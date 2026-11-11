#!/bin/sh
# Installs the latest Moodboard release.
#   curl -fsSL https://raw.githubusercontent.com/shariqmalik10/moodboard/main/scripts/install.sh | sh
# Set MOODBOARD_DIR to install somewhere other than ~/Applications.
set -eu

REPO="shariqmalik10/moodboard"
DEST="${MOODBOARD_DIR:-$HOME/Applications}"
URL="https://github.com/$REPO/releases/latest/download/Moodboard.zip"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Moodboard is a macOS app." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "The prebuilt app is for Apple silicon. On an Intel Mac, build it from source:" >&2
  echo "  https://github.com/$REPO#build-from-source" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading Moodboard…"
curl -fL --progress-bar "$URL" -o "$work/Moodboard.zip"
ditto -x -k "$work/Moodboard.zip" "$work"

mkdir -p "$DEST"
if [ -d "$DEST/Moodboard.app" ]; then
  osascript -e 'quit app id "io.github.shariqmalik10.moodboard"' >/dev/null 2>&1 || true
  rm -rf "$DEST/Moodboard.app"
fi
ditto "$work/Moodboard.app" "$DEST/Moodboard.app"
echo "Installed $DEST/Moodboard.app"

if ! command -v node >/dev/null 2>&1; then
  echo "Moodboard runs your projects with Node 20.19 or newer. Get it from https://nodejs.org"
elif ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>20||(a===20&&b>=19)?0:1)' 2>/dev/null; then
  echo "Moodboard runs your projects with Node 20.19 or newer, and this Mac has $(node --version). Get a newer one from https://nodejs.org"
fi

open "$DEST/Moodboard.app"
