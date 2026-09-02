#!/bin/bash
# Regenerates appcast.xml from the version's zip in dist/, so existing
# installs can pick it up via Sparkle. Downloads Sparkle's prebuilt CLI
# tools (cached after first use) rather than depending on Xcode's SPM
# checkout path, which isn't stable across machines/DerivedData wipes.
#
# Only the latest release is kept in the feed (--maximum-versions 1):
# build-release.sh doesn't retain older zips in dist/, and generate_appcast
# tries to move pruned versions' archive files to old_updates/, which
# fails if those files aren't there. Sparkle only needs the latest item
# to serve updates anyway — release history already lives in git tags.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?Usage: $0 <version>   e.g. $0 1.8}"
ZIP_PATH="dist/Meeting-Watcher-$VERSION.zip"
[ -f "$ZIP_PATH" ] || { echo "error: $ZIP_PATH not found — run build-release.sh first" >&2; exit 1; }

# Keep in sync with the Sparkle SPM package version (see the Sparkle
# dependency's requirement in project.pbxproj).
SPARKLE_VERSION="2.9.6"
TOOLS_CACHE="$HOME/Library/Caches/meeting-watcher-sparkle-tools/$SPARKLE_VERSION"
GENERATE_APPCAST="$TOOLS_CACHE/bin/generate_appcast"

if [ ! -x "$GENERATE_APPCAST" ]; then
  echo "==> Downloading Sparkle $SPARKLE_VERSION CLI tools"
  mkdir -p "$TOOLS_CACHE"
  TMP_ZIP="$(mktemp -t sparkle-tools).zip"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" -o "$TMP_ZIP"
  unzip -q -o "$TMP_ZIP" -d "$TOOLS_CACHE" "bin/*"
  rm -f "$TMP_ZIP"
fi

echo "==> Generating appcast.xml for $VERSION"
# Stage just this version's zip in isolation — generate_appcast errors out on
# duplicate CFBundleVersion, and dist/ accumulates zips from past releases
# that build-release.sh never cleans up.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$ZIP_PATH" "$STAGING_DIR/"

"$GENERATE_APPCAST" \
  --maximum-versions 1 \
  --download-url-prefix "https://github.com/tpmanley/meeting-watcher/releases/download/v$VERSION/" \
  "$STAGING_DIR/"

cp "$STAGING_DIR/appcast.xml" appcast.xml
echo "    wrote appcast.xml (signed against the EdDSA key in your Keychain)"
