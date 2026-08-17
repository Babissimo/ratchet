# DRAFT — template for a personal tap (e.g. <you>/homebrew-ratchet), not
# yet hosted anywhere. See TODO.md ("Own Homebrew tap, not the official
# homebrew-cask repo") — the official repo's quality guidelines likely
# require signing/notarization, which this project deliberately skips
# (no paid Apple Developer Program membership), so this needs its own tap.
#
# TODO before first real release:
#   - set `version` to the release tag (without the leading "v")
#   - set `sha256` to the checksum of that release's Ratchet.app.zip
#     (`shasum -a 256 Ratchet.app.zip`)
#   - confirm `url` matches the asset name .github/workflows/release.yml
#     actually publishes
cask "ratchet" do
  version "0.0.0" # TODO: set on first release
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # TODO: set on first release

  # Points at the zip Ratchet's release workflow (.github/workflows/release.yml)
  # attaches to the GitHub Release for tag v#{version}.
  url "https://github.com/OWNER/ratchet/releases/download/v#{version}/Ratchet.app.zip"
  name "Ratchet"
  desc "Menu-bar time tracker for FreeAgent"
  homepage "https://github.com/OWNER/ratchet"

  app "Ratchet.app"

  # Unsigned, unnotarized build (see TODO.md). Strips the quarantine
  # attribute so Gatekeeper doesn't show "Apple could not verify this app
  # is free of malware" after a Homebrew install.
  #
  # NOTE: unverified — files Homebrew fetches via curl often aren't
  # quarantined the way a browser download is, so this postflight may turn
  # out to be a no-op in practice. Confirm with a real release artifact
  # (check `xattr` on the downloaded .app before assuming this is needed).
  postflight do
    system_command "/usr/bin/xattr",
                    args: ["-dr", "com.apple.quarantine", "#{appdir}/Ratchet.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.ratchet.app.plist",
    "~/Library/Caches/com.ratchet.app",
  ]
end
