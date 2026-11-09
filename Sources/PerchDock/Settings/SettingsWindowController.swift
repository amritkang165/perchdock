import AppKit
import SwiftUI

/// Owns the Settings window. PerchDock is an agent app with no main menu, so the
/// window is managed directly rather than through SwiftUI's `Settings` scene.
@MainActor
final class SettingsWindowController {
    private let objSettings: SettingsStore
    private let objThumbnailService: ThumbnailService
    private var objWindow: NSWindow?

    /// Creates the controller (the window is built on first use).
    /// - Parameters:
    ///   - objSettings: Preferences to edit.
    ///   - objThumbnailService: Used to report Screen Recording status.
    init(objSettings: SettingsStore, objThumbnailService: ThumbnailService) {
        self.objSettings = objSettings
        self.objThumbnailService = objThumbnailService
    }

    /// Shows the Settings window and brings PerchDock forward so it gets focus.
    func show() {
        if objWindow == nil {
            let objHosting = NSHostingController(rootView: SettingsView(objSettings: objSettings, objThumbnailService: objThumbnailService))
            let objNewWindow = NSWindow(contentViewController: objHosting)
            objNewWindow.title = "PerchDock Settings"
            objNewWindow.styleMask = [.titled, .closable]
            objNewWindow.isReleasedWhenClosed = false
            objNewWindow.center()
            objWindow = objNewWindow
        }
        NSApp.activate()
        objWindow?.makeKeyAndOrderFront(nil)
    }
}
