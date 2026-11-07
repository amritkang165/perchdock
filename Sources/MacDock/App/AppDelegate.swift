import AppKit
import os

/// Owns the app's long-lived services and the menu bar status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let objSettings = SettingsStore()
    private lazy var objAppTracker = AppTracker(objSettings: objSettings)
    private let objWindowService = WindowService()
    private let objThumbnailService = ThumbnailService()
    private let objNewWindowTracker = NewWindowTracker()
    private let objDockBadges = DockBadgeService()
    private let objNativeDock = NativeDockController()
    private let objUpdates = UpdateController()
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

        // Minimized tiles show the window's last captured preview.
        objAppTracker.fnThumbnail = { [weak self] intWindowId in
            self?.objThumbnailService.cachedThumbnail(for: intWindowId)
        }
        objAppTracker.start()
        objNewWindowTracker.start()
        objDockBadges.start()
        // Raising a window from the dock means the user has seen it.
        objWindowService.onRaised = { [weak self] intWindowId in
            self?.objNewWindowTracker.markSeen(intWindowId)
        }

        let objController = DockController(
            objTracker: objAppTracker,
            objWindowService: objWindowService,
            objThumbnailService: objThumbnailService,
            objNewWindowTracker: objNewWindowTracker,
            objBadges: objDockBadges,
            objSettings: objSettings
        )
        objController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
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

        // Only builds published with an update feed can update themselves.
        if objUpdates.blnIsConfigured {
            let objUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            objUpdateItem.target = self
            objMenu.addItem(objUpdateItem)
        }

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

    /// Checks for a new version via Sparkle.
    @objc private func checkForUpdates() {
        objUpdates.checkForUpdates()
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
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--show-picker=") }),
            let intIndex = Int(strArg.dropFirst("--show-picker=".count)) {
            // Optional `--show-picker-delay=S`: wait first (e.g. to open a window meanwhile).
            let fltDelay = arrStrArgs.first(where: { $0.hasPrefix("--show-picker-delay=") })
                .flatMap { Double($0.dropFirst("--show-picker-delay=".count)) } ?? 0
            Task {
                try? await Task.sleep(for: .seconds(fltDelay))
                objController.debugShowPicker(atIndex: intIndex)
            }
        }
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--show-grid=") }),
           let intIndex = Int(strArg.dropFirst("--show-grid=".count)) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                objController.debugToggleGrid(atIndex: intIndex)
            }
        }
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--bring-here=") }),
           let intWindowId = CGWindowID(strArg.dropFirst("--bring-here=".count)) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                // Find the window's app and entry among its windows.
                for objApp in NSWorkspace.shared.runningApplications where objApp.activationPolicy == .regular {
                    if let objWindow = objWindowService.windows(for: objApp).first(where: { $0.intWindowId == intWindowId }) {
                        objController.bringWindowHere(objWindow, of: objApp)
                        break
                    }
                }
            }
        }
        if arrStrArgs.contains("--open-settings") {
            objSettingsWindow.show()
        }
        if arrStrArgs.contains("--fake-badges") {
            objDockBadges.debugFake(strBadgeId: "com.google.Chrome", strProgressId: "com.apple.finder")
        }
        if arrStrArgs.contains("--dump-dock") {
            objDockBadges.debugDump(objLogger: Logger(subsystem: "com.slynck.macdock", category: "dump"))
        }
        if arrStrArgs.contains("--dump-windows") {
            let objLogger = Logger(subsystem: "com.slynck.macdock", category: "dump")
            for objItem in objAppTracker.arrObjItems {
                guard let objApp = objItem.objRunningApp else { continue }
                let arrObjWindows = objWindowService.windows(for: objApp)
                let arrStrTitles = arrObjWindows.map {
                    $0.strTitle + " [\($0.strDesktopLabel ?? "-")]" + ($0.blnIsMinimized ? " [minimized]" : "")
                }
                objLogger.notice("\(objItem.strName, privacy: .public): \(arrStrTitles, privacy: .public)")

                // Tab bars, for middle-click "close tab".
                for objWindow in arrObjWindows where objWindow.objElement != nil {
                    let arrObjTabs = objWindowService.tabs(in: objWindow)
                    guard !arrObjTabs.isEmpty else { continue }
                    let arrStrTabs = arrObjTabs.map { ($0.blnIsSelected ? "*" : "") + $0.strTitle }
                    objLogger.notice("  tabs in \(objWindow.strTitle, privacy: .public): \(arrStrTabs, privacy: .public)")
                }

                // Check that other-desktop windows can be resolved to AX elements (needed to switch to them).
                for objWindow in arrObjWindows where objWindow.blnIsOnOtherSpace {
                    guard let intWindowId = objWindow.intWindowId else { continue }
                    let objStart = ContinuousClock.now
                    let blnFound = PrivateWindowAPI.axElement(forWindowId: intWindowId, intPid: objApp.processIdentifier) != nil
                    objLogger.notice("  other-desktop \(intWindowId) \(objWindow.strTitle, privacy: .public): AX \(blnFound ? "found" : "NOT found", privacy: .public) in \(ContinuousClock.now - objStart, privacy: .public)")
                }
            }
        }
    }
}
