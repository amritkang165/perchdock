#!/usr/bin/env bash
# Regenerates the Xcode project, builds PerchDock (Debug), and optionally launches it.
# Usage: scripts/build.sh [--run]
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

if [[ "${1:-}" == "--run" ]]; then
  # Quit any running instance first so the new build takes over.
  pkill -x PerchDock 2>/dev/null || true
  open "$APP_PATH"
fi
