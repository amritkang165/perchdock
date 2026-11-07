import AppKit
import ApplicationServices
import os

/// Window-discovery diagnostics: `log stream --predicate 'subsystem == "com.slynck.macdock"'`.
private let objLogger = Logger(subsystem: "com.slynck.macdock", category: "windows")

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
        guard AccessibilityPermission.blnIsTrusted else {
            objLogger.debug("Not trusted for Accessibility; no windows listed")
            return []
        }

        var setIntSeenByAX = Set<CGWindowID>()
        let arrObjCurrentSpace = currentSpaceWindows(for: objApp, setIntSeenIds: &setIntSeenByAX)
        // Anything AX reported (even popups we filtered out) is on this Space, not another.
        let arrObjOtherSpaces = otherSpaceWindows(for: objApp, excluding: setIntSeenByAX)

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
                var setIntIgnored = Set<CGWindowID>()
                let objMatch = self.currentSpaceWindows(for: objApp, setIntSeenIds: &setIntIgnored)
                    .first { $0.intWindowId == intWindowId }
                if let objElement = objMatch?.objElement {
                    self.axRaise(objElement)
                }
            }
        }
    }

    /// Closes a window by pressing its close button, exactly as a user click would
    /// (so apps still get to ask "save changes?").
    /// - Parameter objWindow: Window to close; ignored if it has no AX handle.
    func close(_ objWindow: WindowInfo) {
        guard let objElement = objWindow.objElement,
              let objCloseButton: AXUIElement = attribute(objElement, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(objCloseButton, kAXPressAction as CFString)
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
    /// - Parameters:
    ///   - objApp: The running application.
    ///   - setIntSeenIds: Receives the IDs of every AX window, including filtered-out popups.
    /// - Returns: Windows in front-to-back order.
    private func currentSpaceWindows(for objApp: NSRunningApplication, setIntSeenIds: inout Set<CGWindowID>) -> [WindowInfo] {
        let objAxApp = AXUIElementCreateApplication(objApp.processIdentifier)
        // Keep a hung app from stalling the dock.
        AXUIElementSetMessagingTimeout(objAxApp, 0.5)

        var objRawValue: CFTypeRef?
        let objError = AXUIElementCopyAttributeValue(objAxApp, kAXWindowsAttribute as CFString, &objRawValue)
        guard objError == .success, let arrObjElements = objRawValue as? [AXUIElement] else {
            objLogger.debug("\(objApp.localizedName ?? "?", privacy: .public): AXWindows failed (\(objError.rawValue))")
            return []
        }

        var arrObjResult: [WindowInfo] = []
        for objElement in arrObjElements {
            let strSubrole: String? = attribute(objElement, kAXSubroleAttribute)
            let strTitle: String = attribute(objElement, kAXTitleAttribute) ?? ""
            let blnMinimized: Bool = attribute(objElement, kAXMinimizedAttribute) ?? false
            let intWindowId = PrivateWindowAPI.windowId(for: objElement)
            if let intWindowId {
                setIntSeenIds.insert(intWindowId)
            }

            objLogger.debug("\(objApp.localizedName ?? "?", privacy: .public) AX window id=\(intWindowId ?? 0) subrole=\(strSubrole ?? "nil", privacy: .public) min=\(blnMinimized) title=\(strTitle, privacy: .public)")

            // Skip sheets, panels, popovers and other non-document windows.
            guard strSubrole == kAXStandardWindowSubrole else { continue }

            arrObjResult.append(WindowInfo(
                id: intWindowId.map(Int.init) ?? Int(bitPattern: CFHash(objElement)),
                strTitle: strTitle.isEmpty ? (objApp.localizedName ?? "Untitled") : strTitle,
                blnIsMinimized: blnMinimized,
                blnIsOnOtherSpace: false,
                intWindowId: intWindowId,
                objElement: objElement
            ))
        }
        return arrObjResult
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
        let intActiveSpace = PrivateWindowAPI.activeSpace()

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

            // Must live on some Space (drops hidden and cached-but-closed windows),
            // and not the visible one (AX already covers that Space).
            let arrIntSpaces = PrivateWindowAPI.spaces(for: intWindowId) ?? []
            objLogger.debug("\(objApp.localizedName ?? "?", privacy: .public) CG candidate id=\(intWindowId) spaces=\(arrIntSpaces, privacy: .public)")
            guard !arrIntSpaces.isEmpty else { return nil }
            if let intActiveSpace, arrIntSpaces.contains(intActiveSpace) { return nil }

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
