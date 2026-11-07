import AppKit
import ApplicationServices

/// A single top-level window belonging to an app.
struct WindowInfo: Identifiable {
    let id: Int
    let strTitle: String
    let blnIsMinimized: Bool
    let intWindowId: CGWindowID?
    let objElement: AXUIElement
}

/// Lists an app's windows and raises a specific one, via the Accessibility API.
///
/// This is the fix for the native Dock's grouping problem: the Dock activates an
/// *app*, which leaves its current front window in front. Here we raise the exact
/// window the user picked, even when another window of the same app is on top.
@MainActor
final class WindowService {
    /// Returns the standard windows of an app on the current Space, front to back.
    /// Windows on other Spaces aren't reported by AX (handled in a later phase).
    /// - Parameter objApp: The running application.
    /// - Returns: Its windows, or an empty array without Accessibility permission.
    func windows(for objApp: NSRunningApplication) -> [WindowInfo] {
        guard AccessibilityPermission.blnIsTrusted else { return [] }

        let objAxApp = AXUIElementCreateApplication(objApp.processIdentifier)
        // Keep a hung app from stalling the dock.
        AXUIElementSetMessagingTimeout(objAxApp, 0.5)

        guard let arrObjElements: [AXUIElement] = attribute(objAxApp, kAXWindowsAttribute) else { return [] }

        return arrObjElements.compactMap { objElement in
            // Skip sheets, panels, popovers and other non-document windows.
            let strSubrole: String? = attribute(objElement, kAXSubroleAttribute)
            guard strSubrole == kAXStandardWindowSubrole else { return nil }

            let strTitle: String = attribute(objElement, kAXTitleAttribute) ?? ""
            let blnMinimized: Bool = attribute(objElement, kAXMinimizedAttribute) ?? false
            let intWindowId = PrivateWindowAPI.windowId(for: objElement)

            return WindowInfo(
                id: intWindowId.map(Int.init) ?? Int(bitPattern: CFHash(objElement)),
                strTitle: strTitle.isEmpty ? (objApp.localizedName ?? "Untitled") : strTitle,
                blnIsMinimized: blnMinimized,
                intWindowId: intWindowId,
                objElement: objElement
            )
        }
    }

    /// Brings one specific window to the front and gives it keyboard focus.
    /// - Parameters:
    ///   - objWindow: Window to raise.
    ///   - objApp: The app that owns it.
    func raise(_ objWindow: WindowInfo, of objApp: NSRunningApplication) {
        if objApp.isHidden {
            objApp.unhide()
        }

        if objWindow.blnIsMinimized {
            AXUIElementSetAttributeValue(objWindow.objElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // Preferred path: ask the window server to front this exact window.
        // Fallback: activate the app, then rely on AXRaise below.
        var blnFocused = false
        if let intWindowId = objWindow.intWindowId {
            blnFocused = PrivateWindowAPI.focus(intWindowId: intWindowId, intPid: objApp.processIdentifier)
        }
        if !blnFocused {
            objApp.activate()
        }

        AXUIElementSetAttributeValue(objWindow.objElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(objWindow.objElement, kAXRaiseAction as CFString)
    }

    /// Launches an app, or "reopens" it if running (same as clicking it in the native Dock,
    /// which makes most apps open a new window when they have none).
    /// - Parameter objUrl: Location of the `.app` bundle.
    func open(_ objUrl: URL) {
        let objConfig = NSWorkspace.OpenConfiguration()
        objConfig.activates = true
        NSWorkspace.shared.openApplication(at: objUrl, configuration: objConfig, completionHandler: nil)
    }

    /// Reads a typed AX attribute.
    /// - Parameters:
    ///   - objElement: Element to query.
    ///   - strAttribute: Attribute name, e.g. `kAXTitleAttribute`.
    /// - Returns: The value cast to `T`, or `nil` if missing or of another type.
    private func attribute<T>(_ objElement: AXUIElement, _ strAttribute: String) -> T? {
        var objValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, strAttribute as CFString, &objValue) == .success else { return nil }
        return objValue as? T
    }
}
