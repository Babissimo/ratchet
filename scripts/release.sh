#!/bin/bash
# Cuts a Ratchet release: tags origin/main, waits for .github/workflows/release.yml to publish the
# build, then points the Homebrew tap's cask at it. Safe to re-run for the same version if a later
# step failed; it picks up from the pushed tag.
#
# Usage: scripts/release.sh <version>    e.g. scripts/release.sh 1.2.0

set -euo pipefail

REPO="Babissimo/ratchet"
TAP="Babissimo/homebrew-ratchet"

VERSION="${1:-}"
# Same rule as build-app.sh, so a bad version fails here rather than in CI after the tag is out.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Usage: $0 <version>, up to three dot-separated integers (e.g. 1.2.0)" >&2
    exit 1
fi
TAG="v$VERSION"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

git fetch --quiet --tags origin main
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" > /dev/null; then
    echo "$TAG is already pushed; resuming."
else
    if ! git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null; then
        git tag -a "$TAG" -m "Ratchet $VERSION" origin/main
    elif [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse origin/main)" ]]; then
        echo "A local $TAG already exists and isn't origin/main. Delete it with: git tag -d $TAG" >&2
        exit 1
    fi
    git push --quiet origin "refs/tags/$TAG"
    echo "Pushed $TAG ($(git rev-parse --short "$TAG^{commit}"))."
fi

# The run takes a few seconds to appear after the push. The workflow runs only on tags, so the
# tagged commit identifies its run.
RUN_ID=""
for _ in {1..24}; do
    RUN_ID="$(gh run list -R "$REPO" --workflow release.yml --commit "$(git rev-parse "$TAG^{commit}")" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    [[ -n "$RUN_ID" ]] && break
    sleep 5
done
if [[ -z "$RUN_ID" ]]; then
    echo "No release workflow run appeared for $TAG." >&2
    exit 1
fi
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
echo "Waiting for $RUN_URL ..."
if ! gh run watch -R "$REPO" "$RUN_ID" --exit-status > /dev/null; then
    echo "The release build failed: $RUN_URL" >&2
    echo "Rerun it (gh run rerun $RUN_ID -R $REPO --failed) and then this script, or fix main" >&2
    echo "and release the next version." >&2
    exit 1
fi
echo "Release build succeeded."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gh release download "$TAG" -R "$REPO" --pattern Ratchet.app.zip --dir "$WORK"
SHA256="$(shasum -a 256 "$WORK/Ratchet.app.zip" | cut -d' ' -f1)"

gh repo clone "$TAP" "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/ratchet.rb"
sed -i '' -E \
    -e "s/^(  version )\"[^\"]*\"/\1\"$VERSION\"/" \
    -e "s/^(  sha256 )\"[^\"]*\"/\1\"$SHA256\"/" \
    "$CASK"
if ! grep -q "^  version \"$VERSION\"$" "$CASK" || ! grep -q "^  sha256 \"$SHA256\"$" "$CASK"; then
    echo "Couldn't find the version and sha256 lines to update in $TAP's Casks/ratchet.rb." >&2
    exit 1
fi
if git -C "$WORK/tap" diff --quiet; then
    echo "The tap already points at $VERSION."
else
    git -C "$WORK/tap" commit --quiet -am "ratchet $VERSION"
    git -C "$WORK/tap" push --quiet origin HEAD
    echo "Pointed $TAP at $VERSION ($SHA256)."
fi
