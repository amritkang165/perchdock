import AppKit
import os

/// Owns the app's long-lived services and the menu bar status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let objSettings: SettingsStore = {
        // Settings must be carried over from the old name before SettingsStore reads them.
        LegacyDefaultsMigration.run()
        return SettingsStore()
    }()
    private lazy var objAppTracker = AppTracker(objSettings: objSettings)
    private let objWindowService = WindowService()
    private let objThumbnailService = ThumbnailService()
    private let objNewWindowTracker = NewWindowTracker()
    private let objDockBadges = DockBadgeService()
    private let objNowPlaying = NowPlayingService()
    private let objBattery = BatteryService()
    private let objNativeDock = NativeDockController()
    private let objUpdates = UpdateController()
    private let objSpaceKeeper = DockSpaceKeeper()
    private lazy var objSettingsWindow = SettingsWindowController(objSettings: objSettings, objThumbnailService: objThumbnailService)
    private var objDockController: DockController?
    private var objStatusItem: NSStatusItem?
    /// Extra docks, one per non-main display, in "every display" mode.
    private var arrObjExtraDocks: [DockController] = []
    private var objScreensObserver: NSObjectProtocol?

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
        startWidgets()
        // Raising a window from the dock means the user has seen it.
        objWindowService.onRaised = { [weak self] intWindowId in
            self?.objNewWindowTracker.markSeen(intWindowId)
        }

        let objController = makeDockController(intFixedScreenId: nil)
        objController.show()
        objDockController = objController

        // "Every display" mode: extra docks follow the setting and connected displays.
        syncExtraDocks()
        observeDisplayMode()
        objScreensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncExtraDocks() }
        }

        // Windows stay out from under every dock while it's always shown.
        objSpaceKeeper.fnReservedStrips = { [weak self] in
            guard let self else { return [] }
            return ([self.objDockController] + self.arrObjExtraDocks).compactMap { $0?.reservedStrip() }
        }
        objWindowService.fnUsableFrame = { [weak self] objScreen in
            self?.objSpaceKeeper.usableFrame(of: objScreen) ?? objScreen.visibleFrame
        }
        objSpaceKeeper.start()

        buildStatusItem()
        runDebugArguments(objController)
    }

    // MARK: - Docks per display

    /// Creates a dock wired to the shared services.
    /// - Parameter intFixedScreenId: Display to pin it to, or `nil` for the main dock.
    /// - Returns: The controller (not yet shown).
    private func makeDockController(intFixedScreenId: CGDirectDisplayID?) -> DockController {
        let objController = DockController(
            objTracker: objAppTracker,
            objWindowService: objWindowService,
            objThumbnailService: objThumbnailService,
            objNewWindowTracker: objNewWindowTracker,
            objBadges: objDockBadges,
            objNowPlaying: objNowPlaying,
            objBattery: objBattery,
            objSettings: objSettings,
            intFixedScreenId: intFixedScreenId
        )
        objController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        return objController
    }

    /// In "every display" mode, keeps one extra dock on each display other than the
    /// main one (the main dock stays on the menu-bar display); otherwise removes them.
    private func syncExtraDocks() {
        let setIntWanted: Set<CGDirectDisplayID> = objSettings.enmDisplayMode == .everyDisplay
            ? Set(NSScreen.screens.dropFirst().compactMap { DockController.displayId(of: $0) })
            : []

        // Drop docks whose display is gone or no longer wanted.
        arrObjExtraDocks.removeAll { objDock in
            guard let intId = objDock.intFixedScreenId, setIntWanted.contains(intId) else {
                objDock.tearDown()
                return true
            }
            return false
        }

        // Add docks for newly wanted displays.
        let setIntHave = Set(arrObjExtraDocks.compactMap(\.intFixedScreenId))
        for intId in setIntWanted.subtracting(setIntHave) {
            let objDock = makeDockController(intFixedScreenId: intId)
            objDock.show()
            arrObjExtraDocks.append(objDock)
        }
    }

    /// Re-syncs the extra docks whenever the display mode changes.
    private func observeDisplayMode() {
        withObservationTracking {
            _ = objSettings.enmDisplayMode
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; apply on the next turn.
            Task { @MainActor [weak self] in
                self?.syncExtraDocks()
                self?.observeDisplayMode()
            }
        }
    }

    /// Starts the widget services and tells the dock which widget tiles to show.
    ///
    /// Tiles draw live from the services; the dock only rebuilds when a tile should
    /// appear/disappear or its hover label (track name, battery summary) changes.
    private func startWidgets() {
        objAppTracker.fnWidgets = { [weak self] in
            guard let self else { return [] }
            var arrObjTiles: [AppTracker.WidgetTile] = []
            if self.objSettings.blnShowNowPlaying, let objTrack = self.objNowPlaying.objTrack {
                let strName = objTrack.strArtist.isEmpty ? objTrack.strTitle : "\(objTrack.strTitle) — \(objTrack.strArtist)"
                arrObjTiles.append(AppTracker.WidgetTile(
                    enmWidget: .nowPlaying, strName: strName,
                    objIcon: objTrack.objArtwork ?? NowPlayingTileView.appIcon(for: objTrack.strBundleId)
                ))
            }
            if self.objSettings.blnShowBattery, self.objBattery.blnHasBattery {
                arrObjTiles.append(AppTracker.WidgetTile(
                    enmWidget: .battery, strName: self.objBattery.strSummary,
                    objIcon: NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery") ?? NSImage()
                ))
            }
            return arrObjTiles
        }
        objNowPlaying.onChange = { [weak self] in self?.objAppTracker.rebuild() }
        objBattery.onChange = { [weak self] in self?.objAppTracker.rebuild() }
        objNowPlaying.start()
        objBattery.start()
    }

    /// Restores the native Dock on a normal quit so the user is never left without one.
    /// - Parameter notification: Termination notification (unused).
    func applicationWillTerminate(_ notification: Notification) {
        objNowPlaying.stop()
        if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }
    }

    /// Hides or restores the native Dock.
    /// - Parameter blnHide: Whether the native Dock should be hidden.
    private func applyNativeDock(_ blnHide: Bool) {
        if blnHide {
            objNativeDock.hide()
        } else if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }
    }

    // MARK: - Status item

    /// Creates the menu bar item that hosts PerchDock's controls. The menu is filled
    /// in `menuNeedsUpdate(_:)` each time it opens, so checkmarks match the settings.
    private func buildStatusItem() {
        let objItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        objItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "PerchDock")

        let objMenu = NSMenu()
        objMenu.delegate = self
        objItem.menu = objMenu
        objStatusItem = objItem
    }

    /// Rebuilds the status menu: quick settings, then Settings, updates and Quit.
    /// - Parameter objMenu: The status item's menu, about to open.
    func menuNeedsUpdate(_ objMenu: NSMenu) {
        objMenu.removeAllItems()

        QuickSettingsMenu.add(to: objMenu, objSettings: objSettings)
        objMenu.addItem(.separator())

        let objSettingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        objSettingsItem.target = self
        objMenu.addItem(objSettingsItem)

        // Only builds published with an update feed can update themselves.
        if objUpdates.blnIsConfigured {
            let objUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            objUpdateItem.target = self
            objMenu.addItem(objUpdateItem)
        }

        objMenu.addItem(.separator())

        let objQuitItem = NSMenuItem(title: "Quit PerchDock", action: #selector(quit), keyEquivalent: "q")
        objQuitItem.target = self
        objMenu.addItem(objQuitItem)
    }

    /// Opens the Settings window.
    @objc private func openSettings() {
        objSettingsWindow.show()
    }

    /// Checks for a new version via Sparkle.
    @objc private func checkForUpdates() {
        objUpdates.checkForUpdates()
    }

    /// Quits PerchDock (the termination hook restores the native Dock).
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Debug

    /// Handles debug launch arguments.
    /// - `--cycle-pickers`: stress-tests picker switching.
    /// - `--dump-windows`: logs every app's windows.
    /// - `--dump-recents=BUNDLE_ID,…`: writes apps' recent documents to /tmp/perchdock-recents.txt.
    /// - `--open-settings`: opens the Settings window.
    /// - `--flyout`: opens the side-dock Now Playing fly-out.
    /// - `--dock-menu=BUNDLE_ID`: writes the app's borrowed native Dock actions to /tmp/perchdock-dockmenu.txt.
    /// - `--dock-action=BUNDLE_ID,TITLE`: presses an item in the app's native Dock menu.
    /// - Parameter objController: The dock controller.
    private func runDebugArguments(_ objController: DockController) {
        let arrStrArgs = CommandLine.arguments

        // `--tile=BUNDLE_ID,left|right|fill`: tiles that app's front window on this desktop.
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--tile=") }) {
            let arrStrParts = strArg.dropFirst("--tile=".count).split(separator: ",").map(String.init)
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard arrStrParts.count == 2,
                      let objApp = NSRunningApplication.runningApplications(withBundleIdentifier: arrStrParts[0]).first,
                      let objWindow = objWindowService.windows(for: objApp).first(where: { !$0.blnIsOnOtherSpace }) else { return }
                let enmTile: WindowService.Tile = switch arrStrParts[1] {
                case "left": .leftHalf
                case "right": .rightHalf
                default: .fill
                }
                objWindowService.tile(objWindow, of: objApp, to: enmTile)
            }
        }
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
                // Optional `--peek=CARD`: then peek at that card.
                if let strPeek = arrStrArgs.first(where: { $0.hasPrefix("--peek=") }),
                   let intCard = Int(strPeek.dropFirst("--peek=".count)) {
                    // Cards load asynchronously; wait up to ~4 s for this one.
                    for _ in 0..<40 where !objController.debugPeek(atCard: intCard) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--preview-group=") }),
           let intIndex = Int(strArg.dropFirst("--preview-group=".count)) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                objController.debugPreviewGroup(atIndex: intIndex)
            }
        }
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--show-grid=") }),
           let intIndex = Int(strArg.dropFirst("--show-grid=".count)) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                objController.debugToggleGrid(atIndex: intIndex)
                // Optional follow-ups: `--grid-preview=TILE`, `--grid-rename`.
                try? await Task.sleep(for: .milliseconds(400))
                if let strTile = arrStrArgs.first(where: { $0.hasPrefix("--grid-preview=") }),
                   let intTile = Int(strTile.dropFirst("--grid-preview=".count)) {
                    objController.debugPreviewGridTile(intTile)
                }
                if let strDrag = arrStrArgs.first(where: { $0.hasPrefix("--grid-drag=") }) {
                    let arrInt = strDrag.dropFirst("--grid-drag=".count).split(separator: ",").compactMap { Int($0) }
                    if arrInt.count == 2 { objController.debugReorderGrid(from: arrInt[0], to: arrInt[1]) }
                }
                if arrStrArgs.contains("--grid-rename") {
                    objController.debugEditGridTitle()
                }
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
        // `--dock-menu=BUNDLE_ID`: writes the app's borrowed Dock actions to /tmp/perchdock-dockmenu.txt.
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--dock-menu=") }) {
            let strBundleId = String(strArg.dropFirst("--dock-menu=".count))
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strBundleId) else { return }
                let intPid = NSRunningApplication.runningApplications(withBundleIdentifier: strBundleId).first?.processIdentifier
                let objStart = ContinuousClock.now
                let arrObjEntries = NativeDockMenuService.entries(forAppAt: objUrl, intPid: intPid, setStrSkip: [])
                let objElapsed = ContinuousClock.now - objStart
                let arrStrLines = ["took \(objElapsed)"] + arrObjEntries.map { objEntry in
                    switch objEntry {
                    case .action(let strTitle, _): strTitle
                    case .header(let strTitle): "[\(strTitle)]"
                    case .separator: "---"
                    }
                }
                try? arrStrLines.joined(separator: "\n").write(toFile: "/tmp/perchdock-dockmenu.txt", atomically: true, encoding: .utf8)
            }
        }

        // `--dock-action=BUNDLE_ID,TITLE`: presses an item in the app's native Dock menu.
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--dock-action=") }) {
            let arrStrParts = strArg.dropFirst("--dock-action=".count).split(separator: ",", maxSplits: 1).map(String.init)
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard arrStrParts.count == 2,
                      let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arrStrParts[0]) else { return }
                NativeDockMenuService.perform(arrStrParts[1], intIndex: -1, forAppAt: objUrl)
            }
        }

        // `--flyout`: opens the side-dock Now Playing fly-out once something is playing.
        if arrStrArgs.contains("--flyout") {
            Task { @MainActor in
                for _ in 0..<50 where !objController.debugShowFlyout() {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        // `--dump-recents=BUNDLE_ID[,BUNDLE_ID…]`: writes each app's recent documents to /tmp/perchdock-recents.txt.
        if let strArg = arrStrArgs.first(where: { $0.hasPrefix("--dump-recents=") }) {
            var strReport = ""
            for strId in strArg.dropFirst("--dump-recents=".count).split(separator: ",").map(String.init) {
                let objStart = ContinuousClock.now
                let arrObjDocs = RecentDocumentsService.documents(
                    forBundleId: strId, objAppUrl: NSWorkspace.shared.urlForApplication(withBundleIdentifier: strId))
                strReport += "\(strId) (\(ContinuousClock.now - objStart)):\n"
                strReport += arrObjDocs.map { "  \($0.path)\n" }.joined()
            }
            try? strReport.write(toFile: "/tmp/perchdock-recents.txt", atomically: true, encoding: .utf8)
        }
        if arrStrArgs.contains("--dump-dock") {
            objDockBadges.debugDump(objLogger: Logger(subsystem: "com.slynck.perchdock", category: "dump"))
        }
        if arrStrArgs.contains("--dump-windows") {
            let objLogger = Logger(subsystem: "com.slynck.perchdock", category: "dump")
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
