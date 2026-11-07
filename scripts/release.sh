#!/usr/bin/env bash
# Builds MacDock (Release) and packages it as a drag-to-install DMG in dist/.
#
# Usage: scripts/release.sh
#
# Auto-updates (optional, one-time setup):
#   1. Generate a signing key pair (stored in your login keychain):
#        build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#   2. Put the printed public key in project.yml as SUPublicEDKey, and the URL
#      where you'll host appcast.xml as SUFeedURL.
#   3. Run this script; it prints the signature line for the new appcast entry.
#
# Sharing with other Macs needs a Developer ID certificate and notarization;
# the local self-signed identity only works on this Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/setup-signing.sh >/dev/null
security unlock-keychain -p macdock-local "$HOME/Library/Keychains/macdock-signing.keychain-db"

xcodegen generate --quiet

xcodebuild \
  -project MacDock.xcodeproj \
  -scheme MacDock \
  -configuration Release \
  -derivedDataPath build \
  -quiet \
  build

APP_PATH="build/Build/Products/Release/MacDock.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="dist/MacDock-$VERSION.dmg"

# Stage the app next to an /Applications link so users can drag to install.
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p dist
rm -f "$DMG_PATH"
hdiutil create -quiet -volname "MacDock $VERSION" -srcfolder "$STAGE_DIR" -format UDZO "$DMG_PATH"
echo "Built: $DMG_PATH"

# Sparkle signature for the appcast entry (needs a key from generate_keys).
SIGN_UPDATE="build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -x "$SIGN_UPDATE" ]]; then
  if SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" 2>/dev/null); then
    echo "Appcast enclosure attributes: $SIGNATURE"
  else
    echo "No Sparkle key yet; run $(dirname "$SIGN_UPDATE")/generate_keys to enable signed updates."
  fi
fi
