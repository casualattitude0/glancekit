#!/usr/bin/env bash
#
# install.sh — Build Glancekit in Release and install it to /Applications.
#
# Usage:
#   ./install.sh              # build, install, and launch
#   ./install.sh --login      # also add Glancekit as a login item (auto-start)
#   ./install.sh --no-launch  # install but don't launch afterwards
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="Glancekit"
APP_NAME="Glancekit.app"
DEST="/Applications/${APP_NAME}"
CONFIG="Release"

ADD_LOGIN_ITEM=false
LAUNCH=true
for arg in "$@"; do
  case "$arg" in
    --login)     ADD_LOGIN_ITEM=true ;;
    --no-launch) LAUNCH=false ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -12
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode / Command Line Tools." >&2
  exit 1
fi

cd "$PROJECT_DIR"
echo "▸ Building ${SCHEME} (${CONFIG})…"

# Build into a local, predictable products dir so we always know where the .app is.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

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

# ── Install ───────────────────────────────────────────────────────────────
# Quit any running copy so we can overwrite it.
if pgrep -x "${SCHEME}" >/dev/null 2>&1; then
  echo "▸ Quitting running Glancekit…"
  osascript -e "quit app \"${SCHEME}\"" 2>/dev/null || killall "${SCHEME}" 2>/dev/null || true
  sleep 1
fi

echo "▸ Installing to ${DEST}…"
rm -rf "$DEST"
# Prefer plain cp; if /Applications isn't writable, fall back to sudo.
if cp -R "$BUILT_APP" "$DEST" 2>/dev/null; then
  :
else
  echo "  (need admin rights to write to /Applications)"
  sudo cp -R "$BUILT_APP" "$DEST"
fi

# Clear the quarantine flag so it opens without a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ Installed: ${DEST}"

# ── Optional: login item ──────────────────────────────────────────────────
if [ "$ADD_LOGIN_ITEM" = true ]; then
  echo "▸ Adding login item…"
  osascript <<EOF 2>/dev/null || echo "  (couldn't add login item automatically; add it in System Settings ▸ General ▸ Login Items)"
tell application "System Events"
    if not (exists login item "${SCHEME}") then
        make login item at end with properties {path:"${DEST}", hidden:true}
    end if
end tell
EOF
  echo "✓ Glancekit will start automatically at login."
fi

# ── Launch ────────────────────────────────────────────────────────────────
if [ "$LAUNCH" = true ]; then
  echo "▸ Launching…"
  open "$DEST"
  echo "✓ Glancekit is running — look for it in your menu bar."
fi
