import AppKit
import ApplicationServices

/// A single top-level window belonging to an app.
struct WindowInfo: Identifiable {
    let id: Int
    let strTitle: String
    let blnIsMinimized: Bool
    let blnIsOnOtherSpace: Bool
    let intWindowId: CGWindowID?
    /// AX handle; `nil` for windows on other Spaces, which AX can't see.
    let objElement: AXUIElement?
}

/// Lists an app's windows and raises a specific one.
///
/// This is the fix for the native Dock's grouping problem: the Dock activates an
/// *app*, which leaves its current front window in front. Here we raise the exact
/// window the user picked, even when another window of the same app is on top.
@MainActor
final class WindowService {
    /// Smallest size a window must have to count (filters out helper strips and popups).
    private static let fltMinWindowSide: CGFloat = 80

    /// Returns an app's windows: current-Space ones first (front to back, from AX),
    /// then windows on other Spaces (from the window server).
    /// - Parameter objApp: The running application.
    /// - Returns: Its windows, or an empty array without Accessibility permission.
    func windows(for objApp: NSRunningApplication) -> [WindowInfo] {
        guard AccessibilityPermission.blnIsTrusted else { return [] }

        let arrObjCurrentSpace = currentSpaceWindows(for: objApp)
        let setIntKnownIds = Set(arrObjCurrentSpace.compactMap(\.intWindowId))
        let arrObjOtherSpaces = otherSpaceWindows(for: objApp, excluding: setIntKnownIds)

        return arrObjCurrentSpace + arrObjOtherSpaces
    }

    /// Brings one specific window to the front and gives it keyboard focus.
    /// For a window on another Space, macOS switches to that Space.
    /// - Parameters:
    ///   - objWindow: Window to raise.
    ///   - objApp: The app that owns it.
    func raise(_ objWindow: WindowInfo, of objApp: NSRunningApplication) {
        if objApp.isHidden {
            objApp.unhide()
        }

        if objWindow.blnIsMinimized, let objElement = objWindow.objElement {
            AXUIElementSetAttributeValue(objElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
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

        if let objElement = objWindow.objElement {
            axRaise(objElement)
        } else if let intWindowId = objWindow.intWindowId {
            // Other-Space window: once the Space switch settles, AX can see it; raise it then.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                let objMatch = self.currentSpaceWindows(for: objApp).first { $0.intWindowId == intWindowId }
                if let objElement = objMatch?.objElement {
                    self.axRaise(objElement)
                }
            }
        }
    }

    /// Launches an app, or "reopens" it if running (same as clicking it in the native Dock,
    /// which makes most apps open a new window when they have none).
    /// - Parameter objUrl: Location of the `.app` bundle.
    func open(_ objUrl: URL) {
        let objConfig = NSWorkspace.OpenConfiguration()
        objConfig.activates = true
        NSWorkspace.shared.openApplication(at: objUrl, configuration: objConfig, completionHandler: nil)
    }

    // MARK: - Listing

    /// Standard windows on the current Space (including minimized ones), via AX.
    /// - Parameter objApp: The running application.
    /// - Returns: Windows in front-to-back order.
    private func currentSpaceWindows(for objApp: NSRunningApplication) -> [WindowInfo] {
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
                blnIsOnOtherSpace: false,
                intWindowId: intWindowId,
                objElement: objElement
            )
        }
    }

    /// Windows on other Spaces, which AX doesn't report, via the window server list.
    /// Titles need Screen Recording permission; without it a generic label is used.
    /// - Parameters:
    ///   - objApp: The running application.
    ///   - setIntKnownIds: IDs already found on the current Space.
    /// - Returns: Other-Space windows in window-server order.
    private func otherSpaceWindows(for objApp: NSRunningApplication, excluding setIntKnownIds: Set<CGWindowID>) -> [WindowInfo] {
        let objOptions: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let arrDictWindows = CGWindowListCopyWindowInfo(objOptions, kCGNullWindowID) as? [[String: Any]] else { return [] }

        return arrDictWindows.compactMap { dictWindow in
            guard (dictWindow[kCGWindowOwnerPID as String] as? pid_t) == objApp.processIdentifier,
                  (dictWindow[kCGWindowLayer as String] as? Int) == 0,
                  let intRawId = dictWindow[kCGWindowNumber as String] as? Int else { return nil }

            let intWindowId = CGWindowID(intRawId)
            guard !setIntKnownIds.contains(intWindowId) else { return nil }

            // Ignore tiny helper windows.
            let dictBounds = dictWindow[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            guard (dictBounds["Width"] ?? 0) >= Self.fltMinWindowSide,
                  (dictBounds["Height"] ?? 0) >= Self.fltMinWindowSide else { return nil }

            // Must live on some Space; this drops hidden and cached-but-closed windows.
            guard PrivateWindowAPI.isOnAnySpace(intWindowId) == true else { return nil }

            let strTitle = (dictWindow[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(objApp.localizedName ?? "Window") — other desktop"

            return WindowInfo(
                id: Int(intWindowId),
                strTitle: strTitle,
                blnIsMinimized: false,
                blnIsOnOtherSpace: true,
                intWindowId: intWindowId,
                objElement: nil
            )
        }
    }

    // MARK: - AX helpers

    /// Makes an AX window main and raises it within its app.
    /// - Parameter objElement: AX window.
    private func axRaise(_ objElement: AXUIElement) {
        AXUIElementSetAttributeValue(objElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(objElement, kAXRaiseAction as CFString)
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
