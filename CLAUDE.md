# Ratchet

A macOS menu-bar time tracker for FreeAgent. SwiftPM package, AppKit, no Xcode project.

## Building and testing

Build with:

```bash
swift build
```

**`swift test` does not work on this machine.** `xcode-select -p` points at
`/Library/Developer/CommandLineTools`, and there is no `Xcode.app` and no entry in
`/Library/Developer/Toolchains`. XCTest ships with Xcode, not with the Command Line Tools, so
every test target fails to compile with `no such module 'XCTest'` before a single test runs.

Consequences to keep in mind:

- `swift build` compiles the source targets but **not** the test targets, so a change that
  breaks a test file's *compilation* passes `swift build` silently. This is not hypothetical:
  `Tests/FreeAgentKitTests/FreeAgentAPIClientTests.swift` carried an unbalanced paren from
  `2057c7c` until 2026-08-20, so that target had never compiled at all.
- After changing anything in `Sources/`, check test call sites rather than assuming the compiler
  will catch them — particularly signature changes on the `DataStore` protocol, whose
  implementations include `Tests/RatchetCoreTests/Support/FakeDataStore.swift`.
- Tests written in this state are unrun code. Say so plainly rather than implying they pass.

Two things partly close the gap, and both are worth running before claiming a change is good:

- **Type-check the test targets.** Build a minimal XCTest shim module, then
  `swiftc -typecheck -target x86_64-apple-macosx13.0` the test files against the debug
  `-enable-testing` `.swiftmodule`s. That catches broken call sites even though nothing can run
  the assertions.
- **Run the state-divergence harness**, which *does* execute:

  ```bash
  swift run Antagonise
  ```

  Ten scenarios drive the real `FreeAgentDataStore` against a stub transport and assert the
  fixed behaviour for every local/remote divergence fixed in `cbcb28f..HEAD` — a stale cache
  stopping the wrong timer, a refresh clobbering a just-started one, a re-dated edit unsorting
  the timeslip list, and so on. It exits non-zero on any regression. Run it after touching
  `FreeAgentDataStore`, `AppState`, or `restoreRunningTimer`; see
  `Sources/Antagonise/main.swift` for what each scenario covers.

Installing Xcode and running `xcode-select -s /Applications/Xcode.app` restores `swift test`.

## Sign-in and environments

The app carries no FreeAgent credentials, so a fresh clone builds as is. Sign-in starts at, and
every token request goes to, Ratchet's sign-in service (`worker/`, a Cloudflare Worker at
`auth.ratchet.babissimo.net`), which holds the client ID and secret. Test it with
`npm test` in `worker/`; `worker/README.md` covers deploying it.

Builds target FreeAgent production. Build with `-Xswiftc -DFREEAGENT_SANDBOX` (or
`FREEAGENT_SANDBOX=1 scripts/build-app.sh debug`) to target the sandbox instead.

## App bundle

`swift build` alone produces a bare Mach-O binary. macOS only routes the `ratchet://` OAuth
callback to an app Launch Services knows about, so use:

```bash
scripts/build-app.sh debug
```

That assembles `.build/Ratchet.app` around the built binary and registers it with
`lsregister`.

## Layout

- `RatchetCore`: models, `AppState`, `MenuBuilder`, `StatusItemController`, `RatchetIcon`. No
  FreeAgent dependency; the dependency runs the other way.
- `FreeAgentKit`: API client, OAuth, Keychain, DTOs, `FreeAgentDataStore`.
- `Ratchet`, the executable: `AppDelegate`, `URLSchemeHandler`, `main.swift`.
- `IconExporter`: dev-only tool that renders the app icon. Not shipped in the bundle.
- `Antagonise`: dev-only regression harness for local/remote state divergence (see "Building
  and testing" above). Not shipped in the bundle.
- `worker/`: the sign-in service (see "Sign-in and environments" above). JavaScript, not part
  of the Swift package.

## Conventions

Comments explain **why**, not what — the rationale for a non-obvious choice, the AppKit hazard
being worked around, the bug a line prevents. Match that density; don't add narrating comments.

Dates: FreeAgent's `dated_on` is a plain calendar day, not an instant. Route every conversion
through `CalendarDay` (`Sources/RatchetCore/CalendarDay.swift`), which works in the user's local
zone with an `en_US_POSIX` locale. Do not hand-roll a `yyyy-MM-dd` `DateFormatter`; pinning one
to UTC books time to the wrong day either side of the meridian, and omitting the POSIX locale
emits non-ASCII digits under some regional settings.
