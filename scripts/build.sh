#!/usr/bin/env bash
# Regenerates the Xcode project, builds MacDock (Debug), and optionally launches it.
# Usage: scripts/build.sh [--run]
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate --quiet

xcodebuild \
  -project MacDock.xcodeproj \
  -scheme MacDock \
  -configuration Debug \
  -derivedDataPath build \
  -quiet \
  build

APP_PATH="build/Build/Products/Debug/MacDock.app"
echo "Built: $APP_PATH"

if [[ "${1:-}" == "--run" ]]; then
  # Quit any running instance first so the new build takes over.
  pkill -x MacDock 2>/dev/null || true
  open "$APP_PATH"
fi
