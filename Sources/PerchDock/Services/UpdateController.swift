import AppKit
import Sparkle

/// Sparkle auto-updates. Only runs when the app ships with a feed URL
/// (`SUFeedURL` in Info.plist), so local builds never phone home.
@MainActor
final class UpdateController {
    private let objController: SPUStandardUpdaterController?

    /// Whether an update feed is configured.
    var blnIsConfigured: Bool { objController != nil }

    /// Starts the updater if a feed is configured.
    init() {
        let strFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        objController = strFeed.isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Checks for an update now, showing Sparkle's UI.
    func checkForUpdates() {
        NSApp.activate()
        objController?.checkForUpdates(nil)
    }
}
