# Ratchet — path to a polished, distributable app

Roadmap for turning the current locally-run build into something
installable via Homebrew and usable by people other than the developer.

## Decided: no paid Apple Developer Program membership ($99/yr)

That rules out real code signing + notarization. Everything below assumes
that constraint; each item notes what it costs to skip signing.

## Free things that fix real problems now

- [x] **No client secret in the app.** FreeAgent registers only
  confidential OAuth clients (PKCE was live-tested and rejected), and its
  API terms (5.5.1) forbid hardcoding credentials into an app. The client
  ID and secret live in a Cloudflare Worker instead (`worker/`,
  `auth.ratchet.babissimo.net`), which runs sign-in and refreshes and adds
  the credentials. Sign-in runs in the default browser, and the Worker
  stands in for PKCE so a callback intercepted on its way back through
  `ratchet://` is useless. Live-tested against production.

- [x] **Rate-limit the sign-in service at Cloudflare's edge.** A zone
  rule blocks one client's flood before it reaches the Worker and spends
  the free plan's 100,000 requests a day. A distributed flood still
  gets through; see `worker/README.md`.

- [x] **Production FreeAgent environment support.** Builds target
  production; `-Xswiftc -DFREEAGENT_SANDBOX` targets the sandbox. One
  FreeAgent OAuth app serves both (live-tested), so the Worker holds a
  single credential pair.

- [x] **Self-signed code signing certificate.** Created in Keychain Access
  (Certificate Assistant → Create a Certificate → Code Signing, named
  "Ratchet"). `scripts/build-app.sh` now signs every build with it
  (`codesign --sign "Ratchet" --identifier com.ratchet.app`, falling back
  to ad-hoc with a warning if the cert isn't present — e.g. a fresh
  clone). Confirmed via `codesign -dv` that `Identifier` is now the
  stable `com.ratchet.app` across rebuilds, instead of the ad-hoc
  signature's per-build regenerated identifier. This was the actual
  cause of a live-tested bug: **Launch at login didn't survive a
  rebuild** — `sfltool dumpbtm` showed each `scripts/build-app.sh` run
  registering a *new*, separate login item under the old ad-hoc
  identifier rather than updating the existing one, so the toggle
  silently reverted to off on next launch. Also still fixes the
  original Keychain-access-reprompt-on-every-build annoyance this item
  was first written for. Does **not** make other users trust the app
  off this Mac (self-signed certs aren't recognized elsewhere) —
  unrelated to and doesn't block notarization/distribution.

- [x] **App icon.** `Resources/AppIcon.icns`, built from `RatchetIcon`
  (`Sources/RatchetCore/RatchetIcon.swift`) via
  `swift run IconExporter <output-dir>` + `iconutil`.
  `scripts/build-app.sh` regenerates it into `.build/icons` on every run,
  bundles that, sets `CFBundleIconFile`/`CFBundleIconName`, and warns when the
  committed copy has gone stale. Also covers the Homebrew Cask
  listing concern this item originally raised. Menu bar and dialogs use
  the same drawing code (`RatchetIcon.mark` / `.appTile`) instead of the
  old SF Symbol `clock` — `.appTile` (Dock/dialog/FreeAgent-listing icon,
  `design/icons/freeagent-icon.png`) has a textured gradient/grain/engraved
  treatment; `.mark` (tray glyph) stays flat, per platform convention for
  status-bar icons.

## Distribution without notarization

- [ ] **Public GitHub repo.** Needed as the home for release artifacts and
  the Homebrew tap. Free for public repos.

- [ ] **Own Homebrew tap, not the official `homebrew-cask` repo.** The
  official repo's quality guidelines likely require signing/notarization
  for acceptance. A personal tap (`brew tap <you>/ratchet`) has no such
  gate — `Casks/ratchet.rb` is drafted and ready to host there, with
  placeholder `version`/`sha256`/`url` to fill in once a release exists.

- [x]/[ ] **GitHub Actions release workflow.** `.github/workflows/release.yml`
  drafted: tag push (`v*`) → `swift build -c release` →
  `scripts/build-app.sh release` → `ditto`-zip → GitHub Release. Needs no
  repository secrets. Untested, as there is no public repo to push a tag to yet.

- [x]/[ ] **Accept the one-time Gatekeeper prompt, and soften it.**
  - [x] `README.md` documents right-click → Open for first launch.
  - [x] `Casks/ratchet.rb` drafted with a `postflight` quarantine-strip,
    flagged in-file as unverified until there's a real release artifact
    to test `xattr` against.

## Feature backlog

- [ ] **Contact integrationsrequests@freeagent.com to make it official.**
  Pursue listing/partnership status for the app.
- [ ] **Offline/intermittent connection support** — start tracking while
  offline, sync to FreeAgent automatically once back online.
- [ ] **Support multiple simultaneous timers**, matching the FreeAgent web
  app. `AppState`/`FreeAgentDataStore` currently model a single
  `currentRunningTimeslip`/`trackingTask` — this would be a real data-model
  change, not just a UI one.
- [x]/[ ] **Explore how a timer ought to and does work across days.**
  Researched: FreeAgent's docs are silent on multi-day running timers, but
  the schema (`dated_on` a single scalar day, no splitting) implies the
  whole duration books to the start day — not server-confirmed, just the
  strong inference. The research surfaced a real, separate bug rather than
  just an ambiguity: `FreeAgentDataStore.startTimer`'s existing-timeslip
  lookup was scoped to *today*, so a timer left running past midnight and
  then re-started (app restart, etc.) would silently create a duplicate
  timeslip rather than resuming the original — fixed, `startTimer` now
  checks for any currently-running timeslip first regardless of day.
  Remaining, not done: a lightweight "running since yesterday" indicator
  in the menu (cheap, `CalendarDay` already in the codebase) was
  recommended but not built — no auto-splitting, which is the wrong
  altitude for a background menu-bar app per the research's own
  reasoning.
- [x] **Icons next to some menu buttons**, beyond the current
  `RatchetIcon.mark`/`.appTile` usage. SF Symbol icons (`menuIcon` helper
  in `MenuBuilder.swift`) added to the highest-traffic rows — start/stop,
  switch task, log past time, recent entries, settings, log in, refresh,
  log out, account email. Deliberately left plain: Quit (macOS
  convention), Launch at login (already shows state via its checkmark),
  Open FreeAgent, and every leaf of the client→project→task pickers.
- [x] **Submenu of tasks to switch what's being tracked while a timer is
  active.** "Switch task" reuses the same client→project→task picker as
  Start timer/Log past time. Reassigns the *running* timeslip's task in
  place (a `PUT` on task/project/client, same date/hours/comment) rather
  than stopping and starting a new timer — keeps it one continuous
  timeslip and the elapsed-time counter running from its original start
  instant. The submenu excludes whichever task is already tracking.
- [x] **Make "Recent time entries" editable** — clicking an entry opens a
  form (task via three cascading Client/Project/Task popups, plus
  date/duration/comment) that `PUT`s the full record via a new
  `DataStore.updateTimeslip`. The currently-running entry is excluded
  from the list outright (FreeAgent doesn't live-update a running
  timeslip's `hours`, so it would otherwise show a stale, paused-at
  duration).

- [ ] **Duplicate timeslips when a create response is lost.** If the network drops after FreeAgent
  processes `POST /timeslips` but before the response arrives, the entry exists server-side with
  no local record, and retrying "Log past time" creates a second one. `startTimer` self-heals
  (its next call re-queries the running view and adopts what it finds); `logTime` has no
  equivalent. A real fix needs either an idempotency key or a post-failure reconciliation query
  against the same task/day/hours — worth doing before Ratchet is used for anything invoiced.

## Not blocking, revisit later

- Code signing + notarization proper, if the $99/yr ever becomes worth it
  — would remove the Gatekeeper prompt and the self-signed-cert
  workaround above entirely.
- Mac App Store distribution (would need sandboxing work, a paid account,
  and App Review) — not a goal right now, Homebrew is the target.
- Three state-reconciliation behaviours have no covering check. Each was
  reasoned through and type-checked when written, but nothing in
  `Sources/Antagonise` or `Tests/` exercises it, so a regression would be
  silent — and since `swift test` can't run here, the harness is the only
  place coverage actually counts for:
  - `startTimer` throwing when a `POST /timeslips/:id/timer` response
    explicitly reports `timer.running == false` (as opposed to omitting the
    `timer` object, which is the case that gets a `clock()` stamp). Needs a
    stub returning `"running":false` on that endpoint.
  - `updateTimeslip` carrying the cached `timerStartedAt` forward when the
    PUT response omits the timer object for the entry that's running. This
    guards the elapsed-time baseline `AppState.reconcile(with:)` reads on every
    refresh, so a regression would re-base a running timer's clock to now.
  - The interleaving the two-edge `mutationEpoch` bump exists to close: a
    refresh that *starts* after a mutation's entry bump and would otherwise
    commit over it. Harness scenarios 1 and 2 gate the refresh and mutate
    afterwards, which passes under the old single-edge design too — so the
    exit bump specifically is unguarded. Needs the mutation to begin first
    and the refresh to snapshot mid-flight.
