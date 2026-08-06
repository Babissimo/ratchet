# Ratchet — Menu Bar UI Design

Date: 2026-08-06
Status: Approved (UI scope only)

## Purpose

Ratchet is a macOS menu bar app for starting and stopping FreeAgent time
tracking without opening a browser. This spec covers **only the UI**: menu
structure, states, and transitions, built against fake/stubbed data. Auth
and the real FreeAgent API integration are separate, later work — the UI
talks to a stub that presents the same shape of data the real API will.

## Context / prior decisions

- User pattern: one task tracked for most of the day, started once, stopped
  once. Not fast task-switching, not ad hoc project search.
- The problem being solved is pure convenience (avoiding the FreeAgent web
  UI), not idle detection, forgetting to stop, or offline work. Those are
  explicitly out of scope for this tool's design.
- Chosen shell: native `NSMenu` via a menu bar item (not a popover/window).
  This gives keyboard navigation and type-to-select for free and matches
  the drill-down (client → project → task) the user wants.
- Menu bar icon: icon only, tinted/filled when tracking, outline when not.
  No elapsed time or text in the menu bar itself — all context lives in
  the dropdown menu, since that's the only other surface available.
- Stack: Swift + SwiftUI / AppKit, macOS 13+.

## Menu states

There are four states. Exactly one is shown at a time, driven by:
`hasHistory` (has a most-recent client/project/task ever been tracked)
and `isTracking` (a timer is currently running).

### 1. First run — idle, no history

No most-recent task exists yet, so there's nothing to offer a one-click
start for.

```
Start >
─────────────────────
Settings >
Quit
```

### 2. Idle, has history

```
Start tracking Development
  Acme · Website Redesign
Start >
─────────────────────
Settings >
Quit
```

- Top item is a single click: starts tracking on the most recent
  (client, project, task) tuple, regardless of whether it already has
  time logged today. There is no separate "resume" label or state — see
  "Considered and dropped" below.
- The two-line label (task name, then "Client · Project") is disabled
  text above it — not a menu item, not clickable, purely context — with
  the actual clickable action as the top item, OR the top item itself
  renders as two lines if the platform menu API allows a subtitle-style
  item. Implementation should use whichever native affordance keeps this
  a single click to start.
- `Start >` always leads to the full client → project → task drill-down,
  for when you want something other than the most-recent task.

### 3. Tracking

```
Development
Acme · Website Redesign
1:47
─────────────────────
Stop tracking
─────────────────────
Settings >
Quit
```

- First three lines are disabled/non-interactive: task name, then
  "Client · Project", then live elapsed time (ticking, `H:MM` format,
  updates at least once per minute).
- `Stop tracking` is the only action above the settings/quit footer.
- Elapsed time is computed from the local start instant, not polled from
  the API.

### 4. Idle, has history (returning to idle after a stop)

Same as state 2. Stopping tracking returns here; "most recent" updates
to reflect the task that was just stopped, so starting again immediately
re-offers the same task at the top.

## Submenu: Start >

Drill-down, three levels, matching the client → project → task hierarchy.

**Clients level:**
```
Acme >
Other Co >
```
Clicking a client opens its projects submenu. No "add client" item —
see "Considered and dropped."

**Projects level (within a client):**
```
Website Redesign >
Q3 Retainer >
```
Clicking a project opens its tasks submenu. No "add project" item —
same reasoning.

**Tasks level (within a project):**
```
Development
Design
Copywriting
─────────────────────
New task…
```
Clicking a task starts tracking immediately (creates/reuses today's
timeslip for that task and starts its timer — API detail, out of scope
here). `New task…` opens a minimal one-field prompt (task name) since
adding a task to an *existing* project is a single string with no other
required fields, unlike creating a client or project.

## Submenu: Settings >

```
al@example.com
Refresh projects & tasks
✓ Launch at login
─────────────────────
Open FreeAgent
─────────────────────
Log out
```

- First line: signed-in account email, disabled/non-interactive.
- `Refresh projects & tasks` re-fetches clients/projects/tasks from the
  API so newly-created ones (made via the FreeAgent web UI) show up
  without relaunching the app.
- `Launch at login` is a checkbox-style toggle (via `SMAppService` at
  implementation time).
- `Open FreeAgent` opens the FreeAgent web app in the default browser —
  an escape hatch for anything this menu can't do.
- `Log out` clears stored credentials and returns to the logged-out
  state (see below).

## Logged-out state

Shown before auth completes, or after Log out.

```
Log in with browser
─────────────────────
Quit
```

`Log in with browser` opens the OAuth flow (out of scope here beyond
triggering it); on success, transitions to state 1 or 2 depending on
whether history exists.

## Non-goals for this pass

- No elapsed-time or text display in the menu bar icon itself.
- No "today's total time" line — considered and dropped, see below.
- No logging time after the fact (backfilling a timeslip for earlier
  today or a past day).
- No creating clients or projects from within Ratchet.
- No idle detection, auto-stop, or reminders.
- No handling of what happens if the API stub reports an error — this
  pass assumes happy-path fake data. Real error states are designed
  alongside the API integration work.

## Considered and dropped

- **"Resume tracking" as a distinct state/label from "Start tracking".**
  In FreeAgent both actions do the same thing (restart the timer on
  today's existing timeslip for that task, or create one if none
  exists). A separate "Resume" label would be one more state to build,
  test, and keep in sync with "has today's timeslip already got time on
  it," for a distinction the user doesn't need. Single "Start tracking"
  label covers both cases.
- **"Today: 3h 20m" line in the idle menu.** Requires tracking a running
  total across possibly multiple start/stop cycles in a day, which adds
  real complexity (What day boundary? What timezone? Does it include
  time from other apps/the FreeAgent web UI?) for a value whose payoff
  wasn't clearly worth it. Parked as a future addition.

## Future additions (not this pass)

- Log time after the fact (backfill a timeslip for a past date/duration
  without running a live timer).
- Create clients and projects from within Ratchet (currently: web UI
  only, since these need fields — billing details, currency, budget —
  that don't fit a single-field prompt).
- "Today: N h M m" running total in the idle menu.
