#!/bin/sh
# Builds Moodboard from this checkout and installs it.
#   scripts/build.sh            installs to ~/Applications (or $MOODBOARD_DIR)
#   scripts/build.sh --zip      writes build/Moodboard.zip, ad-hoc signed
#   scripts/build.sh --release  writes build/Moodboard.zip signed with Developer ID, notarized and stapled
# --release reads MOODBOARD_SIGN_ID (default "Developer ID Application") and
# MOODBOARD_NOTARY_PROFILE (default moodboard-notary, made with `xcrun notarytool store-credentials`).
set -eu
cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$2" >&2; exit 1; }
}

sign_id="${MOODBOARD_SIGN_ID:-Developer ID Application}"
notary_profile="${MOODBOARD_NOTARY_PROFILE:-moodboard-notary}"
if [ "${1:-}" = "--release" ]; then
  security find-identity -v -p codesigning | grep -q "\"$sign_id" \
    || { echo "No \"$sign_id\" certificate in the keychain. Create one in Xcode > Settings > Accounts > Manage Certificates." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
    || { echo "No notary credentials named $notary_profile. Run: xcrun notarytool store-credentials $notary_profile --apple-id <id> --team-id <team>" >&2; exit 1; }
fi

sign() {
  codesign --force --options runtime --timestamp --sign "$sign_id" "$@"
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

if [ "${1:-}" = "--release" ]; then
  # The bundled node_modules carry their own Mach-O binaries; Apple rejects any that are unsigned.
  find "$app/Contents/Resources" -type f -print0 \
    | xargs -0 file | grep 'Mach-O' | grep -v '(for architecture' | cut -d: -f1 \
    | while IFS= read -r binary; do sign "$binary"; done
  sign "$app"
  codesign --verify --deep --strict "$app"
  mkdir -p build
  rm -f build/Moodboard.zip
  ditto -c -k --keepParent "$app" build/Moodboard.zip
  xcrun notarytool submit build/Moodboard.zip --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app"
  rm build/Moodboard.zip
  ditto -c -k --keepParent "$app" build/Moodboard.zip
  spctl --assess --type execute --verbose "$app"
  echo "Wrote build/Moodboard.zip, notarized"
  exit 0
fi

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
