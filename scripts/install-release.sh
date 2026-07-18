#!/bin/bash
# Download the latest Glancekit release and install it to /Applications — no
# clone, no Xcode, no build. Designed to be run straight from the internet:
#
#   curl -fsSL https://raw.githubusercontent.com/casualattitude0/glancekit/main/scripts/install-release.sh | bash
#
# or, with a pinned version:
#
#   curl -fsSL .../install-release.sh | GLANCEKIT_VERSION=v1.0.2 bash
#
# Unlike scripts/install.sh (which builds Debug from a source checkout), this
# installs a prebuilt, standalone-signed release asset. It updates the app IN
# PLACE so widgets you have already placed keep their saved settings, strips the
# download quarantine so Gatekeeper does not block the ad-hoc-signed app, and
# refreshes the widget daemons so the gallery picks up the new build.
set -euo pipefail

REPO="casualattitude0/glancekit"
APP_NAME="Glancekit.app"
DEST="/Applications/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
VERSION="${GLANCEKIT_VERSION:-latest}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ Glancekit is a macOS app; this installer only runs on macOS." >&2
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Resolve the .zip asset URL from the GitHub releases API. `latest` uses the
# dedicated endpoint; a pinned tag uses the by-tag endpoint. No auth needed for
# public releases; `gh` is used when present (higher rate limit), else curl.
if [ "$VERSION" = "latest" ]; then
  API="https://api.github.com/repos/$REPO/releases/latest"
else
  API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
fi

echo "▸ Looking up $VERSION release of $REPO …"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  META="$(gh api "${API#https://api.github.com/}")"
else
  META="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")"
fi

# Pick the app zip (…-<version>.zip), not the .dmg — a zip needs no mount.
ZIP_URL="$(printf '%s' "$META" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.zip"' \
  | sed -E 's/.*"(https[^"]+)"/\1/' | head -n1)"
TAG="$(printf '%s' "$META" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')"

if [ -z "$ZIP_URL" ]; then
  echo "✗ Could not find a .zip asset on the $VERSION release." >&2
  echo "  Check https://github.com/$REPO/releases" >&2
  exit 1
fi

echo "▸ Downloading ${TAG:-$VERSION} …"
curl -fSL --progress-bar -o "$WORK/Glancekit.zip" "$ZIP_URL"

echo "▸ Unpacking …"
# ditto -x -k merges the AppleDouble (._*) metadata the release zip carries,
# instead of littering the tree with sidecar ._ files the way unzip would.
ditto -x -k "$WORK/Glancekit.zip" "$WORK/extracted"
BUILT="$(/usr/bin/find "$WORK/extracted" -maxdepth 2 -name "$APP_NAME" -type d | head -n1)"
if [ -z "$BUILT" ] || [ ! -d "$BUILT" ]; then
  echo "✗ The downloaded archive did not contain $APP_NAME." >&2
  exit 1
fi

echo "▸ Quitting running app + widget …"
osascript -e 'quit app "Glancekit"' 2>/dev/null || true
killall Glancekit GlancekitWidgets 2>/dev/null || true
sleep 1

# Update IN PLACE — never `rm -rf "$DEST"` first. A placed widget's settings are
# App-Intent values chronod holds against the widget instance; if the appex
# vanishes even briefly chronod prunes the instance and loses that config.
# rsync --delete swaps the contents while the bundle itself stays put.
echo "▸ Installing to $DEST (in place) …"
if [ -d "$DEST" ]; then
  rsync -a --delete "$BUILT/" "$DEST/"
else
  ditto "$BUILT" "$DEST"
fi

# Curl-downloaded bundles carry com.apple.quarantine; combined with ad-hoc
# signing that makes Gatekeeper block the first launch outright. Strip it.
echo "▸ Removing download quarantine …"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "▸ Re-registering with LaunchServices …"
"$LSREGISTER" -f -R "$DEST"

echo "▸ Restarting extension + widget daemons (pkd, chronod) …"
killall pkd chronod 2>/dev/null || true

echo "▸ Launching …"
open "$DEST"

echo "▸ Verifying pkd registration …"
sleep 4
if pluginkit -m -p com.apple.widgetkit-extension 2>/dev/null | grep -q GlancekitWidgets; then
  echo "✓ Installed ${TAG:-} and registered. Open the widget gallery to add widgets."
else
  echo "⚠ Installed ${TAG:-}, but pkd has not registered the widget yet."
  echo "  If widgets don't appear, log out/in once to force a pkd rescan."
fi
