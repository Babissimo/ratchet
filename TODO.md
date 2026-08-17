# Ratchet — path to a polished, distributable app

Roadmap for turning the current sandbox-only, locally-run build into
something installable via Homebrew and usable by people other than the
developer. Nothing here is required for personal day-to-day use — the app
already works end to end against the FreeAgent sandbox.

## Decided: no paid Apple Developer Program membership ($99/yr)

That rules out real code signing + notarization. Everything below assumes
that constraint; each item notes what it costs to skip signing.

## Free things that fix real problems now

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

- [ ] **Switch OAuth to PKCE, stop embedding the client secret — tried,
  reverted.** Implemented RFC 7636 PKCE (`code_verifier`/`code_challenge`
  on the authorize URL, no `Authorization: Basic`) and live-tested it
  against the real FreeAgent sandbox: every token exchange came back
  `invalid_grant`. FreeAgent's OAuth app registration is a
  confidential-client type — it doesn't recognize PKCE and still
  requires the client secret regardless. Reverted to
  `Authorization: Basic` with `clientID`/`clientSecret` (both files back
  to documenting/requiring `clientSecret`). Leaving this open in case
  FreeAgent ever adds a public-client/PKCE app registration type — until
  then, the client secret in the compiled binary is a real, accepted
  limitation of a solo/small-scale unsigned distribution rather than
  something fixable from this side alone.

- [x]/[ ] **Production FreeAgent environment support.**
  `FreeAgentEnvironment.production` exists (`api.freeagent.com` URLs).
  `AppDelegate.swift` now reads `FreeAgentEnvironment.configured`, which
  resolves to `FreeAgentSecrets.environment` — the environment lives next to
  the client ID/secret it's paired with, in the same gitignored
  `Secrets.swift`, so a sandbox credential pair can't accidentally get
  wired to `.production` or vice versa. `Secrets.swift.example` and the
  local `Secrets.swift` both default to `.sandbox`;
  `.github/workflows/release.yml` generates `.production` for release
  builds. Remaining work: **register a real (non-sandbox) FreeAgent OAuth
  app** at dev.freeagent.com, set its redirect URI to `ratchet://callback`
  (same as sandbox), and add its client ID/secret as the
  `FREEAGENT_CLIENT_ID`/`FREEAGENT_CLIENT_SECRET` repo secrets the release
  workflow reads — those don't exist yet, so the workflow won't build
  until they're added. Nothing else code-side is needed once that app
  exists.

## Distribution without notarization

- [ ] **Public GitHub repo.** Needed as the home for release artifacts and
  the Homebrew tap. Free for public repos.

- [x]/[ ] **GitHub Actions release workflow.** `.github/workflows/release.yml`
  drafted: tag push (`v*`) → `swift build -c release` →
  `scripts/build-app.sh release` → `ditto`-zip → GitHub Release. Writes
  `Secrets.swift` from a `FREEAGENT_CLIENT_ID` repo secret first (needs
  adding once the repo exists — see below). Untested — no public repo to
  push a tag to yet.

- [x]/[ ] **Accept the one-time Gatekeeper prompt, and soften it.**
  - [x] `README.md` documents right-click → Open for first launch.
  - [x] `Casks/ratchet.rb` drafted with a `postflight` quarantine-strip,
    flagged in-file as unverified until there's a real release artifact
    to test `xattr` against.

- [ ] **Own Homebrew tap, not the official `homebrew-cask` repo.** The
  official repo's quality guidelines likely require signing/notarization
  for acceptance. A personal tap (`brew tap <you>/ratchet`) has no such
  gate — `Casks/ratchet.rb` is drafted and ready to host there, with
  placeholder `version`/`sha256`/`url` to fill in once a release exists.

## Not blocking, revisit later

- Code signing + notarization proper, if the $99/yr ever becomes worth it
  — would remove the Gatekeeper prompt and the self-signed-cert
  workaround above entirely.
- Mac App Store distribution (would need sandboxing work, a paid account,
  and App Review) — not a goal right now, Homebrew is the target.
