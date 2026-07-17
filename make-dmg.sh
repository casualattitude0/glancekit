#!/usr/bin/env bash
#
# make-dmg.sh — Build Glancekit in Release and package it as a distributable .dmg.
#
# Produces a disk image containing Glancekit.app plus a shortcut to /Applications,
# so users can install by dragging the app onto the Applications folder.
#
# Usage:
#   ./make-dmg.sh                 # build + package -> dist/Glancekit.dmg
#   ./make-dmg.sh -o out.dmg      # write to a custom output path
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="Glancekit"
APP_NAME="Glancekit.app"
CONFIG="Release"
VOL_NAME="Glancekit"
OUTPUT="${PROJECT_DIR}/dist/Glancekit.dmg"

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -12
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode / Command Line Tools." >&2
  exit 1
fi

cd "$PROJECT_DIR"
echo "▸ Building ${SCHEME} (${CONFIG})…"

BUILD_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGE_DIR"' EXIT

xcodebuild \
  -project "${SCHEME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${BUILD_DIR}" \
  CODE_SIGN_IDENTITY="-" \
  build \
  | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" || true

BUILT_APP="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}"
if [ ! -d "$BUILT_APP" ]; then
  echo "error: build did not produce ${APP_NAME}." >&2
  exit 1
fi

# ── Stage ─────────────────────────────────────────────────────────────────
echo "▸ Staging disk image contents…"
cp -R "$BUILT_APP" "$STAGE_DIR/${APP_NAME}"
# Drag-to-install shortcut.
ln -s /Applications "$STAGE_DIR/Applications"
# Clear quarantine on the app we ship.
xattr -cr "$STAGE_DIR/${APP_NAME}" 2>/dev/null || true

# ── Package ───────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
echo "▸ Building disk image…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUTPUT" >/dev/null

echo "✓ Created: $OUTPUT"
echo "  Distribute this .dmg; users open it and drag Glancekit onto Applications."
