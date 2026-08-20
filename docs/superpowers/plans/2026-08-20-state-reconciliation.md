# Local/Remote State Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the eight confirmed ways Ratchet's in-memory state can disagree with FreeAgent's, so that no divergence can silently bill time, destroy hours, or strand a running timer.

**Architecture:** Three structural moves, then targeted fixes. (a) `RatchetTimeslip` stops overloading one `date` field to mean both "the calendar day this work is booked against" and "the instant a timer started" — they become `day` and `timerStartedAt`. (b) `FreeAgentDataStore.refresh()` becomes atomic: every field is built into a local and committed in one non-suspending block, guarded by a mutation epoch so a refresh whose responses predate a user action is discarded rather than reinstating the pre-action world. (c) Every read of "what is actually running" that precedes a write goes to the server, never to the cache. The rest are single-site fixes: strict list envelopes, a Keychain load that distinguishes "no credentials" from "Keychain unavailable", and a `restoreRunningTimer` that keeps tracking when it can't name the running task.

**Tech Stack:** Swift 5.9, SwiftPM (no Xcode project), AppKit, macOS 13 deployment target.

## Global Constraints

- **`swift test` does not work on this machine.** `xcode-select -p` points at `/Library/Developer/CommandLineTools`; there is no Xcode and no XCTest. `swift build` compiles the three source targets but **not** the test targets. Tests you write are unrun code — say so plainly, never imply they pass.
- **Every task therefore has two verification legs, and both are mandatory:** `swift build` in the repo, and a scenario in the Antagonise harness (below) that actually executes against the real `FreeAgentDataStore`.
- **Antagonise harness** lives at `/private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise`. It is a standalone SwiftPM package whose `Sources/RatchetCore` and `Sources/FreeAgentKit` are **symlinks to the real repo source directories**, so it compiles the code you just changed. Build with `cd <harness> && swift build`; run one scenario with `ONLY=N ./.build/debug/Antagonise`. The harness currently asserts the *buggy* behaviour (prints `BUG`); each task flips its scenario to assert the *fixed* behaviour (prints `ok`).
- **Harness runs must be watchdogged** — `timeout` is not installed on this machine. Use:
  `( ONLY=N ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )`
- **The harness writes Keychain items** under `com.ratchet.antagonise.<uuid>`. After a run, clean up:
  `security dump-keychain 2>/dev/null | grep -o 'com\.ratchet\.antagonise\.[A-F0-9-]*' | sort -u | while read s; do security delete-generic-password -s "$s" >/dev/null 2>&1; done`
- **`Sources/FreeAgentKit/Secrets.swift` is gitignored and required to compile.** It already exists here. Never commit it, never delete it.
- **Comment style (from CLAUDE.md):** comments explain **why**, not what — the rationale for a non-obvious choice, the hazard being worked around, the bug a line prevents. Match the surrounding density. Do not add narrating comments.
- **Dates:** route every `yyyy-MM-dd` conversion through `CalendarDay` (`Sources/RatchetCore/CalendarDay.swift`). Never hand-roll a `DateFormatter` for `dated_on`.
- **Test-file call sites are not compiler-checked here.** After changing any signature in `Sources/`, grep `Tests/` for call sites — especially `Tests/RatchetCoreTests/Support/FakeDataStore.swift`, which implements the `DataStore` protocol — and update them by hand.
- **Git:** work directly on `master`. One commit per task. End every commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Do not** run `scripts/build-app.sh`, install anything, or touch `.build` in the repo.

---

## File Structure

| File | Responsibility after this plan |
|---|---|
| `Sources/RatchetCore/Models.swift` | `RatchetTimeslip` gains `day` + `timerStartedAt`, loses the overloaded `date`. |
| `Sources/RatchetCore/AppState.swift` | `startTracking` gains `recordAsMostRecent:` so an unnamed adopted timer doesn't become "most recent". |
| `Sources/RatchetCore/DataStore.swift` | Protocol gains `runningTimeslip()` — the authoritative server read, callable from `RatchetCore`. |
| `Sources/RatchetCore/MenuBuilder.swift` | Reads `entry.day` for display/sort. |
| `Sources/RatchetCore/StatusItemController.swift` | `switchTask` re-reads the server before the PUT; edit form refuses invoiced entries; log-out warns while tracking. |
| `Sources/FreeAgentKit/FreeAgentModelMapping.swift` | `toRatchetTimeslip()` maps `dated_on`→`day` and `timer.start_from`→`timerStartedAt`, honouring `timer.running`. |
| `Sources/FreeAgentKit/FreeAgentDataStore.swift` | Atomic `refresh()`, mutation epoch, server-verified `stopTimer()`, `runningTimeslip()`, `currentUserURL` guard. |
| `Sources/FreeAgentKit/FreeAgentAPIClient.swift` | `getList` throws on a missing list key; `authenticatedRequest` distinguishes Keychain-unavailable. |
| `Sources/FreeAgentKit/KeychainTokenStore.swift` | `loadResult()` returns found / missing / unavailable. |
| `Sources/FreeAgentKit/FreeAgentError.swift` | New `credentialStoreUnavailable(OSStatus)`, explicitly **not** session-expired. |
| `Sources/Ratchet/AppDelegate.swift` | `restoreRunningTimer` keeps tracking when the running timeslip can't be resolved locally. |
| `Tests/RatchetCoreTests/Support/FakeDataStore.swift` | Tracks the model rename and implements `runningTimeslip()`. |

---

### Task 1: `getList` must not turn a missing list key into an empty list

**Findings addressed:** #6 — a response under an unexpected key produced a *successful* refresh with zero clients and a fresh `lastRefreshedAt`, so nothing ever retried.

**Files:**
- Modify: `Sources/FreeAgentKit/FreeAgentAPIClient.swift` (`getList`)
- Test: `Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift`
- Harness: scenario 8

**Interfaces:**
- Consumes: `MissingEnvelopeKey` — the `private struct` already declared at the top of `FreeAgentAPIClient.swift`, `init(envelopeKey: String)`.
- Produces: nothing new. `getList` keeps its signature `func getList<T: Decodable>(_ path: String, query: [URLQueryItem] = [], listKey: String) async throws -> [T]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift` (inside the existing test class; reuse whatever stub transport that file already defines — read it first and match its naming):

```swift
func test_getList_throwsWhenTheListKeyIsAbsent() async throws {
    // A silent `?? []` here meant a renamed/rewrapped envelope read as "you have no clients",
    // which refresh() then committed as success — emptying every menu with nothing to retry.
    let transport = StubTransport()
    transport.responsesByPathSubstring = [
        (match: "contacts", status: 200, body: Data(#"{"data":[]}"#.utf8))
    ]
    let tokenStore = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    tokenStore.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
    let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: tokenStore, transport: transport)
    defer { tokenStore.clear() }

    do {
        let _: [FreeAgentContactDTO] = try await client.getList("contacts", listKey: "contacts")
        XCTFail("expected a decoding error for the missing \"contacts\" key")
    } catch let error as FreeAgentError {
        guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
    }
}

func test_getList_stillReturnsAnEmptyListWhenTheKeyIsPresentButEmpty() async throws {
    let transport = StubTransport()
    transport.responsesByPathSubstring = [
        (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8))
    ]
    let tokenStore = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    tokenStore.save(FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600)))
    let client = FreeAgentAPIClient(environment: .sandbox, tokenStore: tokenStore, transport: transport)
    defer { tokenStore.clear() }

    let contacts: [FreeAgentContactDTO] = try await client.getList("contacts", listKey: "contacts")
    XCTAssertTrue(contacts.isEmpty)
}
```

- [ ] **Step 2: Note that the test cannot be run**

Do not attempt `swift test` — it fails with `no such module 'XCTest'` before running anything. The executable check for this task is the harness in steps 5-7.

- [ ] **Step 3: Implement**

In `Sources/FreeAgentKit/FreeAgentAPIClient.swift`, inside `getList`, replace:

```swift
            let envelope = try decode(data, as: [String: [T]].self)
            let items = envelope[listKey] ?? []
```

with:

```swift
            let envelope = try decode(data, as: [String: [T]].self)
            // `?? []` here read a renamed or rewrapped envelope as "the account has none of
            // these", which `refresh()` then committed as a successful, empty refresh — every
            // menu blank, `lastRefreshedAt` stamped fresh, and nothing left to trigger a retry.
            // An absent key is a response Ratchet doesn't understand, not an empty account.
            guard let items = envelope[listKey] else {
                throw FreeAgentError.decoding(MissingEnvelopeKey(envelopeKey: listKey))
            }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Flip harness scenario 8 to assert the fix**

In the harness `Sources/Antagonise/main.swift`, replace the body of `scenario8_envelopeMismatchWipesData` after the `stub.setRule("contacts?", ...)` line with:

```swift
    stub.setRule("contacts?", body: #"{"data":[]}"#)   // key renamed / wrapped differently
    do {
        try await store.refresh()
        bad("refresh() reported success with \(store.clients.count) clients despite an unrecognised envelope")
    } catch {
        ok("mismatch surfaced as an error: \(error)")
        if store.clients.count == 1 { ok("previous clients left intact") } else { bad("clients clobbered anyway: \(store.clients.count)") }
    }
```

- [ ] **Step 6: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=8 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: two `ok` lines, no `BUG` lines.

- [ ] **Step 7: Clean up harness Keychain items**

```bash
security dump-keychain 2>/dev/null | grep -o 'com\.ratchet\.antagonise\.[A-F0-9-]*' | sort -u | while read s; do security delete-generic-password -s "$s" >/dev/null 2>&1; done
```

- [ ] **Step 8: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/FreeAgentKit/FreeAgentAPIClient.swift Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift && git commit -m "$(cat <<'EOF'
fix: treat a missing list envelope key as an error, not an empty list

A response whose list arrived under an unexpected key decoded fine and then
read as "you have no clients", so refresh() committed an empty store as a
success and stamped lastRefreshedAt — blanking every menu with nothing left
to trigger a retry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: A Keychain read that fails must not destroy the credentials

**Findings addressed:** #7 — `load()` returns `nil` for *every* failure (item missing, Keychain locked, `errSecNotAvailable`, corrupt JSON). That became `.unauthorized` → `indicatesSessionExpired` → `handleSessionExpired()` → `performLogOut()` → `tokenStore.clear()`, permanently deleting a **valid** refresh token over a transient read.

**Files:**
- Modify: `Sources/FreeAgentKit/KeychainTokenStore.swift`
- Modify: `Sources/FreeAgentKit/FreeAgentError.swift`
- Modify: `Sources/FreeAgentKit/FreeAgentAPIClient.swift` (`authenticatedRequest`)
- Test: `Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift`
- Harness: scenario 9

**Interfaces:**
- Produces, used by nothing else in this plan but by `FreeAgentAPIClient`:
  - `public enum TokenLoadResult { case found(FreeAgentTokens); case missing; case unavailable(OSStatus) }`
  - `public func loadResult() -> TokenLoadResult` on `KeychainTokenStore`
  - `public func load() -> FreeAgentTokens?` stays, delegating to `loadResult()`
  - `FreeAgentError.credentialStoreUnavailable(OSStatus)` — `isSessionExpired` is **false** for this case

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift`:

```swift
func test_loadResult_reportsMissingWhenNothingIsStored() {
    let store = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    guard case .missing = store.loadResult() else {
        return XCTFail("an empty store should report .missing")
    }
}

func test_loadResult_reportsFoundAfterASave() {
    let store = KeychainTokenStore(service: "com.ratchet.freeagent.test.\(UUID().uuidString)")
    defer { store.clear() }
    let tokens = FreeAgentTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSinceNow: 3600))
    XCTAssertTrue(store.save(tokens))
    guard case .found(let loaded) = store.loadResult() else {
        return XCTFail("expected .found")
    }
    XCTAssertEqual(loaded, tokens)
}

func test_credentialStoreUnavailableIsNotASessionExpiry() {
    // The whole point of the new case: a Keychain that can't be read says nothing about
    // whether the FreeAgent session is alive, and must never reach the code path that
    // deletes the stored refresh token.
    XCTAssertFalse(FreeAgentError.credentialStoreUnavailable(errSecInteractionNotAllowed).indicatesSessionExpired)
    XCTAssertTrue(FreeAgentError.unauthorized.indicatesSessionExpired)
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints). Harness is the executable check.

- [ ] **Step 3: Implement `TokenLoadResult`**

In `Sources/FreeAgentKit/KeychainTokenStore.swift`, add above the class:

```swift
/// Why this exists instead of an `Optional`: `load()` returning nil conflated "there are no
/// stored credentials" with "the Keychain could not be read right now" (locked, an ACL prompt
/// declined, `errSecNotAvailable` early in boot). The caller mapped both to
/// `FreeAgentError.unauthorized`, which the app treats as a dead session — so a transient read
/// failure deleted a perfectly valid refresh token and forced a re-login.
public enum TokenLoadResult {
    case found(FreeAgentTokens)
    /// Definitively no usable credentials: nothing stored, or stored bytes that no longer
    /// decode. Logging out is the correct response.
    case missing
    /// The Keychain itself failed. Says nothing about the session — never log out on this.
    case unavailable(OSStatus)
}
```

Replace `load()` with:

```swift
    public func loadResult() -> TokenLoadResult {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let tokens = try? JSONDecoder().decode(FreeAgentTokens.self, from: data) else {
                // The item is there but unusable, which a re-login does fix — unlike a
                // Keychain that simply wouldn't answer.
                return .missing
            }
            return .found(tokens)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    /// Convenience for call sites that genuinely only need "do we appear to have credentials"
    /// and take no destructive action either way (e.g. `AppDelegate`'s launch-time seed).
    /// Anything that might log the user out must use `loadResult()` instead.
    public func load() -> FreeAgentTokens? {
        if case .found(let tokens) = loadResult() { return tokens }
        return nil
    }
```

- [ ] **Step 4: Add the error case**

In `Sources/FreeAgentKit/FreeAgentError.swift`, add to the enum (after `case credentialStorageFailed`):

```swift
    case credentialStoreUnavailable(OSStatus)
```

Add to `description`:

```swift
        case .credentialStoreUnavailable(let status):
            return "couldn't read your FreeAgent login from the Keychain (status \(status)) — this is usually temporary; try again in a moment"
```

`isSessionExpired` needs no change: its `if case .unauthorized` returns false for everything else. Add a line to its doc comment:

```swift
    /// `.credentialStoreUnavailable` deliberately does *not* qualify: a Keychain that can't be
    /// read says nothing about whether FreeAgent still accepts the session, and treating it as
    /// an expiry deleted valid credentials.
```

Ensure the file imports what `OSStatus` needs — add `import Security` at the top if `OSStatus` doesn't resolve (it comes from `Foundation` on macOS; build will tell you).

- [ ] **Step 5: Wire it into `authenticatedRequest`**

In `Sources/FreeAgentKit/FreeAgentAPIClient.swift`, replace:

```swift
        guard var tokens = tokenStore.load() else { throw FreeAgentError.unauthorized }
```

with:

```swift
        var tokens: FreeAgentTokens
        switch tokenStore.loadResult() {
        case .found(let stored):
            tokens = stored
        case .missing:
            throw FreeAgentError.unauthorized
        case .unavailable(let status):
            // Not `.unauthorized`: that routes to handleSessionExpired(), which clears the
            // Keychain. Doing that because the Keychain was momentarily unreadable destroys the
            // very credentials this request was trying to use.
            throw FreeAgentError.credentialStoreUnavailable(status)
        }
```

Then in `refreshTokensShared`, the line `if let stored = tokenStore.load(), ...` may stay as-is — it is a best-effort optimisation and nil there simply means "start a refresh".

- [ ] **Step 6: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 7: Update harness scenario 9**

`ts.clear()` genuinely removes the item, so scenario 9 exercises the `.missing` path and *should* still report a session expiry. Rewrite the scenario to prove both halves — that a removed item is still an expiry, and that a Keychain failure is not:

Replace the body of `scenario9_keychainBlipLogsOut` after `try await store.refresh()` with:

```swift
    ts.clear()  // a genuinely deleted item: this one *is* a real "log in again"
    do { try await store.refresh(); bad("expected an error after the credentials were removed") }
    catch {
        print("   removed item -> \(error)  indicatesSessionExpired = \(error.indicatesSessionExpired)")
        if error.indicatesSessionExpired { ok("a missing item still logs out, as it should") }
        else { bad("a missing item no longer logs out") }
    }
    // The case that used to destroy credentials: the Keychain answers with a failure status.
    let unavailable = FreeAgentError.credentialStoreUnavailable(errSecInteractionNotAllowed)
    if unavailable.indicatesSessionExpired {
        bad("a Keychain read failure still routes to handleSessionExpired() -> tokenStore.clear()")
    } else {
        ok("a Keychain read failure no longer clears the stored refresh token")
    }
```

Rename the scenario function and its call site to `scenario9_keychainBlipDoesNotLogOut`, and update `hdr(9, ...)` to `"A Keychain read failure is distinguished from a dead session"`.

- [ ] **Step 8: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=9 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: two `ok` lines, no `BUG` lines. Then run the Keychain cleanup command from Global Constraints.

- [ ] **Step 9: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/FreeAgentKit Tests/FreeAgentKitTests/KeychainTokenStoreTests.swift && git commit -m "$(cat <<'EOF'
fix: stop treating an unreadable Keychain as an expired session

KeychainTokenStore.load() returned nil for every failure mode, including a
locked or momentarily unavailable Keychain. That became .unauthorized, which
routes to handleSessionExpired() -> tokenStore.clear() — so a transient read
failure permanently deleted a valid refresh token.

loadResult() now separates .missing from .unavailable(OSStatus), and the new
.credentialStoreUnavailable error is explicitly not a session expiry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Split `RatchetTimeslip.date` into `day` and `timerStartedAt`

**Findings addressed:** #8 — one field meant three different things depending on the response shape (`timer.start_from` when present, local midnight of `dated_on` when not, `Date()` when neither parsed). A timer started seconds earlier displayed **18:11** elapsed. `timer.running` was decoded but never checked, so a paused timeslip carrying a stale `timer` object was dated to its old start instant.

**Files:**
- Modify: `Sources/RatchetCore/Models.swift` (`RatchetTimeslip`)
- Modify: `Sources/FreeAgentKit/FreeAgentModelMapping.swift` (`toRatchetTimeslip`)
- Modify: `Sources/FreeAgentKit/FreeAgentDataStore.swift` (`resolvedTimeslip`, `startTimer`, `logTime` insertion sort)
- Modify: `Sources/RatchetCore/MenuBuilder.swift` (display + sort)
- Modify: `Sources/RatchetCore/StatusItemController.swift` (four `.date` reads)
- Modify: `Sources/Ratchet/AppDelegate.swift` (`restoreRunningTimer`)
- Modify: `Tests/RatchetCoreTests/Support/FakeDataStore.swift` and every test that constructs a `RatchetTimeslip`
- Harness: scenario 5, plus fixture compile fixes throughout

**Interfaces:**
- Produces (relied on by Tasks 4-9):
```swift
public struct RatchetTimeslip: Identifiable, Equatable, Codable {
    public let id: String
    public let clientId: String
    public let projectId: String
    public let taskId: String
    public let day: Date            // local midnight of FreeAgent's `dated_on`
    public let timerStartedAt: Date? // non-nil only while a timer is actually running
    public let hours: Double
    public let comment: String?
    public let isInvoiced: Bool

    public init(
        id: String, clientId: String, projectId: String, taskId: String,
        day: Date, timerStartedAt: Date? = nil, hours: Double,
        comment: String? = nil, isInvoiced: Bool = false
    )
}
```
  Note the parameter is `day:`, not `date:`, so every existing call site fails to compile until updated — deliberate, since a silent rename would leave instants flowing into a field that now means a calendar day.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FreeAgentKitTests/FreeAgentModelMappingTests.swift`:

```swift
func test_toRatchetTimeslip_keepsTheCalendarDaySeparateFromTheTimerStart() {
    let dto = FreeAgentTimeslipDTO(
        url: "https://api.sandbox.freeagent.com/v2/timeslips/1",
        project: "https://api.sandbox.freeagent.com/v2/projects/1",
        task: "https://api.sandbox.freeagent.com/v2/tasks/1",
        user: "https://api.sandbox.freeagent.com/v2/users/1",
        datedOn: "2026-08-12", hours: "1.5", comment: nil,
        timer: FreeAgentTimerDTO(running: true, startFrom: Date(timeIntervalSince1970: 1_786_000_000))
    )
    let slip = dto.toRatchetTimeslip()
    XCTAssertEqual(CalendarDay.dayString(from: slip.day), "2026-08-12")
    XCTAssertEqual(slip.timerStartedAt, Date(timeIntervalSince1970: 1_786_000_000))
}

func test_toRatchetTimeslip_ignoresAStoppedTimersStartInstant() {
    // FreeAgent can return a `timer` object with running:false. Treating its start_from as
    // live made a paused entry look like it had been running since that instant.
    let dto = FreeAgentTimeslipDTO(
        url: "https://api.sandbox.freeagent.com/v2/timeslips/2",
        project: "https://api.sandbox.freeagent.com/v2/projects/1",
        task: "https://api.sandbox.freeagent.com/v2/tasks/1",
        user: "https://api.sandbox.freeagent.com/v2/users/1",
        datedOn: "2026-08-12", hours: "1.5", comment: nil,
        timer: FreeAgentTimerDTO(running: false, startFrom: Date(timeIntervalSince1970: 1_786_000_000))
    )
    XCTAssertNil(dto.toRatchetTimeslip().timerStartedAt)
}

func test_toRatchetTimeslip_hasNoTimerStartWhenTheResponseOmitsOne() {
    let dto = FreeAgentTimeslipDTO(
        url: "https://api.sandbox.freeagent.com/v2/timeslips/3",
        project: "https://api.sandbox.freeagent.com/v2/projects/1",
        task: "https://api.sandbox.freeagent.com/v2/tasks/1",
        user: "https://api.sandbox.freeagent.com/v2/users/1",
        datedOn: "2026-08-12", hours: "0.0", comment: nil, timer: nil
    )
    let slip = dto.toRatchetTimeslip()
    XCTAssertNil(slip.timerStartedAt)
    XCTAssertEqual(CalendarDay.dayString(from: slip.day), "2026-08-12")
}
```

Append to `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift` (match the file's existing `makeStore`/`StubTransport` helpers):

```swift
func test_startTimer_neverReportsAStartInstantHoursInThePast() async throws {
    // The regression this guards: when the POST /timer response carried no `timer` object,
    // the start instant fell back to local midnight, so a timer begun seconds ago displayed
    // as many hours elapsed as had passed since midnight.
    let transport = StubTransport()
    let today = CalendarDay.dayString(from: Date())
    transport.responsesByPathSubstring = [
        (match: "view=running", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[{"url":"https://api.sandbox.freeagent.com/v2/timeslips/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":null,"billed_on_invoice":null}]}"#.utf8)),
        (match: "/timer", status: 200, body: Data(#"{"timeslip":{"url":"https://api.sandbox.freeagent.com/v2/timeslips/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":null,"billed_on_invoice":null}}"#.utf8)),
    ]
    let (store, tokenStore) = makeStore(transport: transport)
    defer { tokenStore.clear() }

    let started = try await store.startTimer(
        taskId: "https://api.sandbox.freeagent.com/v2/tasks/1",
        projectId: "https://api.sandbox.freeagent.com/v2/projects/1",
        clientId: "https://api.sandbox.freeagent.com/v2/contacts/1"
    )
    let startedAt = try XCTUnwrap(started.timerStartedAt)
    XCTAssertLessThan(abs(startedAt.timeIntervalSinceNow), 5)
}
```

- [ ] **Step 2: Note that the tests cannot be run** (see Global Constraints).

- [ ] **Step 3: Change the model**

In `Sources/RatchetCore/Models.swift`, replace the `date` property and initialiser parameter of `RatchetTimeslip`:

```swift
    /// The calendar day this work is booked against — always local midnight of FreeAgent's
    /// `dated_on`, never an instant. Kept separate from `timerStartedAt` because one field
    /// used to mean both: it held `timer.start_from` when a timer object was present and local
    /// midnight otherwise, so the same property was an instant or a day depending on which
    /// endpoint had last filled it in, and the elapsed-time display read midnight as a start.
    public let day: Date
    /// When the currently-running timer on this timeslip started, or nil if no timer is
    /// running on it. The only correct baseline for elapsed time.
    public let timerStartedAt: Date?
```

and the initialiser:

```swift
    public init(
        id: String, clientId: String, projectId: String, taskId: String, day: Date,
        timerStartedAt: Date? = nil, hours: Double, comment: String? = nil, isInvoiced: Bool = false
    ) {
        self.id = id
        self.clientId = clientId
        self.projectId = projectId
        self.taskId = taskId
        self.day = day
        self.timerStartedAt = timerStartedAt
        self.hours = hours
        self.comment = comment
        self.isInvoiced = isInvoiced
    }
```

- [ ] **Step 4: Change the mapping**

In `Sources/FreeAgentKit/FreeAgentModelMapping.swift`, replace the body of `toRatchetTimeslip()`:

```swift
    func toRatchetTimeslip() -> RatchetTimeslip {
        RatchetTimeslip(
            id: url,
            clientId: "", // filled in by FreeAgentDataStore, which knows project->client
            projectId: project,
            taskId: task,
            // `dated_on` is a plain calendar day, parsed as local midnight so it displays as
            // the day the user picked rather than slipping back one west of UTC. The fallback
            // is `.distantPast` rather than `Date()`: an unparseable day is a broken record,
            // and dating it "today" would quietly file it under the wrong day and re-sort the
            // Recent list around it.
            day: CalendarDay.day(from: datedOn) ?? .distantPast,
            // Only a *running* timer's start is a live baseline. FreeAgent can return a timer
            // object with running:false, and treating that start_from as live made a paused
            // entry look like it had been counting since that instant.
            timerStartedAt: (timer?.running == true) ? timer?.startFrom : nil,
            hours: Double(hours) ?? 0,
            comment: comment,
            isInvoiced: billedOnInvoice != nil
        )
    }
```

- [ ] **Step 5: Update `FreeAgentDataStore`**

In `resolvedTimeslip`, replace the reconstruction to carry both fields:

```swift
        return RatchetTimeslip(
            id: mapped.id, clientId: resolvedClientId, projectId: mapped.projectId,
            taskId: mapped.taskId, day: mapped.day, timerStartedAt: mapped.timerStartedAt,
            hours: mapped.hours, comment: mapped.comment, isInvoiced: mapped.isInvoiced
        )
```

In `startTimer`, the same-task resume branch — replace the `resumed` construction with:

```swift
                let resumed = RatchetTimeslip(
                    id: running.id, clientId: clientId, projectId: running.projectId, taskId: running.taskId,
                    day: running.day, timerStartedAt: running.timerStartedAt, hours: running.hours,
                    comment: running.comment, isInvoiced: running.isInvoiced
                )
```

At the end of `startTimer`, replace `let resolved = resolvedTimeslip(started, clientId: clientId)` / `currentRunningTimeslip = resolved` / `return resolved` with:

```swift
        var resolved = resolvedTimeslip(started, clientId: clientId)
        if resolved.timerStartedAt == nil {
            // The timer demonstrably just started — this call is what started it — so "now" is
            // accurate to the round trip. Without this the elapsed baseline fell back to
            // whatever `day` holds (local midnight), and a timer begun seconds ago displayed
            // hours of elapsed time.
            resolved = RatchetTimeslip(
                id: resolved.id, clientId: resolved.clientId, projectId: resolved.projectId,
                taskId: resolved.taskId, day: resolved.day, timerStartedAt: clock(),
                hours: resolved.hours, comment: resolved.comment, isInvoiced: resolved.isInvoiced
            )
        }
        currentRunningTimeslip = resolved
        return resolved
```

In `logTime`, the insertion sort becomes `$0.day > resolved.day`.

- [ ] **Step 6: Update `MenuBuilder`**

In `buildRecentTimeEntriesSubmenu`, `.sorted { $0.date > $1.date }` becomes `.sorted { $0.day > $1.day }`.
In `addTimeEntryItems`, `CalendarDay.displayString(from: entry.date)` becomes `CalendarDay.displayString(from: entry.day)`.

- [ ] **Step 7: Update `StatusItemController`**

Four sites:
- in `actions.startTracking`: `self.appState.startTracking(task, startedAt: timeslip.date)` →
  ```swift
  // `startTimer` guarantees a non-nil start for a timer it just started; the coalesce is a
  // belt-and-braces baseline rather than a silent midnight fallback.
  self.appState.startTracking(task, startedAt: timeslip.timerStartedAt ?? self.now())
  ```
- in `actions.switchTask`, the `updateTimeslip(... date: running.date ...)` call → `date: running.day`
- in `runAddTaskPrompt`'s `switchingFromRunningTimer` branch, the same `date: running.date` → `date: running.day`
- in `runAddTaskPrompt`'s else branch: `self.appState.startTracking(ref, startedAt: timeslip.date)` → `startedAt: timeslip.timerStartedAt ?? self.now()`
- in `runEditTimeEntryForm`: `datePicker.dateValue = entry.date` → `entry.day`

- [ ] **Step 8: Update `AppDelegate.restoreRunningTimer`**

`appState.startTracking(ref, startedAt: running.date)` →

```swift
    // A timeslip the running-view query returned but that carries no timer start is a response
    // Ratchet can't date; counting from adoption undercounts, which is strictly safer than the
    // old midnight fallback's wild overcount.
    appState.startTracking(ref, startedAt: running.timerStartedAt ?? Date())
```

- [ ] **Step 9: Update every test call site**

```bash
cd /Users/al/Documents/projects/ratchet && grep -rn "RatchetTimeslip(\|\.date" Tests --include='*.swift'
```

Update `Tests/RatchetCoreTests/Support/FakeDataStore.swift`:
- `logTime`'s construction: `date: date` → `day: date`
- `updateTimeslip`'s construction: `date: date` → `day: date`
- `startTimer`'s day-match: `CalendarDay.dayString(from: $0.date)` → `from: $0.day`
- `startTimer`'s fresh construction: `date: clock()` → `day: clock(), timerStartedAt: clock()`
- `startTimer`'s resume branch must also return a slip whose `timerStartedAt` is set — replace
  ```swift
            runningTimeslipId = timeslips[index].id
            return timeslips[index]
  ```
  with
  ```swift
            // Mirrors the real store: resuming makes this the running timer, so the returned
            // slip must carry a live start instant or the UI has no elapsed baseline.
            let existing = timeslips[index]
            let resumed = RatchetTimeslip(
                id: existing.id, clientId: existing.clientId, projectId: existing.projectId,
                taskId: existing.taskId, day: existing.day, timerStartedAt: clock(),
                hours: existing.hours, comment: existing.comment, isInvoiced: existing.isInvoiced
            )
            timeslips[index] = resumed
            runningTimeslipId = resumed.id
            return resumed
  ```
- `stopTimer` should clear the start instant on the stored slip:
  ```swift
        let stopped = RatchetTimeslip(
            id: timeslips[index].id, clientId: timeslips[index].clientId,
            projectId: timeslips[index].projectId, taskId: timeslips[index].taskId,
            day: timeslips[index].day, timerStartedAt: nil, hours: timeslips[index].hours,
            comment: timeslips[index].comment, isInvoiced: timeslips[index].isInvoiced
        )
        timeslips[index] = stopped
        self.runningTimeslipId = nil
        return stopped
  ```

Update every other `RatchetTimeslip(...)` in `Tests/` to pass `day:` instead of `date:`. Read each one; do not sed blindly.

- [ ] **Step 10: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`. Then re-grep to confirm no `\.date` reads on a timeslip remain:
`grep -rn "slip\.date\|entry\.date\|running\.date\|timeslip\.date" Sources Tests --include='*.swift'` → no output.

- [ ] **Step 11: Update the harness**

The harness constructs no `RatchetTimeslip` directly but reads `started.date` in scenario 5. Replace scenario 5's assertion block with:

```swift
    let started = try await store.startTimer(taskId: "\(U)/tasks/1", projectId: "\(U)/projects/1", clientId: "\(U)/contacts/1")
    guard let startedAt = started.timerStartedAt else {
        bad("startTimer returned no timer start at all"); return
    }
    let elapsed = Date().timeIntervalSince(startedAt)
    print("   startedAt = \(startedAt), elapsed shown immediately = \(ElapsedTimeFormatter.format(seconds: elapsed))")
    if elapsed > 120 { bad("a timer started just now displays \(ElapsedTimeFormatter.format(seconds: elapsed)) elapsed") }
    else { ok("elapsed baseline is sane (\(ElapsedTimeFormatter.format(seconds: elapsed)))") }
```

Fix any other harness compile errors the rename causes.

- [ ] **Step 12: Build and run the whole harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ./.build/debug/Antagonise & p=$!; ( sleep 60; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: scenario 5 prints `ok`; scenarios 8 and 9 still print `ok` from Tasks 1-2; the rest still print `BUG` (they are fixed in later tasks). Then run the Keychain cleanup command.

- [ ] **Step 13: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add -A Sources Tests && git commit -m "$(cat <<'EOF'
fix: separate a timeslip's calendar day from its timer start instant

RatchetTimeslip.date meant timer.start_from when the response carried a timer
object, local midnight of dated_on when it didn't, and Date() when neither
parsed — while every consumer read it as one thing. A timer started seconds
earlier could display 18:11 elapsed, because the POST /timer response omitted
the timer object and the baseline fell back to midnight.

`day` is now always the calendar day; `timerStartedAt` is non-nil only while a
timer is genuinely running (timer.running is finally honoured), and startTimer
stamps its own start rather than inheriting midnight.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Make `refresh()` atomic

**Findings addressed:** #5 — a refresh that failed partway had already committed `clients` while `timeslips` and `currentRunningTimeslip` kept their old values. Reproduced: `clients=0` alongside a live `currentRunningTimeslip`, which is precisely the state that makes a running timer unresolvable (finding #4).

**Files:**
- Modify: `Sources/FreeAgentKit/FreeAgentDataStore.swift` (`refresh`, `resolvedTimeslip`)
- Test: `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`
- Harness: scenario 6

**Interfaces:**
- Consumes: `RatchetTimeslip(day:timerStartedAt:...)` from Task 3.
- Produces: `private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, using projectMap: [String: String], clientId: String? = nil) -> RatchetTimeslip` — the map is now a parameter so a refresh can resolve against the map it just built rather than the instance property it hasn't committed yet. Task 5 and Task 6 both call the existing instance-property overload; keep a thin wrapper:
  `private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip { resolvedTimeslip(dto, using: projectToClientId, clientId: clientId) }`

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`:

```swift
func test_refresh_commitsNothingWhenAnyFetchFails() async throws {
    let today = CalendarDay.dayString(from: Date())
    let runningBody = #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/400","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"1.0","comment":null,"timer":{"running":true,"start_from":"2026-08-19T09:00:00Z"},"billed_on_invoice":null}"#
    let transport = StubTransport()
    transport.responsesByPathSubstring = [
        (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
        (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
        (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
        (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
        (match: "contacts", status: 200, body: Data(#"{"contacts":[{"url":"https://api.sandbox.freeagent.com/v2/contacts/1","organisation_name":"Acme","first_name":null,"last_name":null,"email":null,"phone_number":null,"address1":null,"town":null,"postcode":null,"country":null}]}"#.utf8)),
        (match: "projects", status: 200, body: Data(#"{"projects":[{"url":"https://api.sandbox.freeagent.com/v2/projects/1","contact":"https://api.sandbox.freeagent.com/v2/contacts/1","name":"Site","status":"Active","currency":"GBP","budget":"0","budget_units":"Hours","hours_per_day":"8","normal_billing_rate":"0","billing_period":"hour","uses_project_invoice_sequence":false,"contract_po_reference":null,"starts_on":null,"ends_on":null}]}"#.utf8)),
        (match: "tasks", status: 200, body: Data(#"{"tasks":[{"url":"https://api.sandbox.freeagent.com/v2/tasks/1","project":"https://api.sandbox.freeagent.com/v2/projects/1","name":"Dev","is_billable":true,"status":"Active","billing_rate":null,"billing_period":null}]}"#.utf8)),
    ]
    let (store, tokenStore) = makeStore(transport: transport)
    defer { tokenStore.clear() }
    try await store.refresh()
    XCTAssertEqual(store.clients.count, 1)
    let firstRefreshAt = store.lastRefreshedAt

    // Second refresh: the contact list now comes back empty and the timeslip window 500s.
    // A partial commit here is what leaves a live running timeslip pointing into an empty
    // client tree — the state that strands a running timer with no way to stop it.
    transport.responsesByPathSubstring[4] = (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8))
    transport.responsesByPathSubstring[3] = (match: "timeslips?", status: 500, body: Data(#"{"error":"boom"}"#.utf8))

    do { try await store.refresh(); XCTFail("expected the refresh to throw") } catch {}

    XCTAssertEqual(store.clients.count, 1, "clients must not be committed by a failed refresh")
    XCTAssertEqual(store.timeslips.count, 1)
    XCTAssertNotNil(store.currentRunningTimeslip)
    XCTAssertEqual(store.lastRefreshedAt, firstRefreshAt, "a failed refresh must not stamp lastRefreshedAt")
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Rewrite `refresh()` as build-then-commit**

Replace the whole body of `refresh()` in `Sources/FreeAgentKit/FreeAgentDataStore.swift` with:

```swift
    public func refresh() async throws {
        // Everything below is built into locals and assigned in the single commit block at the
        // end. The previous shape assigned as it went, so a failure partway through left the
        // store half-new: `clients` replaced while `timeslips` and `currentRunningTimeslip`
        // still described the old world. That combination is exactly what makes a running
        // timeslip unresolvable against the client tree, which used to drop the menu to idle
        // while FreeAgent kept billing.
        let user: FreeAgentUserDTO = try await apiClient.get("users/me", envelopeKey: "user")
        let userURL = user.url

        // Best-effort: "Open FreeAgent" keeps whatever URL it already had if this fails, rather
        // than failing the whole refresh over a menu convenience link.
        let company: FreeAgentCompanyDTO? = try? await apiClient.get("company", envelopeKey: "company")

        // A trailing window rather than today-only: "Recent time entries" is meant to be a short
        // history, and "Log past time" writes entries dated in the past — with a today-only
        // fetch those vanished from the menu on the very next refresh.
        let today = todayString()
        let windowStart = dateString(clock().addingTimeInterval(-Self.recentTimeslipWindowDays * 24 * 60 * 60))

        // All five fetched as one concurrent batch: none depends on another's result, and each
        // is paginated, so running them in sequence made a launch-time refresh cost the sum of
        // every round trip before the menu showed anything. `async let` starts its child task at
        // the declaration, not the `await`, so these all have to be declared together up front.
        async let contactsFetch: [FreeAgentContactDTO] = apiClient.getList("contacts", listKey: "contacts")
        async let projectsFetch: [FreeAgentProjectDTO] = apiClient.getList("projects", listKey: "projects")
        async let tasksFetch: [FreeAgentTaskDTO] = apiClient.getList("tasks", listKey: "tasks")
        async let recentFetch: [FreeAgentTimeslipDTO] = apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "from_date", value: windowStart),
                URLQueryItem(name: "to_date", value: today),
                URLQueryItem(name: "user", value: userURL),
            ], listKey: "timeslips"
        )
        async let runningFetch = fetchRunningTimeslipDTO(userURL: userURL)

        let contacts = try await contactsFetch
        let projects = try await projectsFetch
        let tasks = try await tasksFetch
        let recentDTOs = try await recentFetch
        let runningDTO = try await runningFetch

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps at runtime if
        // pagination ever hands back the same project URL twice. "Last write wins" is fine for
        // a duplicate of the same project.
        let newProjectToClientId = Dictionary(projects.map { ($0.url, $0.contact) }, uniquingKeysWith: { _, new in new })
        let tasksByProject = Dictionary(grouping: tasks, by: \.project)
        let projectsByContact = Dictionary(grouping: projects, by: \.contact)

        let newClients = contacts.map { contact in
            let contactProjects = (projectsByContact[contact.url] ?? []).map { project in
                let projectTasks = (tasksByProject[project.url] ?? []).map { $0.toRatchetTask() }
                return project.toRatchetProject(tasks: projectTasks)
            }
            return contact.toRatchetClient(projects: contactProjects)
        }
        // Resolved against the map just built, not the instance property — which is still the
        // *previous* refresh's map until the commit block below.
        // Kept sorted ascending by day so the array has one defined order regardless of what
        // sequence pagination returned; `logTime` preserves it on insert.
        let newTimeslips = recentDTOs.map { resolvedTimeslip($0, using: newProjectToClientId) }.sorted { $0.day < $1.day }
        let newRunning = runningDTO.map { resolvedTimeslip($0, using: newProjectToClientId) }

        // Single commit point: no `await` between here and the end of the function, so no other
        // main-actor work can observe a half-applied refresh.
        accountEmail = user.email
        currentUserURL = userURL
        if let company { webAppURL = environment.webAppURL(subdomain: company.subdomain) }
        projectToClientId = newProjectToClientId
        clients = newClients
        timeslips = newTimeslips
        currentRunningTimeslip = newRunning
        lastRefreshedAt = clock()
    }
```

- [ ] **Step 4: Parameterise the resolver and the running fetch**

Replace `resolvedTimeslip` with the two-overload form:

```swift
    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, using projectMap: [String: String], clientId: String? = nil) -> RatchetTimeslip {
        let resolvedClientId = clientId ?? projectMap[dto.project] ?? ""
        let mapped = dto.toRatchetTimeslip()
        return RatchetTimeslip(
            id: mapped.id, clientId: resolvedClientId, projectId: mapped.projectId,
            taskId: mapped.taskId, day: mapped.day, timerStartedAt: mapped.timerStartedAt,
            hours: mapped.hours, comment: mapped.comment, isInvoiced: mapped.isInvoiced
        )
    }

    /// The committed-state resolver, for the mutating calls that run outside `refresh()`.
    private func resolvedTimeslip(_ dto: FreeAgentTimeslipDTO, clientId: String? = nil) -> RatchetTimeslip {
        resolvedTimeslip(dto, using: projectToClientId, clientId: clientId)
    }
```

Give `fetchRunningTimeslipDTO` an explicit user parameter so `refresh()` can call it before committing `currentUserURL`:

```swift
    private func fetchRunningTimeslipDTO(userURL: String? = nil) async throws -> FreeAgentTimeslipDTO? {
        let running: [FreeAgentTimeslipDTO] = try await apiClient.getList(
            "timeslips", query: [
                URLQueryItem(name: "view", value: "running"),
                URLQueryItem(name: "user", value: userURL ?? currentUserURL),
            ], listKey: "timeslips"
        )
        return running.first
    }
```

- [ ] **Step 5: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 6: Flip harness scenario 6**

Replace the assertion at the end of `scenario6_partialRefresh` with:

```swift
    if store.clients.count == 1 && store.timeslips.count == 1 && store.currentRunningTimeslip != nil {
        ok("the failed refresh committed nothing; the previous snapshot is intact")
    } else {
        bad("partial commit: clients=\(store.clients.count) timeslips=\(store.timeslips.count) running=\(store.currentRunningTimeslip?.id ?? "nil")")
    }
    if store.lastRefreshedAt == before.at { ok("lastRefreshedAt not stamped by the failed refresh") }
    else { bad("lastRefreshedAt advanced despite the failure") }
```

- [ ] **Step 7: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=6 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: two `ok` lines, no `BUG`. Then run the Keychain cleanup command.

- [ ] **Step 8: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/FreeAgentKit/FreeAgentDataStore.swift Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift && git commit -m "$(cat <<'EOF'
fix: make refresh() commit all its state or none of it

A refresh that failed partway had already replaced `clients` while `timeslips`
and `currentRunningTimeslip` still described the previous fetch — leaving a
live running timeslip pointing into a client tree that no longer contained it.

Every field is now built into a local and assigned in one block with no await
in it, so nothing can observe a half-applied refresh.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Discard a refresh whose responses predate a user action

**Findings addressed:** #1 — `refresh()` unconditionally overwrote `currentRunningTimeslip` with a snapshot that could predate a start or stop the user performed while it was in flight. Both directions reproduced: a stopped timer resurrected as "tracking" (green tray, climbing clock, and the next Stop DELETEs a dead timer), and a just-started timer erased to idle while FreeAgent kept billing. The same mechanism discards `logTime`'s inserted slip and the entities appended by `addClient`/`addProject`/`addTask`.

**Files:**
- Modify: `Sources/FreeAgentKit/FreeAgentDataStore.swift`
- Test: `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`
- Harness: scenarios 1 and 2

**Interfaces:**
- Consumes: the single commit block from Task 4.
- Produces: no public API change. Internally, `private var mutationEpoch: UInt64` and `private func beginMutation()`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`:

```swift
func test_refresh_doesNotResurrectATimerStoppedWhileItWasInFlight() async throws {
    // The interleaving is the ordinary one: menuWillOpen fires a silent refresh, the user
    // clicks "Stop tracking" a second later, and the refresh's already-computed answer
    // ("timeslip 9 is running") lands afterwards. Before the epoch guard that answer won,
    // and the menu showed a green tray and a climbing clock for a stopped timer.
    let today = CalendarDay.dayString(from: Date())
    let runningBody = #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/9","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"2026-08-19T09:00:00Z"},"billed_on_invoice":null}"#
    let transport = GatedStubTransport(gateMatch: "view=running")
    transport.responsesByPathSubstring = [
        (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
        (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
        (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
        (match: "timeslips/9/timer", status: 200, body: Data("{}".utf8)),
        (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[\#(runningBody)]}"#.utf8)),
        (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
        (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
        (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
    ]
    let (store, tokenStore) = makeStore(transport: transport)
    defer { tokenStore.clear() }
    try await store.refresh()
    XCTAssertNotNil(store.currentRunningTimeslip)

    transport.arm()
    let inFlight = Task { @MainActor in try? await store.refresh() }
    await transport.waitForGate()
    _ = try await store.stopTimer()
    XCTAssertNil(store.currentRunningTimeslip)
    transport.release()
    _ = await inFlight.value

    XCTAssertNil(store.currentRunningTimeslip, "the stale in-flight refresh must not resurrect the stopped timer")
}
```

Add the gated transport to the same test file (below the existing `StubTransport`):

```swift
/// A `StubTransport` that can hold the first request matching `gateMatch` open until released,
/// so a test can interleave a user action with a refresh that is still in flight.
@MainActor
private final class GatedStubTransport: FreeAgentTransport {
    var responsesByPathSubstring: [(match: String, status: Int, body: Data)] = []
    private let gateMatch: String
    private var armed = false
    private var gateHit = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(gateMatch: String) { self.gateMatch = gateMatch }

    func arm() { armed = true }

    func release() {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }

    func waitForGate() async {
        for _ in 0..<2000 {
            if gateHit { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Registers the continuation synchronously on the main actor, so `release()` can never run
    /// before the waiter has been recorded — that ordering hole deadlocks the test.
    private func waitIfGated(_ url: String) async {
        guard armed, url.contains(gateMatch), !gateHit else { return }
        gateHit = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        await waitIfGated(url)
        return try await MainActor.run {
            guard let entry = responsesByPathSubstring.first(where: { url.contains($0.match) }) else {
                fatalError("No stubbed response matches \(url)")
            }
            return (entry.body, HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Add the epoch**

In `Sources/FreeAgentKit/FreeAgentDataStore.swift`, next to the other private stored properties:

```swift
    /// Bumped on entry to every method that changes server-side state. `refresh()` snapshots it
    /// before its first request and abandons its commit if the value moved, because a refresh's
    /// responses describe the world as of when the server answered them — which, for a request
    /// still in flight when the user starts or stops a timer, is the world *before* that action.
    /// Committing them anyway reinstated it: a stopped timer came back as "tracking" (green
    /// tray, climbing clock, and a Stop that then DELETEs a dead timer), and a just-started one
    /// vanished to idle while FreeAgent went on billing.
    private var mutationEpoch: UInt64 = 0

    /// Called at the *start* of each mutating method, not the end — a refresh whose responses
    /// were computed while a mutation was mid-flight is just as stale as one that predates it.
    private func beginMutation() {
        mutationEpoch &+= 1
    }
```

- [ ] **Step 4: Snapshot and check in `refresh()`**

As the first line of `refresh()`:

```swift
        let epoch = mutationEpoch
```

Immediately before the commit block (the `accountEmail = user.email` line), insert:

```swift
        // A mutation landed while these responses were in flight, so they describe a superseded
        // world. Drop them — and deliberately don't stamp `lastRefreshedAt`, so the next menu
        // open or wake treats the data as stale and fetches again.
        guard mutationEpoch == epoch else { return }
```

- [ ] **Step 5: Bump on every mutating method**

Add `beginMutation()` as the first statement of each of: `startTimer`, `stopTimer`, `logTime`, `updateTimeslip`, `addClient`, `addProject`, `addTask`.

- [ ] **Step 6: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 7: Flip harness scenarios 1 and 2**

Scenario 1 — replace the final `if`:

```swift
    if store.currentRunningTimeslip == nil, app.trackingTask == nil {
        ok("the stop survived the concurrent refresh")
    } else {
        bad("the stale in-flight refresh resurrected the stopped timer")
    }
```

Scenario 2 — replace the final `if`:

```swift
    if store.currentRunningTimeslip != nil, app.trackingTask != nil {
        ok("the start survived the concurrent refresh")
    } else {
        bad("the in-flight refresh erased the just-started timer")
    }
```

- [ ] **Step 8: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && for n in 1 2 6; do ( ONLY=$n ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p ); done
```

Expected: scenarios 1, 2 and 6 all `ok`, no `BUG`. Then run the Keychain cleanup command.

- [ ] **Step 9: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/FreeAgentKit/FreeAgentDataStore.swift Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift && git commit -m "$(cat <<'EOF'
fix: discard a refresh whose responses predate a user action

menuWillOpen and system wake both fire a silent refresh, so a start or stop
clicked a second later routinely raced it. The refresh's already-computed
answer won: a stopped timer came back as tracking, and a just-started one was
erased to idle while FreeAgent kept billing. The same overwrite discarded
locally-inserted timeslips and newly created clients, projects and tasks.

Mutating calls now bump an epoch that refresh() snapshots and rechecks before
committing, and a discarded refresh leaves lastRefreshedAt alone so the next
trigger retries.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `stopTimer()` must ask the server what is actually running

**Findings addressed:** #3 — the server-query fallback only fired when the cache was `nil`. A cache naming the *wrong* timeslip was never checked, so Ratchet DELETEd `timeslips/100/timer` (already stopped elsewhere), reported success, and left `timeslips/200` running while the menu went idle.

**Files:**
- Modify: `Sources/FreeAgentKit/FreeAgentDataStore.swift` (`stopTimer`, plus a new `runningTimeslip()`)
- Modify: `Sources/RatchetCore/DataStore.swift` (protocol gains `runningTimeslip()`)
- Modify: `Tests/RatchetCoreTests/Support/FakeDataStore.swift`
- Test: `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`
- Harness: scenario 3

**Interfaces:**
- Produces, consumed by Task 7:
```swift
    /// The authoritative "what is running right now" read, straight from FreeAgent. Distinct
    /// from `currentRunningTimeslip`, which is a cache that can name a timeslip that stopped
    /// elsewhere. Callers about to *write* must use this.
    func runningTimeslip() async throws -> RatchetTimeslip?
```
  on the `DataStore` protocol, implemented by `FreeAgentDataStore` and `FakeDataStore`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`:

```swift
func test_stopTimer_stopsWhatIsActuallyRunningNotWhatWasCached() async throws {
    // Cache says 100; the server says 200 is running (100 was stopped from the web app and a
    // new one started). Trusting the cache stopped an already-stopped timeslip, reported
    // success, and left 200 billing with the menu showing idle.
    let today = CalendarDay.dayString(from: Date())
    func body(_ id: Int, _ start: String) -> String {
        #"{"url":"https://api.sandbox.freeagent.com/v2/timeslips/\#(id)","project":"https://api.sandbox.freeagent.com/v2/projects/1","task":"https://api.sandbox.freeagent.com/v2/tasks/1","user":"https://api.sandbox.freeagent.com/v2/users/1","dated_on":"\#(today)","hours":"0.0","comment":null,"timer":{"running":true,"start_from":"\#(start)"},"billed_on_invoice":null}"#
    }
    let transport = StubTransport()
    transport.responsesByPathSubstring = [
        (match: "users/me", status: 200, body: Data(#"{"user":{"url":"https://api.sandbox.freeagent.com/v2/users/1","email":"al@example.com"}}"#.utf8)),
        (match: "company", status: 200, body: Data(#"{"company":{"subdomain":"acme"}}"#.utf8)),
        (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(body(100, "2026-08-19T09:00:00Z"))]}"#.utf8)),
        (match: "timeslips?", status: 200, body: Data(#"{"timeslips":[]}"#.utf8)),
        (match: "contacts", status: 200, body: Data(#"{"contacts":[]}"#.utf8)),
        (match: "projects", status: 200, body: Data(#"{"projects":[]}"#.utf8)),
        (match: "tasks", status: 200, body: Data(#"{"tasks":[]}"#.utf8)),
        (match: "timeslips/", status: 200, body: Data("{}".utf8)),
    ]
    let (store, tokenStore) = makeStore(transport: transport)
    defer { tokenStore.clear() }
    try await store.refresh()
    XCTAssertEqual(store.currentRunningTimeslip?.id, "https://api.sandbox.freeagent.com/v2/timeslips/100")

    transport.responsesByPathSubstring[2] = (match: "view=running", status: 200, body: Data(#"{"timeslips":[\#(body(200, "2026-08-19T11:00:00Z"))]}"#.utf8))
    transport.calls = []
    let stopped = try await store.stopTimer()

    XCTAssertEqual(stopped?.id, "https://api.sandbox.freeagent.com/v2/timeslips/200")
    let deletes = transport.calls.filter { $0.httpMethod == "DELETE" }.map { $0.url!.absoluteString }
    XCTAssertEqual(deletes, ["https://api.sandbox.freeagent.com/v2/timeslips/200/timer"])
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Add `runningTimeslip()` to the protocol**

In `Sources/RatchetCore/DataStore.swift`, add after the `currentRunningTimeslip` property:

```swift
    /// The authoritative "what is running right now", read from the server. `currentRunningTimeslip`
    /// above is a cache and can name a timeslip that was stopped from the FreeAgent web app,
    /// another device, or simply yesterday — anything about to *write* to the running timeslip
    /// must go through this instead.
    func runningTimeslip() async throws -> RatchetTimeslip?
```

- [ ] **Step 4: Implement it and rewrite `stopTimer`**

In `Sources/FreeAgentKit/FreeAgentDataStore.swift`, make the existing private helper public-facing:

```swift
    public func runningTimeslip() async throws -> RatchetTimeslip? {
        try await fetchRunningTimeslip()
    }
```

Replace `stopTimer`'s body:

```swift
    public func stopTimer() async throws -> RatchetTimeslip? {
        beginMutation()
        // Always the server, never the cache. The old code only queried when the cache was
        // empty — but a cache naming the *wrong* timeslip is the dangerous case, not the
        // absent one: it DELETEd a timer that had already been stopped elsewhere, reported
        // success, and left the timer that was genuinely running to bill on unnoticed.
        guard let running = try await fetchRunningTimeslip() else {
            currentRunningTimeslip = nil
            return nil
        }
        try await apiClient.delete("\(running.id)/timer")
        currentRunningTimeslip = nil
        return running
    }
```

- [ ] **Step 5: Implement it on `FakeDataStore`**

In `Tests/RatchetCoreTests/Support/FakeDataStore.swift`, add:

```swift
    /// The fake has no server behind it, so its cache *is* the truth — but the method must
    /// exist for the protocol, and tests that want a drifted cache can seed one via
    /// `seedTimeslips(_:runningId:)`.
    func runningTimeslip() async throws -> RatchetTimeslip? {
        currentRunningTimeslip
    }
```

- [ ] **Step 6: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 7: Flip harness scenario 3**

Replace the final assertion of `scenario3_stopTrustsStaleCache` with:

```swift
    print("   DELETE calls: \(deleted)")
    if queried, deleted == ["\(U)/timeslips/200/timer"] {
        ok("asked the server first and stopped what was actually running")
    } else {
        bad("stopped \(deleted) without re-checking (queried=\(queried))")
    }
```

Also update the scenario's stub so the running-view response after the drift is reachable — it already sets `view=running` to timeslip 200, and `stub.setRule("timeslips/", body: "{}")` covers the DELETE. Confirm rule ordering still routes `view=running` before `timeslips/`.

- [ ] **Step 8: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=3 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: `ok`, no `BUG`. Then run the Keychain cleanup command.

- [ ] **Step 9: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources Tests && git commit -m "$(cat <<'EOF'
fix: stop the timer the server says is running, not the cached one

stopTimer() only queried the server when its cache was empty. A cache naming
the wrong timeslip — stopped from the web app, or from another device — went
unchecked: Ratchet DELETEd an already-stopped timer, reported success, and
left the one that was genuinely running to bill on with the menu showing idle.

Adds DataStore.runningTimeslip() as the authoritative read for callers that
are about to write.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: "Switch task" must re-read the running timeslip before overwriting it

**Findings addressed:** #2 — `switchTask` read `dataStore.currentRunningTimeslip` (as fresh as the last refresh) and PUT it back as a full record. Reproduced: `"hours":"2.0"` from the last refresh sent back over a server value that had since moved on. It also re-sent `dated_on` derived from a `start_from` instant converted to the *Mac's* local day, which can move the entry to a different calendar day than FreeAgent recorded.

**Files:**
- Modify: `Sources/RatchetCore/StatusItemController.swift` (`actions.switchTask`, and the `switchingFromRunningTimer` branch of `runAddTaskPrompt`)
- Test: `Tests/RatchetCoreTests/AppStateTests.swift` or a new `Tests/RatchetCoreTests/SwitchTaskTests.swift`
- Harness: scenario 4

**Interfaces:**
- Consumes: `DataStore.runningTimeslip() async throws -> RatchetTimeslip?` from Task 6; `RatchetTimeslip.day` from Task 3.

- [ ] **Step 1: Write the failing test**

Create `Tests/RatchetCoreTests/SwitchTaskTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RatchetCore

@MainActor
final class SwitchTaskTests: XCTestCase {
    /// The regression: "Switch task" sent the whole timeslip record back with the `hours` it
    /// had cached at the last refresh, so anything the server had accrued since (a pause and
    /// resume from the web app) was asserted away.
    func test_switchTask_sendsTheServersHoursNotTheCachedOnes() async throws {
        let store = FakeDataStore.seeded()
        let day = CalendarDay.day(from: "2026-08-19")!
        let stale = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: day, timerStartedAt: day.addingTimeInterval(9 * 3600), hours: 2.0
        )
        store.seedTimeslips([stale], runningId: "timeslip-1")
        // The server has moved on: the same timeslip now stands at 5 hours.
        store.serverRunningOverride = RatchetTimeslip(
            id: "timeslip-1", clientId: "client-1", projectId: "proj-1", taskId: "task-1",
            day: day, timerStartedAt: day.addingTimeInterval(9 * 3600), hours: 5.0
        )

        let running = try await store.runningTimeslip()
        XCTAssertEqual(running?.hours, 5.0)
        _ = try await store.updateTimeslip(
            id: running!.id, taskId: "task-2", projectId: "proj-1", clientId: "client-1",
            date: running!.day, hours: running!.hours, comment: running!.comment
        )
        XCTAssertEqual(store.timeslips.first { $0.id == "timeslip-1" }?.hours, 5.0)
    }
}
```

Add the seam to `Tests/RatchetCoreTests/Support/FakeDataStore.swift`:

```swift
    /// Lets a test model a server whose running timeslip has drifted from this fake's cache —
    /// the situation `runningTimeslip()` exists to catch.
    var serverRunningOverride: RatchetTimeslip?
```

and change `runningTimeslip()` to `serverRunningOverride ?? currentRunningTimeslip`.

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Rewrite `actions.switchTask`**

In `Sources/RatchetCore/StatusItemController.swift`, replace the body of the `switchTask:` closure's `do` block with:

```swift
                    // Reassigns the *running* timeslip's task in place (a PUT on its task/
                    // project/client, same hours/day/comment) rather than stopping and starting
                    // a new one — the point of "Switch task" is to keep tracking continuously
                    // against a different task, not to end one entry and begin another.
                    //
                    // Read from the server, not from `currentRunningTimeslip`: FreeAgent's
                    // timeslip PUT takes the complete record, so the hours and day sent here are
                    // *asserted*, not merged. Sending the cache's values overwrote anything the
                    // server had accrued since the last refresh — a pause and resume from the
                    // web app silently lost the hours in between.
                    guard let running = try await self.dataStore.runningTimeslip() else {
                        self.presentAPIError(DataStoreError.notFound, action: "switch tasks")
                        return
                    }
                    _ = try await self.dataStore.updateTimeslip(
                        id: running.id,
                        taskId: task.taskId, projectId: task.projectId, clientId: task.clientId,
                        date: running.day, hours: running.hours, comment: running.comment
                    )
```

- [ ] **Step 4: Rewrite the same call in `runAddTaskPrompt`**

Replace the `switchingFromRunningTimer` branch's guard and call with:

```swift
                    // Same reasoning as `switchTask`: the PUT asserts the full record, so the
                    // hours and day must come from the server rather than a cache that may be
                    // minutes old.
                    guard let running = try await self.dataStore.runningTimeslip() else {
                        self.presentAPIError(DataStoreError.notFound, action: "switch tasks")
                        return
                    }
                    _ = try await self.dataStore.updateTimeslip(
                        id: running.id,
                        taskId: task.id, projectId: projectId, clientId: clientId,
                        date: running.day, hours: running.hours, comment: running.comment
                    )
```

- [ ] **Step 5: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 6: Rewrite harness scenario 4**

The harness calls `updateTimeslip` directly, so make it call the new sequence and check the PUT body carries the server's hours:

```swift
    // Elsewhere: the timer was paused and resumed, so the server's hours is now 5.0.
    stub.setRule("view=running", body: #"{"timeslips":[\#(slip(id: 300, task: 1, hours: "5.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z"))]}"#)
    stub.setRule("timeslips/300", body: #"{"timeslip":\#(slip(id: 300, task: 2, hours: "5.0", datedOn: today(), timerStart: "2026-08-19T09:00:00Z"))}"#)
    stub.log = []
    // Exactly what StatusItemController.switchTask now does:
    guard let fresh = try await store.runningTimeslip() else { bad("no running timeslip"); return }
    _ = try await store.updateTimeslip(id: fresh.id, taskId: "\(U)/tasks/2", projectId: "\(U)/projects/1",
                                       clientId: "\(U)/contacts/1", date: fresh.day, hours: fresh.hours, comment: fresh.comment)
    let put = stub.log.first { $0.method == "PUT" }!
    print("   PUT body: \(put.body)")
    if put.body.contains("\"hours\":\"5.0\"") { ok("the PUT carries the server's hours, not the cached 2.0") }
    else { bad("the PUT still asserts stale hours: \(put.body)") }
    if stub.log.contains(where: { $0.url.contains("view=running") }) { ok("re-read the running timeslip before writing") }
    else { bad("switch still writes without re-reading") }
```

- [ ] **Step 7: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=4 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: two `ok` lines, no `BUG`. Then run the Keychain cleanup command.

- [ ] **Step 8: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/RatchetCore Tests/RatchetCoreTests && git commit -m "$(cat <<'EOF'
fix: re-read the running timeslip before Switch task overwrites it

FreeAgent's timeslip PUT takes the complete record, so the hours and day sent
are asserted rather than merged. "Switch task" sent the values it had cached
at the last refresh, so hours the server had accrued since — a pause and
resume from the web app — were silently overwritten. It also re-derived
dated_on from a start instant in the Mac's local zone, which can land on a
different day than FreeAgent recorded.

startTimer and stopTimer were already hardened this way; this was the sibling
that wasn't.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Don't drop to idle when the running timer can't be named

**Findings addressed:** #4 — `restoreRunningTimer` treats "the server reports a running timeslip I can't resolve against the local client tree" identically to "nothing is running", and calls `appState.stopTracking()`. Because "Stop tracking" only exists on the tracking screen, this leaves **no route to stop that timer from Ratchet at all**. Reachable whenever the running timer's task is Completed/Hidden, its project archived, or a list fetch came back short — the app passes no `view` parameter to `/contacts`, `/projects` or `/tasks`, so it inherits FreeAgent's defaults.

**Files:**
- Modify: `Sources/Ratchet/AppDelegate.swift` (`restoreRunningTimer`)
- Modify: `Sources/RatchetCore/AppState.swift` (`startTracking` gains `recordAsMostRecent:`)
- Test: `Tests/RatchetCoreTests/AppStateTests.swift`
- Harness: scenario 7

**Interfaces:**
- Produces:
```swift
    public func startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil, recordAsMostRecent: Bool = true)
```
  Existing call sites need no change — the default preserves today's behaviour.

- [ ] **Step 1: Write the failing test**

Append to `Tests/RatchetCoreTests/AppStateTests.swift`:

```swift
func test_startTracking_canAdoptATimerWithoutMakingItTheMostRecentTask() {
    // An adopted-but-unnameable timer must keep the Stop item reachable, but it must not
    // become the "Start tracking <placeholder>" row on the idle screen afterwards.
    let state = AppState()
    state.logIn()
    let real = TrackedTaskRef(clientId: "c", clientName: "Acme", projectId: "p", projectName: "Site", taskId: "t1", taskName: "Dev")
    state.startTracking(real)
    state.stopTracking()

    let placeholder = TrackedTaskRef(clientId: "c", clientName: "Acme", projectId: "p", projectName: "Site", taskId: "t9", taskName: "Unknown task")
    state.startTracking(placeholder, recordAsMostRecent: false)
    guard case .tracking(let task, _) = state.screen else { return XCTFail("expected .tracking") }
    XCTAssertEqual(task.taskId, "t9")

    state.stopTracking()
    guard case .idle(let mostRecent) = state.screen else { return XCTFail("expected .idle") }
    XCTAssertEqual(mostRecent.taskId, "t1", "the placeholder must not become the most recent task")
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Add the parameter to `AppState`**

Replace `startTracking` in `Sources/RatchetCore/AppState.swift`:

```swift
    /// `recordAsMostRecent: false` is for adopting a timer whose task can't be named from local
    /// data — the placeholder ref keeps "Stop tracking" reachable, but it must never become the
    /// "Start tracking …" row the idle screen offers afterwards.
    public func startTracking(_ task: TrackedTaskRef, startedAt: Date? = nil, recordAsMostRecent: Bool = true) {
        trackingTask = task
        trackingStartedAt = startedAt ?? clock()
        if recordAsMostRecent { mostRecent = task }
        onChange?()
    }
```

- [ ] **Step 4: Rewrite `restoreRunningTimer`**

Replace the whole function in `Sources/Ratchet/AppDelegate.swift`:

```swift
/// Adopts whatever timer FreeAgent reports as running into local `AppState`, so the menu shows
/// "tracking" for a timer started elsewhere (another device, the FreeAgent web app, or this app
/// before a quit or a log out).
///
/// Shared by the launch-time restore and `StatusItemController`'s post-login restore — these
/// were separate before, so quit-and-relaunch restored a running timer but log-out-and-back-in
/// showed idle, from identical server state.
@MainActor
func restoreRunningTimer(from dataStore: FreeAgentDataStore, into appState: AppState) {
    guard let running = dataStore.currentRunningTimeslip else {
        // The server genuinely has nothing running, so local "tracking" is now stale. Without
        // this, a timer stopped elsewhere left the menu tracking forever.
        if appState.trackingTask != nil { appState.stopTracking() }
        return
    }

    // Resolve as far as the local tree allows and fall back to placeholders for the rest.
    // Treating an unresolvable-but-running timeslip as "nothing is running" used to call
    // stopTracking(), which is worse than a wrong label: "Stop tracking" only exists on the
    // tracking screen, so the menu dropped to idle and left no route to stop a timer that went
    // on billing. It is reachable whenever the running task is Completed or Hidden, its project
    // archived, or a list fetch came back short.
    let client = dataStore.clients.first { $0.id == running.clientId }
    let project = client?.projects.first { $0.id == running.projectId }
    let task = project?.tasks.first { $0.id == running.taskId }
    let isFullyResolved = task != nil

    let ref = TrackedTaskRef(
        clientId: running.clientId, clientName: client?.name ?? "Unknown client",
        projectId: running.projectId, projectName: project?.name ?? "Unknown project",
        taskId: running.taskId, taskName: task?.name ?? "Unknown task"
    )
    // A timeslip the running-view query returned but that carries no timer start is a response
    // Ratchet can't date; counting from adoption undercounts, which is strictly safer than the
    // old midnight fallback's wild overcount.
    appState.startTracking(ref, startedAt: running.timerStartedAt ?? Date(), recordAsMostRecent: isFullyResolved)
}
```

- [ ] **Step 5: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 6: Update the harness replica and flip scenario 7**

The harness carries a line-for-line replica of `restoreRunningTimer` (it can't import the executable target). Update the replica in `Sources/Antagonise/main.swift` to match the new implementation exactly, then replace scenario 7's assertion:

```swift
    restoreRunningTimer(from: store, into: app)
    if case .tracking(let t, _) = app.screen {
        ok("still tracking, labelled \"\(t.taskName)\" — Stop stays reachable")
    } else {
        bad("dropped to idle with a timer still running server-side: \(app.screen)")
    }
```

- [ ] **Step 7: Build and run the harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ONLY=7 ./.build/debug/Antagonise & p=$!; ( sleep 20; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: `ok`, no `BUG`. Then run the Keychain cleanup command.

- [ ] **Step 8: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources/Ratchet/AppDelegate.swift Sources/RatchetCore/AppState.swift Tests/RatchetCoreTests/AppStateTests.swift && git commit -m "$(cat <<'EOF'
fix: keep tracking a running timer Ratchet can't name

restoreRunningTimer treated "the server reports a running timeslip I can't
resolve locally" the same as "nothing is running" and called stopTracking().
Since Stop only exists on the tracking screen, that left no route to stop a
timer that kept billing — reachable whenever the running task is Completed or
Hidden, its project archived, or a list fetch came back short.

It now adopts the timer with whatever names it can resolve and placeholders
for the rest, and only stops when the server genuinely reports nothing.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Secondary hardening

**Findings addressed:** the four "not reproduced, but visible in the code" items — writes issued before a refresh has established `currentUserURL`; an open menu offering "Edit" on an entry that became invoiced; log-out abandoning a running timer with no warning; and the unfixable-here duplicate risk when a `POST /timeslips` response is lost.

**Files:**
- Modify: `Sources/FreeAgentKit/FreeAgentDataStore.swift`
- Modify: `Sources/RatchetCore/StatusItemController.swift`
- Modify: `TODO.md`
- Test: `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`

**Interfaces:** no new public API.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FreeAgentKitTests/FreeAgentDataStoreTests.swift`:

```swift
func test_logTime_refusesBeforeARefreshHasIdentifiedTheUser() async throws {
    // Every write interpolates currentUserURL into the body or query. Before the first
    // successful refresh it is "", which asks FreeAgent to file the entry against no user at
    // all — or, for the running-timeslip query, against every user in the company.
    let transport = StubTransport()
    transport.responsesByPathSubstring = [(match: "", status: 200, body: Data("{}".utf8))]
    let (store, tokenStore) = makeStore(transport: transport)
    defer { tokenStore.clear() }

    do {
        _ = try await store.logTime(taskId: "t", projectId: "p", clientId: "c", date: Date(), hours: 1, comment: nil)
        XCTFail("expected a refusal before the first refresh")
    } catch let error as DataStoreError {
        XCTAssertEqual(error, DataStoreError.underlying("Ratchet hasn't loaded your FreeAgent account yet — choose Refresh and try again."))
    }
}
```

- [ ] **Step 2: Note that the test cannot be run** (see Global Constraints).

- [ ] **Step 3: Guard `currentUserURL`**

In `Sources/FreeAgentKit/FreeAgentDataStore.swift`, add:

```swift
    /// Every write interpolates `currentUserURL` into a body or query, and it is "" until the
    /// first successful `refresh()`. An empty `user=` filter is not a harmless no-op: it asks
    /// FreeAgent to file an entry against no user, or — on the running-timeslip query — to
    /// answer for the whole company, which would let Ratchet adopt or stop a colleague's timer.
    private func requireUserURL() throws -> String {
        guard !currentUserURL.isEmpty else {
            throw DataStoreError.underlying("Ratchet hasn't loaded your FreeAgent account yet — choose Refresh and try again.")
        }
        return currentUserURL
    }
```

Call it in `startTimer`, `logTime`, `updateTimeslip`, and in `fetchRunningTimeslipDTO` when no explicit `userURL` was passed, using the returned value in place of `currentUserURL`.

- [ ] **Step 4: Refuse to edit an entry that has since been invoiced**

In `Sources/RatchetCore/StatusItemController.swift`, in `runEditTimeEntryForm`, immediately after `guard response == .alertFirstButtonReturn else { return }` insert:

```swift
        // `rebuild()` is skipped while the menu is open, so the row that opened this sheet came
        // from the menu as it was built — possibly before a silent refresh learned the entry had
        // been invoiced. FreeAgent closes an invoiced entry off, and editing billed time from a
        // stale menu row is the one outcome worse than making the user look again.
        if dataStore.timeslips.first(where: { $0.id == entry.id })?.isInvoiced == true {
            presentValidationError("That entry has been added to an invoice since this menu was opened, so it can no longer be edited here.")
            return
        }
```

- [ ] **Step 5: Warn before logging out mid-timer**

In `Sources/RatchetCore/StatusItemController.swift`, replace `performLogOut()` with:

```swift
    /// Drops local session state and clears stored credentials via `onLogOut`. The single place
    /// "log out" happens, so the menu-driven Log Out and the forced logout below can't diverge.
    private func performLogOut() {
        appState.logOut()
        onLogOut?()
    }

    /// The menu-driven Log Out. Logging out does not stop the FreeAgent timer — the timeslip
    /// goes on accruing billable hours server-side with nothing left in the menu to say so —
    /// so a running timer gets a confirmation naming it rather than a silent abandonment.
    private func confirmAndLogOut() {
        if case .tracking(let task, _) = appState.screen {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A timer is still running"
            alert.informativeText = "Logging out won't stop the timer for \(task.taskName) — it will keep recording time in FreeAgent. Stop it first if that's not what you want."
            alert.addButton(withTitle: "Log Out Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        performLogOut()
    }
```

and point the menu action at it:

```swift
        logOut: { [weak self] in
            // Deferred for the same AppKit reason as the form prompts: running a modal
            // synchronously from inside menu action dispatch can leave the alert non-key.
            DispatchQueue.main.async { self?.confirmAndLogOut() }
        },
```

`handleSessionExpired()` keeps calling `performLogOut()` directly — there is nothing to confirm when the session is already dead.

- [ ] **Step 6: Record the one thing not fixed here**

Append to `TODO.md`, under whatever backlog heading the file already uses (read it first and match the style):

```markdown
- **Duplicate timeslips when a create response is lost.** If the network drops after FreeAgent
  processes `POST /timeslips` but before the response arrives, the entry exists server-side with
  no local record, and retrying "Log past time" creates a second one. `startTimer` self-heals
  (its next call re-queries the running view and adopts what it finds); `logTime` has no
  equivalent. A real fix needs either an idempotency key or a post-failure reconciliation query
  against the same task/day/hours — worth doing before Ratchet is used for anything invoiced.
```

- [ ] **Step 7: Build**

Run: `cd /Users/al/Documents/projects/ratchet && swift build`
Expected: `Build complete!`

- [ ] **Step 8: Run the whole harness**

```bash
cd /private/tmp/claude-501/-Users-al-Documents-projects-ratchet/66f0afc0-23c6-45ba-aacf-a91030814656/scratchpad/Antagonise && swift build && ( ./.build/debug/Antagonise & p=$!; ( sleep 90; kill -9 $p 2>/dev/null ) & wait $p )
```

Expected: **every** scenario 1-9 prints `ok` and no `BUG` line appears anywhere. If a scenario now fails because of the `requireUserURL` guard, its stub sequence must perform a `refresh()` first — fix the scenario, not the guard. Then run the Keychain cleanup command.

- [ ] **Step 9: Commit**

```bash
cd /Users/al/Documents/projects/ratchet && git add Sources Tests TODO.md && git commit -m "$(cat <<'EOF'
fix: guard writes before first refresh, stale edits, and silent log-out

Three smaller divergences: every write interpolated a currentUserURL that is
"" until the first refresh (an empty user filter asks FreeAgent to answer for
the whole company); the edit sheet could still be opened from a menu row built
before a refresh learned the entry was invoiced; and Log Out abandoned a
running timer without saying so.

Also records the remaining known gap — a lost POST /timeslips response leaves
no local record and a retry duplicates the entry — in TODO.md.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** Finding 1 → Task 5. Finding 2 → Task 7. Finding 3 → Task 6. Finding 4 → Task 8. Finding 5 → Task 4. Finding 6 → Task 1. Finding 7 → Task 2. Finding 8 → Task 3. The four secondary items → Task 9 (three fixed, the duplicate-on-lost-response one documented rather than faked).

**Ordering.** Tasks 1 and 2 are isolated and go first. Task 3 changes the model before Task 4 rewrites `refresh()`, so `refresh()` is rewritten once. Task 5 needs Task 4's single commit block. Task 7 needs Task 6's `runningTimeslip()`. Task 8 needs Task 3's `timerStartedAt`. **Run them strictly in order; do not parallelise.**

**Type consistency.** `day:` and `timerStartedAt:` (Task 3) are used under those exact names in Tasks 4, 7 and 8. `runningTimeslip()` (Task 6) is called under that exact name in Task 7. `recordAsMostRecent:` (Task 8) appears only in Task 8. `beginMutation()` (Task 5) is added to methods that Task 6 also edits — Task 6 keeps the `beginMutation()` line it finds at the top of `stopTimer`.
