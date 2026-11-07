import AppKit
import os

/// Owns the app's long-lived services and the menu bar status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let strHideNativeDockKey = "HideNativeDock"

    private let objAppTracker = AppTracker()
    private let objWindowService = WindowService()
    private let objNativeDock = NativeDockController()
    private var objDockController: DockController?
    private var objStatusItem: NSStatusItem?
    private var objHideDockMenuItem: NSMenuItem?

    /// Whether the user wants the native Dock hidden while MacDock runs.
    private var blnHideNativeDock: Bool {
        get { UserDefaults.standard.bool(forKey: Self.strHideNativeDockKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.strHideNativeDockKey) }
    }

    /// Boots services, reconciles native Dock state, and shows the dock panel.
    /// - Parameter notification: Launch notification (unused).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for Accessibility up front; window listing/raising needs it.
        AccessibilityPermission.requestIfNeeded()

        // Reconcile the native Dock with the saved preference. This also repairs
        // the case where a previous run was force-quit while the Dock was hidden.
        if blnHideNativeDock {
            objNativeDock.hide()
        } else if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }

        objAppTracker.start()

        let objController = DockController(objTracker: objAppTracker, objWindowService: objWindowService)
        objController.show()
        objDockController = objController

        buildStatusItem()

        // Debug aid: `open MacDock.app --args --dump-windows` logs every app's windows.
        if CommandLine.arguments.contains("--dump-windows") {
            let objLogger = Logger(subsystem: "com.slynck.macdock", category: "dump")
            for objItem in objAppTracker.arrObjItems {
                guard let objApp = objItem.objRunningApp else { continue }
                let arrStrTitles = objWindowService.windows(for: objApp).map {
                    $0.strTitle + ($0.blnIsOnOtherSpace ? " [other desktop]" : "") + ($0.blnIsMinimized ? " [minimized]" : "")
                }
                objLogger.notice("\(objItem.strName, privacy: .public): \(arrStrTitles, privacy: .public)")
            }
        }
    }

    /// Restores the native Dock on a normal quit so the user is never left without one.
    /// - Parameter notification: Termination notification (unused).
    func applicationWillTerminate(_ notification: Notification) {
        if objNativeDock.blnIsHiddenByUs {
            objNativeDock.restore()
        }
    }

    // MARK: - Status item

    /// Creates the menu bar item that hosts MacDock's controls.
    private func buildStatusItem() {
        let objItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        objItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MacDock")

        let objMenu = NSMenu()

        let objHideItem = NSMenuItem(title: "Hide Native Dock", action: #selector(toggleNativeDock), keyEquivalent: "")
        objHideItem.target = self
        objHideItem.state = blnHideNativeDock ? .on : .off
        objMenu.addItem(objHideItem)
        objHideDockMenuItem = objHideItem

        let objPermissionItem = NSMenuItem(title: "Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        objPermissionItem.target = self
        objMenu.addItem(objPermissionItem)

        objMenu.addItem(.separator())

        let objQuitItem = NSMenuItem(title: "Quit MacDock", action: #selector(quit), keyEquivalent: "q")
        objQuitItem.target = self
        objMenu.addItem(objQuitItem)

        objItem.menu = objMenu
        objStatusItem = objItem
    }

    /// Flips the "hide native Dock" preference and applies it immediately.
    @objc private func toggleNativeDock() {
        blnHideNativeDock.toggle()
        if blnHideNativeDock {
            objNativeDock.hide()
        } else {
            objNativeDock.restore()
        }
        objHideDockMenuItem?.state = blnHideNativeDock ? .on : .off
    }

    /// Opens System Settings at Privacy & Security → Accessibility.
    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    /// Quits MacDock (the termination hook restores the native Dock).
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
