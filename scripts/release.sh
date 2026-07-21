#!/bin/bash
# Cut the distributable release assets and attach them to the GitHub release.
#
# A release is not done when the tag exists — it's done when the .dmg and .zip
# are on it, because scripts/install-release.sh (and every "download the app"
# link) resolves those assets, not the source. Tagging without them ships a
# release nobody can install. This script exists so that step can't be skipped:
# run it and both assets are built, verified, and uploaded in one shot.
#
#   scripts/release.sh            # version taken from MARKETING_VERSION
#   scripts/release.sh 1.1.6      # or pinned explicitly
#
# It builds the SAME standalone, ad-hoc-signed app scripts/install.sh does
# (ENABLE_DEBUG_DYLIB=NO, entitlements preserved) — the form the installers
# expect — then packages and uploads. Nothing lands in /Applications.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Glancekit.app"
OUT="/private/tmp/gk-release"          # not under Spotlight-indexed DerivedData
BUILD_DIR="$OUT/Products"
STAGE="$OUT/stage"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# One account for the release, matching git/github-pr-workflow. Override with
# GH_RELEASE_ACCOUNT=<user>.
ACCOUNT="${GH_RELEASE_ACCOUNT:-casualattitude0}"

# Version: explicit arg, else the project's own MARKETING_VERSION so the tag,
# the bundle and the filenames can never disagree.
VERSION="${1:-$(grep -m1 'MARKETING_VERSION' "$PROJECT_DIR/Glancekit.xcodeproj/project.pbxproj" \
  | sed -E 's/.*= ([0-9.]+);/\1/')}"
TAG="v$VERSION"
REPO="$(git -C "$PROJECT_DIR" config --get remote.origin.url \
  | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#')"

echo "▸ Releasing $TAG to $REPO as $ACCOUNT"

rm -rf "$OUT"; mkdir -p "$BUILD_DIR" "$STAGE"

echo "▸ Building standalone (ENABLE_DEBUG_DYLIB=NO) …"
xcodebuild -project "$PROJECT_DIR/Glancekit.xcodeproj" -scheme Glancekit \
  -configuration Debug \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  build >/dev/null

BUILT="$BUILD_DIR/$APP_NAME"
if [ -e "$BUILT/Contents/PlugIns/GlancekitWidgets.appex/Contents/MacOS/GlancekitWidgets.debug.dylib" ]; then
  echo "✗ Build produced a debug-dylib stub — aborting." >&2; exit 1
fi
# xcodebuild registers what it builds; drop it so it can't shadow /Applications.
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true

echo "▸ Staging + ad-hoc re-signing (entitlements preserved) …"
ditto "$BUILT" "$STAGE/$APP_NAME"
APP="$STAGE/$APP_NAME"
codesign --force --sign - \
  --entitlements "$PROJECT_DIR/GlancekitWidgets/GlancekitWidgets.entitlements" \
  "$APP/Contents/PlugIns/GlancekitWidgets.appex"
codesign --force --sign - \
  --entitlements "$PROJECT_DIR/Glancekit/Glancekit.entitlements" \
  "$APP"

echo "▸ Verifying signature, entitlements, and version …"
codesign -d --entitlements :- "$APP/Contents/PlugIns/GlancekitWidgets.appex" 2>/dev/null \
  | grep -q 'com.apple.security.app-sandbox' \
  || { echo "✗ appex lost app-sandbox — pkd would reject it." >&2; exit 1; }
codesign -d --entitlements :- "$APP" 2>/dev/null \
  | grep -q 'com.apple.security.automation.apple-events' \
  || { echo "✗ app lost apple-events — browser reads would be blocked." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
BUNDLE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLE_VER" = "$VERSION" ] \
  || { echo "✗ bundle version $BUNDLE_VER != $VERSION — bump MARKETING_VERSION." >&2; exit 1; }
echo "  ok · v$BUNDLE_VER"

ZIP="$OUT/Glancekit-$VERSION.zip"
DMG="$OUT/Glancekit-$VERSION.dmg"

echo "▸ Packaging zip …"
# keepParent → archive holds a top-level Glancekit.app, which
# install-release.sh finds via `find -maxdepth 2 -name Glancekit.app`.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "▸ Packaging dmg …"
DMGSRC="$OUT/dmgsrc"; rm -rf "$DMGSRC"; mkdir -p "$DMGSRC"
ditto "$APP" "$DMGSRC/$APP_NAME"
ln -s /Applications "$DMGSRC/Applications"   # drag-to-install affordance
hdiutil create -volname "Glancekit $VERSION" \
  -srcfolder "$DMGSRC" -ov -format UDZO "$DMG" >/dev/null

echo "▸ Uploading to the $TAG release …"
gh auth switch --user "$ACCOUNT" >/dev/null 2>&1 || true
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  # --clobber so a re-run replaces stale assets rather than erroring on collision.
  gh release upload "$TAG" "$DMG" "$ZIP" --repo "$REPO" --clobber
else
  echo "✗ Release $TAG does not exist yet. Create it first, e.g.:" >&2
  echo "    gh release create $TAG --repo $REPO --target main --title $TAG --generate-notes" >&2
  echo "  then re-run this script." >&2
  exit 1
fi

echo
echo "✓ $TAG assets:"
gh release view "$TAG" --repo "$REPO" --json assets \
  --jq '.assets[] | "  \(.name)  (\(.size) bytes)"'
