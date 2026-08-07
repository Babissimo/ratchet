# Ratchet — FreeAgent API Integration Design

Date: 2026-08-07
Status: Approved

## Purpose

The Ratchet menu bar UI ([2026-08-06-ratchet-ui-design.md](2026-08-06-ratchet-ui-design.md))
is fully built against `FakeDataStore`, an in-memory stub. This spec covers
wiring the app to the real FreeAgent API: OAuth login, fetching
clients/projects/tasks, starting/stopping real timers, and creating
clients/projects/tasks/timeslips. Scope is the **sandbox** FreeAgent
environment; production is a one-line config change deferred until the app
is otherwise working end to end.

## Context / prior decisions

- UI spec's non-goals explicitly parked "what happens if the API stub
  reports an error" for this phase — real error handling is in scope here.
- `AppState.startTracking`/`stopTracking` currently only flip local
  in-memory state; they never call `DataStore`. This is a gap this spec
  closes — starting/stopping must actually start/stop a FreeAgent timer.
- Redirect URI is the custom URL scheme `ratchet://callback`. This means
  the app needs to become a real `.app` bundle (`Info.plist` with
  `CFBundleURLTypes`) rather than SPM's raw executable — that bundling
  work is in scope for this pass, done via a build script rather than
  converting to an Xcode project, to stay SPM-only.
- Client credentials (`client_id`/`client_secret`) live in a gitignored
  `Secrets.swift`, since they're app credentials for a personal
  single-user app, not secrets requiring Keychain-grade protection.
  User access/refresh tokens *do* go in the Keychain.

## New target: `FreeAgentKit`

A new SPM target, depending on `RatchetCore` (for the `DataStore` protocol
and `Ratchet*` models), keeping networking/auth/OAuth code out of
`RatchetCore`. The `Ratchet` executable depends on both `RatchetCore` and
`FreeAgentKit`. `FreeAgentKit` gets its own `FreeAgentKitTests` target.

```
Package.swift
  targets:
    RatchetCore        (existing — UI/state, unchanged shape)
    FreeAgentKit        (new — depends on RatchetCore)
    Ratchet             (existing executable — depends on RatchetCore, FreeAgentKit)
    RatchetCoreTests    (existing)
    FreeAgentKitTests   (new — depends on FreeAgentKit)
```

## Credentials & environment

- `Sources/FreeAgentKit/Secrets.swift` (gitignored) defines:
  ```swift
  enum FreeAgentSecrets {
      static let clientID = "..."
      static let clientSecret = "..."
  }
  ```
- `Sources/FreeAgentKit/Secrets.swift.example` (committed) is the same
  shape with placeholder values, so a fresh checkout fails to build with a
  clear "copy this file and fill in your credentials" signal rather than
  a confusing missing-symbol error.
- `FreeAgentEnvironment` constant holds the base URL
  (`https://api.sandbox.freeagent.com`) and the OAuth authorize/token URLs.
  Switching to production later means changing this one value.

## App bundling: `Ratchet.app`

SPM's `swift build` only produces a raw Mach-O executable — macOS will
only route a custom URL scheme to an app that Launch Services knows about
via a bundle's `Info.plist`. `scripts/build-app.sh`:

1. Runs `swift build -c release` (or `debug` via a flag, for local iteration).
2. Assembles `.build/Ratchet.app/Contents/{MacOS,Resources}`, copies the
   built binary into `Contents/MacOS/Ratchet`, and writes
   `Contents/Info.plist` (bundle id `com.ratchet.app`, `LSUIElement: true`
   to keep it a menu-bar-only accessory app with no Dock icon — matches
   `app.setActivationPolicy(.accessory)` already in `main.swift` — and
   `CFBundleURLTypes` registering the `ratchet` scheme).
3. Runs `/usr/bin/touch` on the bundle and, on first build,
   `lsregister -f` (via `/System/Library/Frameworks/CoreServices.framework/.../lsregister`)
   so Launch Services picks up the new URL scheme without waiting for a
   full Finder re-index — otherwise a stale `ratchet://` registration (or
   none at all) can silently swallow the redirect on first run.
4. Prints the path to the built `.app` so it can be launched directly
   (`open .build/Ratchet.app`) — running the raw executable directly
   (`.build/debug/Ratchet`) still works for everyday non-OAuth iteration,
   it just won't have a registered URL scheme.

This replaces `main.swift`/`AppDelegate.swift` invocation for anyone
testing the login flow specifically; day-to-day UI iteration on
already-authenticated state can keep using `swift run`.

## OAuth login flow

`FreeAgentAuthenticator` (in `FreeAgentKit`) owns the whole flow:

1. **Authorize**: build
   `https://api.sandbox.freeagent.com/v2/approve_app?client_id=...&response_type=code&redirect_uri=ratchet://callback&state=<random nonce>`
   and open it via `NSWorkspace.shared.open(_:)`.
2. **URL scheme callback**: `AppDelegate.applicationWillFinishLaunching`
   registers an Apple Event handler
   (`NSAppleEventManager.shared().setEventHandler(_:andSelector:forEventClass: kInternetEventClass, andEventID: kAEGetURL)`)
   — the standard macOS mechanism for receiving a custom-URL-scheme open,
   which fires even if the redirect arrives before the rest of the app has
   finished launching. The handler extracts the `ratchet://callback?...`
   URL from the event's direct-object descriptor and forwards it to
   `FreeAgentAuthenticator`, which parses `code`/`state`, checks `state`
   against the nonce from step 1 (CSRF guard), and resolves the
   in-flight `async` authorization call. A timeout (e.g. 3 minutes)
   surfaces as an error if the user never completes the browser flow —
   covers both "closed the tab" and "the URL scheme wasn't registered"
   failure modes.
3. **Token exchange**: `POST /v2/token_endpoint` with HTTP Basic auth
   (`client_id:client_secret`) and
   `grant_type=authorization_code&code=...&redirect_uri=...`. Response
   (`access_token`, `refresh_token`, `expires_in`) is wrapped in a
   `FreeAgentTokens` struct with a computed `expiresAt` and stored in the
   macOS Keychain via a small `KeychainTokenStore` (generic password item,
   service `"com.ratchet.freeagent"`, JSON-encoded value).
4. **Refresh**: `FreeAgentAPIClient` checks `expiresAt` before each request;
   if expired (or about to expire — 60s buffer), calls
   `grant_type=refresh_token` first and re-stores the new pair. Also
   retries a request exactly once on an unexpected `401` (covers clock
   skew / revoked-but-not-yet-known-expired tokens).
5. **Launch check**: `AppDelegate` asks `KeychainTokenStore` for existing
   tokens before deciding the initial screen. If present, skip the
   logged-out screen and go straight to `appState.logIn()` + an initial
   `dataStore.refresh()`.

`Log out` (existing `MenuActions.logOut`) additionally clears the Keychain
entry.

## Networking + model mapping

- `FreeAgentAPIClient`: single async method
  `func request<T: Decodable>(_ path: String, method: String, query: [URLQueryItem], body: Encodable?) async throws -> T`.
  Injects `Authorization: Bearer <token>` (refreshing first if needed, see
  above), encodes/decodes FreeAgent's `{"resource_name": {...}}` /
  `{"resource_names": [...]}` envelopes, and follows pagination
  (`page`/`per_page` query params + `Link`-style continuation) transparently
  for list endpoints, returning the fully-collected array.
- Errors map to a `FreeAgentError` enum: `.network(Error)`,
  `.unauthorized`, `.decoding(Error)`, `.apiError(status: Int, message: String?)`.
- **ID strategy**: FreeAgent resources are addressed by full URL
  (e.g. `https://api.sandbox.freeagent.com/v2/projects/1`). Rather than
  extracting a bare numeric ID and reconstructing URLs later,
  `RatchetClient`/`RatchetProject`/`RatchetTask`/`RatchetTimeslip.id` is
  set directly to that URL string. This matches what FreeAgent's own
  filter/reference params expect (e.g. `POST /v2/tasks?project=<url>`),
  avoiding round-trip reconstruction logic.
- `FreeAgentDataStore: DataStore` (in `FreeAgentKit`) is the single
  conforming type. Internally holds the current `[RatchetClient]` tree,
  `accountEmail`, `timeslips`, `lastRefreshedAt` as its own state, mutated
  only by `refresh()` and the mutating protocol methods below.

## `DataStore` protocol changes

Mutating/fetching methods become `async throws`:

```swift
public protocol DataStore: AnyObject {
    var clients: [RatchetClient] { get }
    var accountEmail: String { get }
    var timeslips: [RatchetTimeslip] { get }
    var lastRefreshedAt: Date? { get }

    func addTask(...) async throws -> RatchetTask
    func addClient(...) async throws -> RatchetClient
    func addProject(...) async throws -> RatchetProject
    func logTime(...) async throws -> RatchetTimeslip
    func refresh() async throws

    // New — closes the gap where start/stop never touched the API.
    func startTimer(taskId: String, projectId: String, clientId: String) async throws -> RatchetTimeslip
    func stopTimer() async throws -> RatchetTimeslip?
}
```

Return types drop the `?` in favor of `throws` — the fake/local store
returning `nil` for "client/project/task not found" becomes throwing a
`DataStoreError.notFound` instead, so callers have one failure channel
(a thrown error → show an alert) rather than two (`nil` vs thrown).

A synchronous function body can satisfy an `async` protocol requirement in
Swift, so `FakeDataStore`'s existing method bodies are unchanged — only
the signatures gain `async throws`, and call sites (tests,
`StatusItemController`) add `await`/`try`. `FakeDataStore` gets a minimal
in-memory `startTimer`/`stopTimer` (tracks "currently running timeslip
id" as a private var) so it stays a faithful stand-in for UI tests.

`FreeAgentDataStore.startTimer`:
1. Look for an existing timeslip today for `(task, project, user)`
   (`GET /v2/timeslips?task=...&project=...&from_date=today&to_date=today&user=me`).
2. If found and not running, `POST /v2/timeslips/:id/timer`. If none
   found, `POST /v2/timeslips` with `hours=0` first, then start its timer.
3. Return the resulting timeslip (its `timer.start_from` becomes the
   elapsed-time baseline the UI ticks from — see below).

`FreeAgentDataStore.stopTimer`: `DELETE /v2/timeslips/:id/timer` on
whichever timeslip is currently running (tracked from the last
`startTimer`/`refresh` call); returns the updated timeslip, or `nil` if
nothing was running.

`refresh()` additionally calls
`GET /v2/timeslips?view=running&user=me` to detect a timer already
running — e.g. the app was relaunched, or the timer was started from
FreeAgent's own web UI — and surfaces that timeslip so `AppDelegate` can
restore `AppState.startTracking` with the *real* start time instead of
"now."

## Wiring changes in `StatusItemController`

Each `MenuActions` closure that touches `dataStore` wraps the call in
`Task { @MainActor in ... }`:

```swift
startTracking: { [weak self] task in
    guard let self else { return }
    Task { @MainActor in
        do {
            let timeslip = try await self.dataStore.startTimer(
                taskId: task.taskId, projectId: task.projectId, clientId: task.clientId)
            self.appState.startTracking(task, startedAt: timeslip.timerStartedAt ?? Date())
        } catch {
            self.presentAPIError(error, action: "start tracking")
        }
    }
},
```

(`AppState.startTracking` gains an explicit `startedAt` parameter instead
of always using its injected clock, so a resumed timeslip's real start
time is honored rather than restarting the visible elapsed count at zero.)

Same pattern for `stopTracking`, `logIn`, `refresh`, `addTask`,
`addClient`, `addProject`, `logPastTime`, `logPastTimeForNewTask`. Failures
show an `NSAlert` via a new `presentAPIError(_:action:)` helper — same
visual pattern as the existing `presentValidationError`, message built
from `FreeAgentError`'s description (e.g. "Couldn't start tracking:
no connection." / "Couldn't start tracking: session expired, please log
in again.").

`AppDelegate.applicationDidFinishLaunching` becomes:
```swift
let tokenStore = KeychainTokenStore()
let dataStore = FreeAgentDataStore(tokenStore: tokenStore, environment: .sandbox)
let appState = AppState()
statusItemController = StatusItemController(appState: appState, dataStore: dataStore)
if tokenStore.hasValidTokens {
    appState.logIn()
    Task { @MainActor in
        try? await dataStore.refresh()
        if let running = dataStore.currentRunningTimeslip {
            appState.startTracking(running.taskRef, startedAt: running.timerStartedAt)
        }
        statusItemController?.rebuild()
    }
}
```

## Testing approach

- `FreeAgentKitTests`: a `URLProtocol` stub (or an injected transport
  closure `(URLRequest) async throws -> (Data, HTTPURLResponse)` on
  `FreeAgentAPIClient`, to avoid `URLProtocol`'s global-registration
  awkwardness in parallel test runs) drives request-building, pagination,
  401-triggers-refresh-then-retry, and JSON mapping tests without any
  real network access.
- The Apple Event handler itself (actual OS delivery of a `ratchet://`
  open) isn't unit-testable — the URL-parsing/CSRF-check logic it calls
  into is factored as a pure function (`ratchet://callback?code=...&state=...`
  → `Result<AuthCode, AuthError>`) and tested directly. End-to-end delivery
  is verified manually: `open 'ratchet://callback?code=test&state=...'`
  after building via `scripts/build-app.sh` should reach the running app.
- `RatchetCoreTests`: existing tests updated for the `async throws`
  protocol (mechanical — add `await`, adjust `nil`-return assertions to
  `XCTAssertThrowsError`). `FakeDataStoreTests` gains cases for the new
  `startTimer`/`stopTimer` methods.
- No live sandbox-account integration test in CI — sandbox credentials
  are a local developer secret, not something to run in an automated
  pipeline for a single-user personal app.

## Non-goals for this pass

- Production API (`api.freeagent.com`) — sandbox only; switching later is
  a one-constant change in `FreeAgentEnvironment`.
- Code signing / notarization of `Ratchet.app` — fine for local `open`-ing
  on the developer's own Mac; not addressed here since there's no
  distribution to other machines yet.
- Rate-limit backoff/retry tuning beyond a single 401-retry — basic
  pagination only.
- `Launch at login` real implementation — still a no-op toggle in
  `AppState`, unrelated to this integration.
- Multi-account / switching FreeAgent accounts within one company file.

## Considered and dropped

- **Local loopback HTTP listener (`http://127.0.0.1:53682/callback`)
  instead of a custom URL scheme.** Considered first as a way to avoid
  bundling work — no `Network.framework` listener code needed, no
  `Info.plist`. Revisited: the bundling work is small (one shell script)
  and worth doing now rather than carrying two OAuth-redirect code paths
  (loopback now, scheme later) across two separate change sets.
- **Converting to an Xcode project for the bundling step.** Would give
  Xcode's build UI and integrated debugging, but means maintaining a
  `.xcodeproj` alongside (or instead of) `Package.swift`, diverging from
  how the project has been built so far for a benefit not needed yet — a
  shell script achieves the one thing actually required (a valid
  `.app` with the right `Info.plist`).
- **Keychain for `client_id`/`client_secret`.** These are the *app's*
  credentials (like any native OAuth client), not the user's — a
  gitignored source file matches how a solo developer already manages
  other local secrets, and avoids Keychain UI prompts for something that
  isn't user data.
- **Blocking/synchronous network calls in `FreeAgentDataStore`** (e.g. via
  a semaphore) to avoid touching `DataStore`'s protocol signature. Rejected:
  blocks the main thread during every menu action, and Swift concurrency
  is fully available at the macOS 13+ deployment target — no reason to
  fight it.

## Future additions (not this pass)

- Production environment switch.
- Code signing / notarization for distribution beyond the developer's own Mac.
- `Launch at login` via `SMAppService`.
- Background/periodic refresh (currently only on launch, explicit
  "Refresh projects & tasks," and after mutations).
