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

Ratchet isn't signed or notarized (see `TODO.md` for why — it's a cost
tradeoff, not an oversight), so on first launch Gatekeeper will refuse to
open it with "Apple could not verify this app is free of malware." This is
expected for a small unsigned open-source utility. To run it anyway:
right-click (or Control-click) `Ratchet.app` in Finder, choose **Open**,
then confirm **Open** again in the dialog that appears. You only need to do
this once — subsequent launches (including via Spotlight or Dock) work
normally.

## License

Copyright (C) 2026 Babissimo

GPLv3 — see [LICENSE](LICENSE).
