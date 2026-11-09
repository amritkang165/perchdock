#!/usr/bin/env bash
# Regenerates the Xcode project, builds PerchDock (Debug), and optionally launches it.
# Usage: scripts/build.sh [--run | --install]
#   --run      Launch the build straight from build/ (quick dev loop).
#   --install  Copy the build to /Applications and launch it from there.
set -euo pipefail

cd "$(dirname "$0")/.."

# Ensure the local signing identity exists and its keychain is unlocked.
scripts/setup-signing.sh >/dev/null
security unlock-keychain -p perchdock-local "$HOME/Library/Keychains/perchdock-signing.keychain-db"

xcodegen generate --quiet

xcodebuild \
  -project PerchDock.xcodeproj \
  -scheme PerchDock \
  -configuration Debug \
  -derivedDataPath build \
  -quiet \
  build

APP_PATH="build/Build/Products/Debug/PerchDock.app"
echo "Built: $APP_PATH"

case "${1:-}" in
  --run)
    # Quit any running instance first so the new build takes over.
    pkill -x PerchDock 2>/dev/null || true
    open "$APP_PATH"
    ;;
  --install)
    # Replace the installed copy (same signature, so permissions carry over), then launch it.
    pkill -x PerchDock 2>/dev/null || true
    sleep 1
    rm -rf /Applications/PerchDock.app
    ditto "$APP_PATH" /Applications/PerchDock.app
    echo "Installed: /Applications/PerchDock.app"
    open /Applications/PerchDock.app
    ;;
esac
