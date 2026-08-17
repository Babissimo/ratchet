# FreeAgent Data Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two silent, automatic FreeAgent refresh triggers — on menu open and on system wake — both gated so they skip the network call if the data was already refreshed within the last 2 minutes, without adding any background polling or user-facing setting.

**Architecture:** A single private helper on `StatusItemController`, `silentlyRefreshIfStale()`, does the gate check and the actual `dataStore.refresh()` → `restoreRunningTimer()` → `rebuild()` sequence, swallowing all errors except session expiry. Two triggers call it: an `NSMenuDelegate` forwarding object wired to the status item's menu (`menuWillOpen`), and an `NSWorkspace.didWakeNotification` observer. The existing manual "Refresh projects & tasks" menu item is untouched and keeps calling `dataStore.refresh()` directly, unconditionally.

**Tech Stack:** Swift, AppKit (`NSMenuDelegate`, `NSWorkspace`), Swift Concurrency (`Task`, `async`/`await`), XCTest.

## Global Constraints

- Staleness threshold is a hardcoded constant: **2 minutes** (120 seconds). Not a setting.
- No new `UserDefaults` keys, no new Settings submenu rows, no background `Timer`.
- The manual "Refresh projects & tasks" item (`MenuBuilder.swift:245`, `MenuActions.refresh`) must remain unconditional — never routed through the staleness gate.
- Background refresh failures are silent except `error.indicatesSessionExpired`, which must call `handleSessionExpired()` — same contract the existing manual refresh and launch-time refresh already follow.
- Per `CLAUDE.md`, `swift test` does not run on this machine. Every task's test step is `swift build` (compiles `Sources/`, not `Tests/`) plus a manual grep-based sanity check of the test code — tests are written but unrun. Say so; don't claim they pass.
- Dates route through existing project conventions where relevant; this feature touches no `dated_on`/calendar-day logic, so `CalendarDay` isn't involved.

---

## File Structure

- **Modify:** `Sources/RatchetCore/StatusItemController.swift` — add clock injection, the shared `silentlyRefreshIfStale()` helper, a small private `MenuOpenDelegate: NSObject, NSMenuDelegate` forwarding class, wire the menu-open trigger into `rebuild()`, and add the wake-notification observer to `init`/`deinit`.
- **Modify:** `Tests/RatchetCoreTests/Support/FakeDataStore.swift` — add error-injection support (`refreshError`) so tests can simulate a failed background refresh, including a session-expiry failure.
- **Create:** `Tests/RatchetCoreTests/Support/FakeSessionExpiredError.swift` — a minimal `SessionExpiredError`-conforming test double.
- **Modify:** `Tests/RatchetCoreTests/StatusItemControllerTests.swift` — add tests for both triggers' gating and error handling.

---

### Task 1: `FakeDataStore` error injection + `FakeSessionExpiredError` test double

**Files:**
- Modify: `Tests/RatchetCoreTests/Support/FakeDataStore.swift:196-199` (the `refresh()` method)
- Create: `Tests/RatchetCoreTests/Support/FakeSessionExpiredError.swift`
- Test: `Tests/RatchetCoreTests/Support/FakeDataStoreErrorInjectionTests.swift`

**Interfaces:**
- Produces: `FakeDataStore.refreshError: Error?` (settable, default `nil`) — when set, `refresh()` throws it instead of succeeding. `FakeSessionExpiredError: SessionExpiredError` — a `struct` with `isSessionExpired: Bool` (default `true`).

- [ ] **Step 1: Write the failing test**

Create `Tests/RatchetCoreTests/Support/FakeDataStoreErrorInjectionTests.swift`:

```swift
import XCTest
@testable import RatchetCore

@MainActor
final class FakeDataStoreErrorInjectionTests: XCTestCase {
    func test_refresh_throwsInjectedError() async {
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = FakeSessionExpiredError()

        do {
            try await dataStore.refresh()
            XCTFail("expected refresh() to throw the injected error")
        } catch {
            XCTAssertTrue(error.indicatesSessionExpired)
        }
        XCTAssertEqual(dataStore.refreshCount, 0, "a thrown refresh() must not count as a completed refresh")
    }

    func test_refresh_withoutInjectedError_succeedsAsBefore() async throws {
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)
        XCTAssertNotNil(dataStore.lastRefreshedAt)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `value of type 'FakeDataStore' has no member 'refreshError'` and `cannot find 'FakeSessionExpiredError' in scope`.

- [ ] **Step 3: Add `FakeSessionExpiredError`**

Create `Tests/RatchetCoreTests/Support/FakeSessionExpiredError.swift`:

```swift
import Foundation
@testable import RatchetCore

/// Minimal `SessionExpiredError` conformance for tests that need to simulate a dead FreeAgent
/// session without depending on `FreeAgentKit` (which `RatchetCoreTests` doesn't link against).
struct FakeSessionExpiredError: SessionExpiredError {
    var isSessionExpired: Bool = true
}
```

- [ ] **Step 4: Add `refreshError` to `FakeDataStore` and make `refresh()` honor it**

In `Tests/RatchetCoreTests/Support/FakeDataStore.swift`, add a stored property near `refreshCount` (around line 8):

```swift
    private(set) var refreshCount = 0
    /// Set by tests to make the next `refresh()` call throw instead of succeeding, simulating a
    /// network failure or a dead session (via `FakeSessionExpiredError`).
    var refreshError: Error?
```

Replace the `refresh()` method (lines 196-199):

```swift
    func refresh() async throws {
        if let refreshError {
            throw refreshError
        }
        refreshCount += 1
        lastRefreshedAt = clock()
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift build`
Expected: PASS to compile. (Actual test execution is unavailable per `CLAUDE.md` — confirm by reading the test logic that `refreshError` set before the call causes `refresh()` to throw before touching `refreshCount`/`lastRefreshedAt`, and that leaving it `nil` preserves the prior increment-and-stamp behavior every existing test already relies on.)

- [ ] **Step 6: Commit**

```bash
git add Tests/RatchetCoreTests/Support/FakeDataStore.swift Tests/RatchetCoreTests/Support/FakeSessionExpiredError.swift Tests/RatchetCoreTests/Support/FakeDataStoreErrorInjectionTests.swift
git commit -m "test: add FakeDataStore error injection for refresh() failures"
```

---

### Task 2: `silentlyRefreshIfStale()` + menu-open trigger

**Files:**
- Modify: `Sources/RatchetCore/StatusItemController.swift`
  - `init` signature (lines 46-53) and body (lines 53-74)
  - `rebuild()` (lines 324-335)
  - new private method + new private `MenuOpenDelegate` class, added immediately after `rebuild()` — keeping the delegate type next to the one method (`rebuild()`) that assigns it, rather than separated at the bottom of the file
- Test: `Tests/RatchetCoreTests/StatusItemControllerTests.swift`

**Interfaces:**
- Consumes: `DataStore.lastRefreshedAt: Date?`, `DataStore.refresh() async throws`, `StatusItemController.restoreRunningTimer: RestoreRunningTimerHandler`, `StatusItemController.rebuild()` (already private, same file), `StatusItemController.handleSessionExpired()` (already `public`, same type), `Error.indicatesSessionExpired` (`Sources/RatchetCore/SessionExpiredError.swift`).
- Produces: `StatusItemController.init(..., now: @escaping () -> Date = Date.init)` — new trailing parameter, defaulted so every existing call site keeps compiling untouched. `private func silentlyRefreshIfStale()` — no return value, fire-and-forget. `private static let staleRefreshThreshold: TimeInterval = 120`. Both consumed by Task 3.

- [ ] **Step 1: Write the failing test**

Add to `Tests/RatchetCoreTests/StatusItemControllerTests.swift` (inside `StatusItemControllerTests`, after the existing two tests):

```swift
    func test_menuWillOpen_refreshesWhenNeverRefreshed() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1)
    }

    func test_menuWillOpen_skipsRefreshWhenRecentlyRefreshed() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        let fixedNow = Date()
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { fixedNow }
        )
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1, "a refresh 0s ago is well within the 2-minute staleness threshold")
    }

    func test_menuWillOpen_refreshesWhenStaleBeyondThreshold() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        // 3 minutes after the refresh above — past the 2-minute threshold.
        let laterNow = dataStore.lastRefreshedAt!.addingTimeInterval(180)
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { laterNow }
        )
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 2)
    }

    func test_menuWillOpen_refreshFailure_isSilent() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = DataStoreError.notFound
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        // Must not crash and must not present a modal alert (no way to assert "no alert shown"
        // directly without blocking on NSAlert.runModal — the absence of a hang/crash here,
        // combined with the menu still reflecting the logged-in idle screen below, is the
        // signal that no alert was raised for this background failure).
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Start timer")
    }

    func test_menuWillOpen_sessionExpired_logsOut() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        dataStore.refreshError = FakeSessionExpiredError()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        let menu = controller.statusItemForTesting.menu!
        menu.delegate?.menuWillOpen?(menu)
        await drainMainActorQueue()

        XCTAssertEqual(controller.statusItemForTesting.menu?.items.first?.title, "Log in with browser")
    }

    /// Fire-and-forget `Task { @MainActor in ... }` work (like `silentlyRefreshIfStale()`) needs
    /// somewhere to run before assertions read its effects. `FakeDataStore.refresh()` never
    /// suspends on real I/O, so a handful of yields is enough for it to complete — cheaper and
    /// less flaky than a fixed `Task.sleep`.
    private func drainMainActorQueue() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
```

Note: `test_menuWillOpen_refreshFailure_isSilent` requires `handleSessionExpired()`'s alert path NOT to fire for a non-session error — it relies on `DataStoreError.notFound` (`Sources/RatchetCore/DataStoreError.swift`) not conforming to `SessionExpiredError`, so `error.indicatesSessionExpired` is `false` and the alert path in Step 3 below is skipped entirely, avoiding a blocking `NSAlert.runModal()` in the test run.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `argument passed to call that takes no arguments` (the `now:` parameter doesn't exist yet) and, once that's fixed by Step 3, the tests would fail at runtime for lack of the gating logic — but since `swift test` doesn't run here, confirm the *compile* failure now, and treat runtime correctness as unrun/reviewed-by-hand until `swift test` is available.

- [ ] **Step 3: Implement `silentlyRefreshIfStale()`, clock injection, and the menu-open wiring**

In `Sources/RatchetCore/StatusItemController.swift`, change the `init` signature (replace lines 46-53):

```swift
    public init(
        appState: AppState,
        dataStore: DataStore,
        statusBar: NSStatusBar = .system,
        performLogin: @escaping LoginHandler = {},
        restoreRunningTimer: @escaping RestoreRunningTimerHandler = {},
        setLaunchAtLogin: @escaping SetLaunchAtLoginHandler = { _ in false },
        now: @escaping () -> Date = Date.init
    ) {
```

Add `self.now = now` to the assignment block (after line 59, `self.setLaunchAtLogin = setLaunchAtLogin`):

```swift
        self.setLaunchAtLogin = setLaunchAtLogin
        self.now = now
```

Add the stored property next to the other private stored properties (near line 37, after `private var isChangingLaunchAtLogin = false`):

```swift
    private var isChangingLaunchAtLogin = false
    private let now: () -> Date
```

Replace `rebuild()` (lines 324-335) to wire the delegate onto every freshly-built menu:

```swift
    private func rebuild() {
        let menu = MenuBuilder.build(state: appState, dataStore: dataStore, actions: actions)
        menu.delegate = menuOpenDelegate
        statusItem.menu = menu
        if case .tracking = appState.screen {
            // Index 0 is the disabled elapsed-time line built by MenuBuilder.buildTracking.
            elapsedMenuItem = menu.items[0]
        } else {
            elapsedMenuItem = nil
        }
        updateIcon()
        updateTimer()
    }
```

Add the delegate object and the shared refresh helper right after `rebuild()`:

```swift
    /// `NSMenu.delegate` is an Objective-C protocol, so forwarding `menuWillOpen` needs an
    /// `NSObject`-rooted type — `StatusItemController` itself stays a plain Swift class rather
    /// than picking up `NSObject` for this alone. `NSMenu.delegate` is unowned, so this must be
    /// held strongly somewhere for the menu's lifetime; `rebuild()` assigns it to every freshly
    /// built menu.
    private final class MenuOpenDelegate: NSObject, NSMenuDelegate {
        private let onOpen: () -> Void

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
        }

        func menuWillOpen(_ menu: NSMenu) {
            onOpen()
        }
    }

    private lazy var menuOpenDelegate = MenuOpenDelegate { [weak self] in
        self?.silentlyRefreshIfStale()
    }

    /// Two minutes: long enough that opening the menu twice in quick succession, or a rapid
    /// sleep/wake, doesn't fire a second network round-trip; short enough that data is never
    /// stale for long while the app is actually being used.
    private static let staleRefreshThreshold: TimeInterval = 120

    /// Shared by the menu-open and system-wake triggers. Skips the network round-trip entirely
    /// if `dataStore` was already refreshed within `staleRefreshThreshold`. Never blocks the
    /// caller — the menu (or whatever triggered this) is already visible/handled by the time
    /// this returns; a successful refresh's `rebuild()` just makes the *next* open reflect fresh
    /// data. The manual "Refresh projects & tasks" item bypasses this entirely by calling
    /// `dataStore.refresh()` directly, so it's never subject to this gate.
    private func silentlyRefreshIfStale() {
        if let lastRefreshedAt = dataStore.lastRefreshedAt,
           now().timeIntervalSince(lastRefreshedAt) < Self.staleRefreshThreshold {
            return
        }
        Task { @MainActor in
            do {
                try await self.dataStore.refresh()
                // Same adoption the manual refresh and launch/login paths do — without this, a
                // timer started or stopped elsewhere wouldn't show up even after this silent
                // refresh succeeds.
                self.restoreRunningTimer()
                self.rebuild()
            } catch where error.indicatesSessionExpired {
                self.handleSessionExpired()
            } catch {
                // A background refresh failing (e.g. no network) isn't worth interrupting the
                // user over — same reasoning as AppDelegate's launch-time refresh. The next
                // menu open or wake just tries again.
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build`
Expected: PASS to compile. As with Task 1, `swift test` is unavailable on this machine — read back through each new test against the implementation to confirm the gating arithmetic (`now().timeIntervalSince(lastRefreshedAt) < 120`) and error routing match, since this is otherwise unrun code.

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/StatusItemController.swift Tests/RatchetCoreTests/StatusItemControllerTests.swift
git commit -m "feat: silently refresh FreeAgent data on menu open when stale"
```

---

### Task 3: System-wake trigger

**Files:**
- Modify: `Sources/RatchetCore/StatusItemController.swift`
  - `init` body (after the block added in Task 2)
  - `deinit` (lines 76-79)
- Test: `Tests/RatchetCoreTests/StatusItemControllerTests.swift`

**Interfaces:**
- Consumes: `StatusItemController.silentlyRefreshIfStale()` (Task 2, same file), `NSWorkspace.shared.notificationCenter`, `NSWorkspace.didWakeNotification`.
- Produces: nothing new consumed by later tasks — this is the last task.

- [ ] **Step 1: Write the failing test**

Add to `Tests/RatchetCoreTests/StatusItemControllerTests.swift`:

```swift
    func test_systemWake_refreshesWhenStale() async {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        let controller = StatusItemController(appState: appState, dataStore: dataStore)
        self.controller = controller
        appState.logIn()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1)
    }

    func test_systemWake_skipsRefreshWhenRecentlyRefreshed() async throws {
        let appState = AppState()
        let dataStore = FakeDataStore.seeded()
        try await dataStore.refresh()
        XCTAssertEqual(dataStore.refreshCount, 1)

        let fixedNow = Date()
        let controller = StatusItemController(
            appState: appState, dataStore: dataStore,
            now: { fixedNow }
        )
        self.controller = controller
        appState.logIn()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drainMainActorQueue()

        XCTAssertEqual(dataStore.refreshCount, 1, "a refresh 0s ago is well within the 2-minute staleness threshold")
    }
```

(Reuses the `drainMainActorQueue()` helper added in Task 2 — no duplicate needed.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: builds fine syntactically (these tests only call existing public API + a real `NSWorkspace` notification), but would fail at runtime today since nothing observes `didWakeNotification` yet. Confirm by reading: `StatusItemController` currently has no wake observer, so `dataStore.refreshCount` would stay `0` after the post in the first test — the assertion `XCTAssertEqual(dataStore.refreshCount, 1)` would fail once `swift test` is available.

- [ ] **Step 3: Add the wake observer**

In `Sources/RatchetCore/StatusItemController.swift`, add a stored property next to `appearanceObservation` (near line 38):

```swift
    private var appearanceObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
```

Add the registration at the end of `init`'s body, after the `appearanceObservation` block (after line 73, the closing `}` of that KVO block, still inside `init`):

```swift
        // A sleeping Mac is the single biggest source of staleness — a timer stopped elsewhere
        // hours ago wouldn't otherwise be caught until the next menu open. Gated by the same
        // `silentlyRefreshIfStale()` threshold as the menu-open trigger, so rapid sleep/wake
        // (e.g. lid flutter) doesn't fire repeated requests.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.silentlyRefreshIfStale()
        }
    }
```

(This replaces the `init`'s closing `}` — the new block's trailing `}` is the one that closes `init`.)

Update `deinit` (lines 76-79) to remove the observer:

```swift
    deinit {
        elapsedTimer?.invalidate()
        appearanceObservation?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build`
Expected: PASS to compile. Read back through the two new tests against the implementation: posting `didWakeNotification` should invoke the closure synchronously (main-thread `NotificationCenter` delivery), which calls `silentlyRefreshIfStale()`, same gating logic already verified by Task 2's tests. Unrun, per `CLAUDE.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RatchetCore/StatusItemController.swift Tests/RatchetCoreTests/StatusItemControllerTests.swift
git commit -m "feat: silently refresh FreeAgent data on system wake when stale"
```

---

## Final check

- [ ] **Run `swift build` once more from a clean state to confirm the whole target still compiles:**

```bash
swift build
```

Expected: PASS. This is the only verification available on this machine (per `CLAUDE.md`); `Tests/` compiling is not checked by `swift build`, so also re-read every new/changed test in `StatusItemControllerTests.swift`, `FakeDataStore.swift`, and `FakeSessionExpiredError.swift` once more for obvious signature mismatches against the final `StatusItemController` code, since a broken test *file* would compile-fail silently from `swift build`'s perspective.
