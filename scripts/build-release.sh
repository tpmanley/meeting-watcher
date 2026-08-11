#!/bin/bash
# Builds a Release .app, signs it (Developer ID if available, else ad-hoc),
# and zips it into dist/ ready to attach to a GitHub Release for the
# Homebrew cask. See HOMEBREW.md for the full release walkthrough.
set -euo pipefail

cd "$(dirname "$0")/../Meeting Watcher"

SCHEME="Meeting Watcher"
PROJECT="Meeting Watcher.xcodeproj"
APP_NAME="Meeting Watcher"
BUILD_DIR="$(mktemp -d)"
DIST_DIR="../dist"

VERSION="${1:-$(xcodebuild -showBuildSettings -scheme "$SCHEME" -configuration Release 2>/dev/null | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')}"
if [ -z "$VERSION" ]; then
  echo "error: couldn't determine version; pass one explicitly: $0 1.1" >&2
  exit 1
fi

echo "==> Building $APP_NAME $VERSION (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" clean build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: build didn't produce $APP_PATH" >&2
  exit 1
fi

DEV_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEV_ID_IDENTITY" ]; then
  echo "==> Re-signing with Developer ID identity: $DEV_ID_IDENTITY"
  codesign --force --deep --options runtime --sign "$DEV_ID_IDENTITY" "$APP_PATH"
  echo "    Signed with a real Developer ID cert. You should notarize before"
  echo "    distributing — see 'Notarizing' in HOMEBREW.md — otherwise"
  echo "    Gatekeeper will still flag it on first launch."
else
  echo "==> No 'Developer ID Application' cert found — ad-hoc signing instead"
  echo "    (coworkers will need the one-time Gatekeeper bypass; the cask"
  echo "    handles this automatically via a postflight quarantine removal)."
  codesign --force --deep --sign - "$APP_PATH"
fi

mkdir -p "$DIST_DIR"
ZIP_NAME="Meeting-Watcher-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"

echo "==> Zipping to $ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo
echo "==> Done"
echo "    zip:    $(cd "$DIST_DIR" && pwd)/$ZIP_NAME"
echo "    sha256: $SHA256"
echo
echo "Next: create a GitHub release tagged v$VERSION, upload that zip as a"
echo "release asset, then update Casks/meeting-watcher.rb with:"
echo "    version \"$VERSION\""
echo "    sha256 \"$SHA256\""
