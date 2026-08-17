# Ratchet — Keeping FreeAgent Data Fresh

Date: 2026-08-17
Status: Approved

## Purpose

Ratchet currently only fetches clients/projects/tasks/timeslip state from
FreeAgent at launch (if logged in) and when the user clicks "Refresh
projects & tasks" in the Settings submenu. Between those points, the menu
can show stale data — most importantly, a timer started or stopped
elsewhere (the FreeAgent web app, another device) won't be reflected until
the user happens to hit manual refresh.

This spec adds two automatic, silent refresh triggers so the menu is
usually fresh without the user thinking about it, while keeping the app
free of background polling and any new user-facing setting.

## Context / prior decisions

- Considered and rejected: a user-configurable background poll interval
  (the original idea prompting this spec). FreeAgent's API allows 120
  requests/minute and 3600/hour per user — nowhere near a limiting factor
  at any plausible interval — so rate limits don't drive this design.
  Rejected instead because Ratchet is a menu bar app that's invisible
  except when clicked: polling on a clock benefits the user only if
  something is watching between clicks, and nothing is. A setting for a
  number most users won't think about isn't worth adding.
- Considered and rejected: a fixed (non-configurable) background timer.
  Same reasoning — refreshing when nobody's looking has no payoff here.
- The existing "Refresh projects & tasks" Settings item
  (`MenuBuilder.swift:245`, wired to `MenuActions.refresh`) is unconditional
  and stays that way — it's an explicit user action and must never be
  skipped for being "too soon since the last refresh."
- `FreeAgentDataStore.lastRefreshedAt` already exists and already backs the
  "Last refreshed at …" subtitle on the manual refresh item — this spec
  reads it for gating, it doesn't add a new timestamp.
- The manual refresh closure in `StatusItemController` (around
  `refresh: { … }` in the `actions` lazy var) already establishes the
  pattern this spec reuses: `dataStore.refresh()` →
  `restoreRunningTimer()` → `rebuild()` on success,
  `presentAPIError(error, action:)` on failure. The new silent path is the
  same shape minus the alert.

## Design

### Shared silent-refresh helper

A new private method on `StatusItemController`, e.g.
`silentlyRefreshIfStale()`:

1. If `dataStore.lastRefreshedAt` is non-nil and within **2 minutes** of
   now, return immediately (no request fired).
2. Otherwise, `Task { @MainActor in ... }`:
   - `try await dataStore.refresh()`
   - `restoreRunningTimer()`
   - `rebuild()`
   - On error: if `error.indicatesSessionExpired`, call
     `handleSessionExpired()` (same as the launch-time and manual-refresh
     paths). Any other error is swallowed — matching the existing
     launch-time refresh precedent in `AppDelegate`, where a background
     failure isn't worth interrupting the user over.

This mirrors the manual refresh closure but drops the `presentAPIError`
alert path, since nothing the user did should be blamed for a silent
background fetch failing.

The 2-minute threshold is a constant, not a setting.

### Trigger 1: refresh on menu open

`StatusItemController` currently assigns `statusItem.menu = menu` directly
in `rebuild()` with no delegate. Add `NSMenuDelegate` conformance and set
`menu.delegate = self` when building the menu (or a stable delegate
assigned once — whichever keeps `rebuild()`'s existing shape cleanest).
`menuWillOpen(_:)` calls `silentlyRefreshIfStale()`.

The menu opens immediately from whatever's cached — this call never blocks
menu presentation. If the refresh completes while the menu is still open,
`rebuild()` swaps in a new `NSMenu` on the status item; this may not
visibly update the currently-displayed menu (AppKit doesn't live-patch an
open menu from a swapped-out instance), but the next open reflects fresh
state. That's an accepted tradeoff — the alternative (blocking menu
presentation on a network round-trip) is the exact "wait a second" problem
this design avoids.

### Trigger 2: refresh on system wake

Observe `NSWorkspace.shared.notificationCenter` for
`NSWorkspace.didWakeNotification` (registered once, e.g. in
`StatusItemController.init`, torn down in `deinit` alongside the existing
`appearanceObservation` cleanup) and call `silentlyRefreshIfStale()` on
wake. Uses the same 2-minute gate, so e.g. lid-flutter (rapid sleep/wake)
doesn't fire repeated requests.

### Not changed

- `MenuActions.refresh` / the manual "Refresh projects & tasks" item:
  unconditional, as today.
- Launch-time refresh in `AppDelegate.applicationDidFinishLaunching`:
  unconditional, as today (there's nothing to be stale relative to yet).
- No new `UserDefaults` keys, no new Settings submenu rows.

## Error handling

Both new triggers swallow all errors except session expiry, which routes
to the existing `handleSessionExpired()` path (same alert/log-out behavior
already used elsewhere). No new error types or presentation paths.

## Testing

- `StatusItemControllerTests` (or wherever menu-open behavior is
  currently tested): a fake/spy `DataStore` with a controllable
  `lastRefreshedAt` and `refresh()` call count, verifying:
  - `menuWillOpen` triggers `refresh()` when `lastRefreshedAt` is nil or
    older than 2 minutes.
  - `menuWillOpen` does **not** trigger `refresh()` when
    `lastRefreshedAt` is within 2 minutes.
  - A refresh failure that isn't session-expiry does not present an
    alert and does not crash.
  - A session-expiry failure calls the same path as
    `handleSessionExpired()` elsewhere (logged out, credentials cleared).
- A wake-notification test posting `NSWorkspace.didWakeNotification` (or
  exercising the same gating logic directly if posting real
  `NSWorkspace` notifications isn't practical in the test target) and
  confirming the same gate applies.
- Per `CLAUDE.md`, `swift test` doesn't run on this machine — these tests
  are written but unrun; `swift build` only confirms the test file
  compiles, not that the tests pass.
