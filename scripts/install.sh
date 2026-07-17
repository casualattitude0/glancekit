#!/bin/bash
# Build Glancekit as a STANDALONE app (no Xcode debug-dylib preview stub) and
# install it as the single canonical copy in /Applications, then refresh the
# widget daemon so newly added/changed widgets show up in the gallery.
#
# Why this exists: `xcodebuild ... build` (and running from Xcode) produces a
# widget extension whose main executable is a ~58 KB launcher stub that loads a
# sidecar `GlancekitWidgets.debug.dylib`. That form is for debugging under Xcode
# and is unreliable when the OS registers the widget itself — the widget gallery
# gets stuck showing an old, cached set of widgets. ENABLE_DEBUG_DYLIB=NO forces
# a self-contained extension binary with every widget statically linked in.
#
# Usage: scripts/install.sh   (run from anywhere)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# pwd -P so this matches the resolved /private/var path LaunchServices reports;
# the purge below compares against it literally.
BUILD_DIR="$(cd "$(mktemp -d)" && pwd -P)/Products"
APP_NAME="Glancekit.app"
DEST="/Applications/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# xcodebuild registers whatever it builds, so the temp copy would linger as a
# registered rival to $DEST for the same appex bundle id — the shadowing this
# script exists to prevent. Drop it on exit, however we exit.
cleanup() {
  "$LSREGISTER" -u "$BUILD_DIR/$APP_NAME" 2>/dev/null || true
  rm -rf "$(dirname "$BUILD_DIR")"
}
trap cleanup EXIT

echo "▸ Building standalone (ENABLE_DEBUG_DYLIB=NO) …"
xcodebuild -project "$PROJECT_DIR/Glancekit.xcodeproj" -scheme Glancekit \
  -configuration Debug \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  build >/dev/null

BUILT="$BUILD_DIR/$APP_NAME"
AX="$BUILT/Contents/PlugIns/GlancekitWidgets.appex"
if [ -e "$AX/Contents/MacOS/GlancekitWidgets.debug.dylib" ]; then
  echo "✗ Build still produced a debug-dylib stub — aborting." >&2; exit 1
fi

echo "▸ Quitting running app + widget …"
osascript -e 'quit app "Glancekit"' 2>/dev/null || true
killall Glancekit GlancekitWidgets 2>/dev/null || true
sleep 1

# Any other Glancekit.app on disk shares the appex bundle id
# com.glancekit.Glancekit.GlancekitWidgets, so pkd may resolve the widget to it
# instead of $DEST — an Xcode build into DerivedData silently wins and renders a
# stale widget that ignores its saved config. Purge every copy but $DEST.
# $BUILT is spared: xcodebuild registers its own output, so it shows up in the
# dump too, and deleting it would destroy the build we're here to install.
echo "▸ Purging competing copies (DerivedData / temp builds) …"
"$LSREGISTER" -dump 2>/dev/null \
  | grep -oE 'path:[[:space:]]+\S*/Glancekit\.app' \
  | sed 's/path:[[:space:]]*//' | sort -u \
  | grep -vFx "$DEST" \
  | grep -vFx "$BUILT" \
  | while read -r stale; do
      echo "  - $stale"
      "$LSREGISTER" -u "$stale" 2>/dev/null || true
      rm -rf "$stale"
    done || true   # grep exits 1 when there's nothing stale; pipefail would abort the install

# Update IN PLACE — never `rm -rf "$DEST"` first. A placed widget's settings are
# App-Intent values held by chronod against the widget instance, not by us (no
# App Group is possible on ad-hoc signing, so the intent is the only config
# channel). If the appex vanishes, even briefly, chronod can't resolve the
# instance's extension and prunes it — taking the user's token/symbols with it.
# rsync --delete swaps the contents while the bundle itself stays put.
echo "▸ Installing to $DEST (in place) …"
if [ -d "$DEST" ]; then
  rsync -a --delete "$BUILT/" "$DEST/"
else
  ditto "$BUILT" "$DEST"
fi

# `codesign --force --sign -` DROPS entitlements unless --entitlements is passed.
# The appex must keep com.apple.security.app-sandbox: pkd silently refuses to
# register an unsandboxed widget extension, so the gallery shows no Glancekit
# widgets at all. Sign inner-to-outer; only the widget target has entitlements.
echo "▸ Ad-hoc re-signing (ditto can invalidate the signature) …"
codesign --force --sign - \
  --entitlements "$PROJECT_DIR/GlancekitWidgets/GlancekitWidgets.entitlements" \
  "$DEST/Contents/PlugIns/GlancekitWidgets.appex"
codesign --force --sign - "$DEST"

if ! codesign -d --entitlements :- "$DEST/Contents/PlugIns/GlancekitWidgets.appex" 2>/dev/null \
     | grep -q 'com.apple.security.app-sandbox'; then
  echo "✗ appex lost its app-sandbox entitlement — pkd would reject it." >&2; exit 1
fi

echo "▸ Re-registering with LaunchServices …"
"$LSREGISTER" -f -R "$DEST"

echo "▸ Restarting extension + widget daemons (pkd, chronod) …"
killall pkd chronod 2>/dev/null || true

echo "▸ Launching …"
open "$DEST"

rm -rf "$(dirname "$BUILD_DIR")"

echo "▸ Verifying pkd registration …"
sleep 4
if pluginkit -m -p com.apple.widgetkit-extension 2>/dev/null | grep -q GlancekitWidgets; then
  echo "✓ Installed and registered. Open the widget gallery to add widgets."
else
  echo "⚠ Installed, but pkd has not registered the widget yet."
  echo "  Check: pluginkit -mAvvv | grep -iA3 glance   (the Path must be $DEST)"
  echo "  If it lists another path, an Xcode/DerivedData build is shadowing it."
  echo "  If it lists nothing, log out/in once to force a pkd rescan."
fi
