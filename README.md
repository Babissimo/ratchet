# Ratchet

A macOS menu-bar time tracker for FreeAgent. SwiftPM package, AppKit, no
Xcode project.

Ratchet lives in the menu bar and lets you start and stop FreeAgent
timeslips without opening a browser tab. Click the tray icon to see your
FreeAgent tasks and projects, start tracking against one, and stop it again
later; the icon's rim and teeth turn green while a timer is running, so you
can tell at a glance whether the clock is going. It authenticates with your
FreeAgent account via OAuth and talks to the FreeAgent API directly. The one
exception is sign-in: FreeAgent requires an app secret that can't ship inside
an open-source app, so a small sign-in service ([`worker/`](worker/)) adds it
when Ratchet signs in and renews its access. Your timesheet data never passes
through it, and it keeps nothing.

## Building

```bash
swift build
```

`swift build` alone produces a bare Mach-O binary. macOS only routes the
`ratchet://` OAuth callback to an app Launch Services knows about, so build
and register a real `.app` bundle instead:

```bash
scripts/build-app.sh debug
```

See `CLAUDE.md` for building against FreeAgent's sandbox, and for testing
notes.

## Installation

Ratchet needs macOS 13 or later, on Intel or Apple silicon. With
[Homebrew](https://brew.sh):

```bash
brew install babissimo/ratchet/ratchet
```

Or download `Ratchet.app.zip` from the
[latest release](https://github.com/Babissimo/ratchet/releases/latest),
unzip it, and move `Ratchet.app` to Applications.

Ratchet isn't notarised (see `TODO.md` for why: it's a cost trade-off), so
macOS refuses to open a downloaded copy the first time, saying Apple could
not verify it is free of malware. The Homebrew install avoids this. For a
downloaded copy, you only need to get past it once:

- On macOS 15 and later, open Ratchet, choose **Done**, then go to
  System Settings → Privacy & Security and choose **Open Anyway** beside
  the message about Ratchet.
- On macOS 13 and 14, Control-click `Ratchet.app` in Finder, choose
  **Open**, then **Open** again.

## Releasing

```bash
scripts/release.sh 1.2.0
```

This tags `main` on GitHub (so push first) as `v1.2.0`; GitHub Actions then
builds and publishes the release, and the script points the
[Homebrew tap](https://github.com/Babissimo/homebrew-ratchet) at it.

## License

Copyright (C) 2026 Babissimo

GPLv3 — see [LICENSE](LICENSE).
