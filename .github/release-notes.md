## Install

1. Download `PerchDock-<version>.dmg` below, open it, and drag **PerchDock** into **Applications**.
2. Open PerchDock from Applications. macOS will say it can't check the app for malicious software, because this build isn't notarized by Apple yet. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to PerchDock. You only need to do this once.
4. Grant **Accessibility** (and optionally **Screen Recording** for window previews) when PerchDock asks.

Needs macOS 15 Sequoia or later, on an Apple silicon or Intel Mac.

> **Updating from an earlier download:** macOS ties permissions to each build of an un-notarized app, so after updating you may need to turn PerchDock's Accessibility and Screen Recording switches off and on again.

To check the download, compare `shasum -a 256 PerchDock-<version>.dmg` with the `.sha256` file.
