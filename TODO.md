# Ratchet — path to a polished, distributable app

Roadmap for turning the current sandbox-only, locally-run build into
something installable via Homebrew and usable by people other than the
developer. Nothing here is required for personal day-to-day use — the app
already works end to end against the FreeAgent sandbox.

## Decided: no paid Apple Developer Program membership ($99/yr)

That rules out real code signing + notarization. Everything below assumes
that constraint; each item notes what it costs to skip signing.

## Free things that fix real problems now

- [ ] **Self-signed code signing certificate** (Keychain Access →
  Certificate Assistant → Create a Certificate → "Code Signing"). Sign dev
  builds with it instead of relying on ad-hoc signing. Ad-hoc signatures
  change with every rebuild, which is why macOS re-prompts for Keychain
  access on every `scripts/build-app.sh` run — a stable self-signed
  identity fixes that for local use. Does **not** make other users trust
  the app (self-signed certs aren't recognized off this Mac).

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

- [ ] **Switch OAuth to PKCE, stop embedding the client secret.**
  `Sources/FreeAgentKit/Secrets.swift` bakes a real client secret into the
  compiled binary — fine for a solo local build, not something to ship
  publicly (extractable from the binary via `strings`). PKCE removes the
  need for a client secret entirely and is the standard pattern for
  public native-app OAuth clients. Free, no Developer Program needed, and
  correct regardless of what else on this list happens.

- [ ] **Production FreeAgent environment support.** `FreeAgentEnvironment`
  currently only has `.sandbox` — needs a `.production` case
  (`api.freeagent.com`) before anyone but the developer's sandbox account
  could use this. Also needs a real (non-sandbox) FreeAgent OAuth app
  registration.

- [ ] **`Launch at login` is still a no-op toggle.** `AppState` tracks the
  checkbox state but nothing wires it to `SMAppService`. Minor polish, not
  hard, currently just unfinished.

## Distribution without notarization

- [ ] **Public GitHub repo.** Needed as the home for release artifacts and
  the Homebrew tap. Free for public repos.

- [ ] **GitHub Actions release workflow.** On a tag push: `swift build -c
  release`, run `scripts/build-app.sh release`, zip the `.app`, attach to
  a GitHub Release. No signing step required — just automates what
  `scripts/build-app.sh` already does locally.

- [ ] **Accept the one-time Gatekeeper prompt, and soften it.** Without
  notarization, first launch shows "Apple could not verify this app is
  free of malware." Two ways to reduce friction, can do both:
  - Document "right-click → Open" for first launch in the README — the
    standard workaround for small unsigned open-source Mac utilities.
  - Have the Homebrew Cask formula's `postflight` block strip the
    quarantine attribute (`xattr -dr com.apple.quarantine`) on install —
    common, accepted pattern for unsigned casks. Note: files Homebrew
    downloads via `curl` often aren't quarantined the way a browser
    download is, so this may matter less than expected in practice —
    verify once there's a real release artifact to test against.

- [ ] **Own Homebrew tap, not the official `homebrew-cask` repo.** The
  official repo's quality guidelines likely require signing/notarization
  for acceptance. A personal tap (`brew tap <you>/ratchet`) has no such
  gate — write and host the formula there instead.

## Not blocking, revisit later

- Code signing + notarization proper, if the $99/yr ever becomes worth it
  — would remove the Gatekeeper prompt and the self-signed-cert
  workaround above entirely.
- Mac App Store distribution (would need sandboxing work, a paid account,
  and App Review) — not a goal right now, Homebrew is the target.
