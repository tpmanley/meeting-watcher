#!/bin/bash
# Cuts a full release: bumps MARKETING_VERSION, builds/signs/zips via
# build-release.sh, tags, pushes, publishes a GitHub Release, and updates
# the Homebrew cask. See HOMEBREW.md for the manual version of this flow.
#
# Everything local (version bump, build, cask file edit) happens
# automatically. It pauses for an explicit go-ahead right before anything
# that pushes to GitHub or publishes a release, and pauses for a manual
# step if the build was Developer ID signed (notarizing needs credentials
# this script doesn't have — see HOMEBREW.md "Code signing status").
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_DIR="Meeting Watcher"
XCODEPROJ="$PROJECT_DIR/Meeting Watcher.xcodeproj"
PBXPROJ="$XCODEPROJ/project.pbxproj"
CASK="Casks/meeting-watcher.rb"

usage() {
  echo "Usage: $0 <version>   e.g. $0 1.3" >&2
  exit 1
}

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "error: version must look like 1.3 or 1.3.1" >&2
  exit 1
}
TAG="v$VERSION"

confirm() {
  read -r -p "$1 [y/N] " reply
  case "$reply" in
    [Yy]) ;;
    *) echo "Stopped — nothing further was pushed/published." ; exit 1 ;;
  esac
}

pause() {
  echo
  echo "----------------------------------------------------------------"
  echo "MANUAL STEP: $1"
  echo "----------------------------------------------------------------"
  read -r -p "Press Enter once done (Ctrl-C to stop here)... " _
}

echo "==> Pre-flight checks"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: must be on main (currently on $BRANCH)" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree has uncommitted changes — commit or stash first" >&2
  exit 1
fi

echo "    fetching origin/main..."
git fetch origin main --quiet
LOCAL_MAIN="$(git rev-parse main)"
REMOTE_MAIN="$(git rev-parse origin/main)"
if [ "$LOCAL_MAIN" != "$REMOTE_MAIN" ]; then
  echo "error: local main isn't in sync with origin/main — pull or push first" >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists" >&2
  exit 1
fi

CURRENT_VERSION="$(xcodebuild -showBuildSettings -project "$XCODEPROJ" -scheme "Meeting Watcher" -configuration Release 2>/dev/null \
  | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')"
if [ -z "$CURRENT_VERSION" ]; then
  echo "error: couldn't read the current MARKETING_VERSION from the project" >&2
  exit 1
fi
if [ "$CURRENT_VERSION" = "$VERSION" ]; then
  echo "error: $VERSION is already the current MARKETING_VERSION" >&2
  exit 1
fi
echo "    current version: $CURRENT_VERSION -> $VERSION"

DEV_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" || true)"

echo
echo "==> Bumping MARKETING_VERSION to $VERSION"
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
if git diff --quiet -- "$PBXPROJ"; then
  echo "error: sed didn't change $PBXPROJ — MARKETING_VERSION format may have changed, check it by hand" >&2
  exit 1
fi

echo
echo "==> Building, signing, and zipping $VERSION (this runs a full xcodebuild — may take a minute)"
./scripts/build-release.sh "$VERSION"

ZIP_PATH="dist/Meeting-Watcher-$VERSION.zip"
if [ ! -f "$ZIP_PATH" ]; then
  echo "error: expected $ZIP_PATH after build-release.sh, but it's not there" >&2
  exit 1
fi

if [ -n "$DEV_ID_IDENTITY" ]; then
  pause "This build was signed with a Developer ID cert ($DEV_ID_IDENTITY).
Notarize it before releasing (see HOMEBREW.md 'Code signing status' for
the one-time notarytool keychain-profile setup):

    xcrun notarytool submit $ZIP_PATH --keychain-profile \"<profile>\" --wait
    unzip -q $ZIP_PATH -d /tmp/mw-staple && xcrun stapler staple \"/tmp/mw-staple/$PROJECT_DIR.app\"
    ditto -c -k --sequesterRsrc --keepParent \"/tmp/mw-staple/$PROJECT_DIR.app\" $ZIP_PATH

This script will re-hash $ZIP_PATH once you continue, so make sure the
stapled, re-zipped file is in place at that path first."
fi

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "    sha256: $SHA256"

echo
echo "==> Committing version bump"
git add "$PBXPROJ"
git commit -m "Bump version to $VERSION" --quiet

echo "==> Tagging $TAG"
git tag "$TAG"

echo
confirm "About to push main (version bump commit) and tag $TAG to origin. Continue?"
git push origin main
git push origin "$TAG"

echo
if command -v gh >/dev/null 2>&1; then
  confirm "Create GitHub Release $TAG and upload $ZIP_PATH as its asset (via gh, with auto-generated notes)?"
  gh release create "$TAG" "$ZIP_PATH" --title "Meeting Watcher $VERSION" --generate-notes
else
  pause "gh CLI not found. Manually create a GitHub Release for $TAG and upload
$ZIP_PATH as a release asset (see HOMEBREW.md 'Cutting a release')."
fi

echo
echo "==> Updating Homebrew cask"
sed -i '' "s/version \"$CURRENT_VERSION\"/version \"$VERSION\"/" "$CASK"
sed -i '' "s/sha256 \"[a-f0-9]\{64\}\"/sha256 \"$SHA256\"/" "$CASK"
if git diff --quiet -- "$CASK"; then
  echo "error: sed didn't change $CASK as expected — check its version/sha256 lines by hand" >&2
  exit 1
fi
git add "$CASK"
git commit -m "Bump cask to $VERSION" --quiet

echo
confirm "Push the cask update to origin/main? (Do this only after the GitHub Release + asset above actually exist — brew installs read from that URL.)"
git push origin main

echo
echo "==> Done. Meeting Watcher $VERSION is released."
echo "    Coworkers pick it up via: brew upgrade"
