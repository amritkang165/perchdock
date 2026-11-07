#!/usr/bin/env bash
# Emergency restore: brings the native macOS Dock back to default auto-hide behavior.
# Use this if MacDock was force-quit while the native Dock was hidden.
set -euo pipefail

defaults delete com.apple.dock autohide-delay 2>/dev/null || true
defaults delete com.apple.dock autohide-time-modifier 2>/dev/null || true
defaults write com.apple.dock autohide -bool false
killall Dock
echo "Native Dock restored."
