# Ratchet

A macOS menu-bar time tracker for FreeAgent. SwiftPM package, AppKit, no
Xcode project.

Click the tray icon to start and stop tracking against FreeAgent tasks and
projects; the icon's rim and teeth turn green while a timer is running.

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

See `CLAUDE.md` for the local setup required before either of these will
compile (`Sources/FreeAgentKit/Secrets.swift`), and for testing notes.

## Installation

Ratchet isn't signed or notarized (see `TODO.md` for why — it's a cost
tradeoff, not an oversight), so on first launch Gatekeeper will refuse to
open it with "Apple could not verify this app is free of malware." This is
expected for a small unsigned open-source utility. To run it anyway:
right-click (or Control-click) `Ratchet.app` in Finder, choose **Open**,
then confirm **Open** again in the dialog that appears. You only need to do
this once — subsequent launches (including via Spotlight or Dock) work
normally.
