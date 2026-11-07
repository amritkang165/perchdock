import AppKit
import os

/// Owns the app's long-lived services and the menu bar status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let objSettings = SettingsStore()
    private lazy var objAppTracker = AppTracker(objSettings: objSettings)
    private let objWindowService = WindowService()
    private let objThumbnailService = ThumbnailService()
    private let objNativeDock = NativeDockController()
    private lazy var objSettingsWindow = SettingsWindowController(objSettings: objSettings, objThumbnailService: objThumbnailService)
    private var objDockController: DockController?
    private var objStatusItem: NSStatusItem?
    private var objHideDockMenuItem: NSMenuItem?

    /// Boots services, reconciles native Dock state, and shows the dock panel.
    /// - Parameter notification: Launch notification (unused).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for Accessibility up front; window listing/raising needs it.
        AccessibilityPermission.requestIfNeeded()
        // Previews need Screen Recording; ask early since macOS applies it only after a relaunch.
        objThumbnailService.requestPermissionIfNeeded()

        // Reconcile the native Dock with the saved preference. This also repairs
        // the case where a previous run was force-quit while the Dock was hidden.
        applyNativeDock(objSettings.blnHideNativeDock)
        objSettings.onHideNativeDockChange = { [weak self] blnHide in
            self?.applyNativeDock(blnHide)
        }

        objAppTracker.start()

        let objController = DockController(
            objTracker: objAppTracker,
            objWindowService: objWindowService,
            objThumbnailService: objThumbnailService,
            objSettings: objSettings
        )
        objController.show()
        objDockController = objController

        buildStatusItem()
        runDebugArguments(objController)
    }

    /// Restores the native Dock on a normal quit so the user is never left without one.
    /// - Parameter notification: Termination notification (unused).
    func applicationWillTerminate(_ notification: Notification) {
        if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }
    }

    /// Hides or restores the native Dock and syncs the menu checkmark.
    /// - Parameter blnHide: Whether the native Dock should be hidden.
    private func applyNativeDock(_ blnHide: Bool) {
        if blnHide {
            objNativeDock.hide()
        } else if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }
        objHideDockMenuItem?.state = blnHide ? .on : .off
    }

    // MARK: - Status item

    /// Creates the menu bar item that hosts MacDock's controls.
    private func buildStatusItem() {
        let objItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        objItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MacDock")

        let objMenu = NSMenu()

        let objSettingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        objSettingsItem.target = self
        objMenu.addItem(objSettingsItem)

        let objHideItem = NSMenuItem(title: "Hide Native Dock", action: #selector(toggleNativeDock), keyEquivalent: "")
        objHideItem.target = self
        objHideItem.state = objSettings.blnHideNativeDock ? .on : .off
        objMenu.addItem(objHideItem)
        objHideDockMenuItem = objHideItem

        objMenu.addItem(.separator())

        let objQuitItem = NSMenuItem(title: "Quit MacDock", action: #selector(quit), keyEquivalent: "q")
        objQuitItem.target = self
        objMenu.addItem(objQuitItem)

        objItem.menu = objMenu
        objStatusItem = objItem
    }

    /// Opens the Settings window.
    @objc private func openSettings() {
        objSettingsWindow.show()
    }

    /// Flips the "hide native Dock" preference (the settings store applies it).
    @objc private func toggleNativeDock() {
        objSettings.blnHideNativeDock.toggle()
    }

    /// Quits MacDock (the termination hook restores the native Dock).
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Debug

    /// Handles debug launch arguments.
    /// - `--cycle-pickers`: stress-tests picker switching.
    /// - `--dump-windows`: logs every app's windows.
    /// - `--open-settings`: opens the Settings window.
    /// - Parameter objController: The dock controller.
    private func runDebugArguments(_ objController: DockController) {
        let arrStrArgs = CommandLine.arguments

        if arrStrArgs.contains("--cycle-pickers") {
            objController.debugCyclePickers(intRounds: 5)
        }
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--magnify-at=") }),
           let intIndex = Int(strArg.dropFirst("--magnify-at=".count)) {
            objController.debugMagnify(atIndex: intIndex)
        }
        if arrStrArgs.contains("--open-settings") {
            objSettingsWindow.show()
        }
        if arrStrArgs.contains("--dump-windows") {
            let objLogger = Logger(subsystem: "com.slynck.macdock", category: "dump")
            for objItem in objAppTracker.arrObjItems {
                guard let objApp = objItem.objRunningApp else { continue }
                let arrStrTitles = objWindowService.windows(for: objApp).map {
                    $0.strTitle + " [\($0.strDesktopLabel ?? "-")]" + ($0.blnIsMinimized ? " [minimized]" : "")
                }
                objLogger.notice("\(objItem.strName, privacy: .public): \(arrStrTitles, privacy: .public)")
            }
        }
    }
}
