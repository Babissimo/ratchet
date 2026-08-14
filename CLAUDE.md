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

- `swift build` is the only verification available here. It compiles the three source targets
  but **not** the test targets, so a change that breaks a test file's *compilation* will pass
  `swift build` silently.
- After changing anything in `Sources/`, check test call sites by grep rather than assuming the
  compiler will catch them — particularly signature changes on the `DataStore` protocol, whose
  implementations include `Tests/RatchetCoreTests/Support/FakeDataStore.swift`.
- Tests written in this state are unrun code. Say so plainly rather than implying they pass.

Installing Xcode and running `xcode-select -s /Applications/Xcode.app` restores `swift test`.

## Local setup

`Sources/FreeAgentKit/Secrets.swift` is gitignored and required to compile `FreeAgentKit`. Copy
`Secrets.swift.example` next to it and fill in credentials from the FreeAgent Developer
Dashboard. A fresh clone or a new git worktree will not build until this exists.

## App bundle

`swift build` alone produces a bare Mach-O binary. macOS only routes the `ratchet://` OAuth
callback to an app Launch Services knows about, so use:

```bash
scripts/build-app.sh debug
```

That assembles `.build/Ratchet.app` around the built binary and registers it with
`lsregister`.

## Layout

- `RatchetCore` — models, `AppState`, `MenuBuilder`, `StatusItemController`, `RatchetIcon`. No
  FreeAgent dependency; the dependency runs the other way.
- `FreeAgentKit` — API client, OAuth, Keychain, DTOs, `FreeAgentDataStore`.
- `Ratchet` — the executable: `AppDelegate`, `URLSchemeHandler`, `main.swift`.
- `IconExporter` — dev-only tool that renders the app icon. Not shipped in the bundle.

## Conventions

Comments explain **why**, not what — the rationale for a non-obvious choice, the AppKit hazard
being worked around, the bug a line prevents. Match that density; don't add narrating comments.

Dates: FreeAgent's `dated_on` is a plain calendar day, not an instant. Route every conversion
through `CalendarDay` (`Sources/RatchetCore/CalendarDay.swift`), which works in the user's local
zone with an `en_US_POSIX` locale. Do not hand-roll a `yyyy-MM-dd` `DateFormatter`; pinning one
to UTC books time to the wrong day either side of the meridian, and omitting the POSIX locale
emits non-ASCII digits under some regional settings.
