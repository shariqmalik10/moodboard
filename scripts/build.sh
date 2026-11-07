#!/bin/sh
# Builds Moodboard from this checkout and installs it.
#   scripts/build.sh            installs to ~/Applications (or $MOODBOARD_DIR)
#   scripts/build.sh --zip      writes build/Moodboard.zip for a release instead
set -eu
cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$2" >&2; exit 1; }
}
need node "Install Node 20.19 or newer from https://nodejs.org"
need xcodebuild "Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>20||(a===20&&b>=19)?0:1)' \
  || { echo "Node $(node --version) is too old. Moodboard needs 20.19 or newer." >&2; exit 1; }

npm ci
npm run build

xcodebuild -project native/Moodboard.xcodeproj -scheme Moodboard -configuration Release \
  -derivedDataPath native/build -quiet build
app="native/build/Build/Products/Release/Moodboard.app"

if [ "${1:-}" = "--zip" ]; then
  mkdir -p build
  rm -f build/Moodboard.zip
  ditto -c -k --keepParent "$app" build/Moodboard.zip
  echo "Wrote build/Moodboard.zip"
  exit 0
fi

dest="${MOODBOARD_DIR:-$HOME/Applications}"
mkdir -p "$dest"
osascript -e 'quit app id "io.github.shariqmalik10.moodboard"' >/dev/null 2>&1 || true
rm -rf "$dest/Moodboard.app"
ditto "$app" "$dest/Moodboard.app"
echo "Installed $dest/Moodboard.app"
open "$dest/Moodboard.app"
