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
    /// "Desktop 2", "Full Screen", etc.; `nil` when minimized or unknown.
    var strDesktopLabel: String? = nil
    /// Appeared recently and hasn't been looked at yet.
    var blnIsNew = false
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

    /// Fired after a window is raised (used to clear its "new" flag).
    var onRaised: ((CGWindowID) -> Void)?

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

        return labelDesktops(arrObjCurrentSpace + arrObjOtherSpaces)
    }

    /// Tags each window with the desktop it's on. Labels are only added when the
    /// user has more than one Space, since "Desktop 1" everywhere is just noise.
    /// - Parameter arrObjWindows: Windows to tag.
    /// - Returns: The same windows with `strDesktopLabel` filled in where known.
    private func labelDesktops(_ arrObjWindows: [WindowInfo]) -> [WindowInfo] {
        let dictStrLabels = PrivateWindowAPI.desktopLabels()
        guard dictStrLabels.count > 1 else { return arrObjWindows }

        return arrObjWindows.map { objWindow in
            guard !objWindow.blnIsMinimized, let intWindowId = objWindow.intWindowId,
                  let intSpaceId = PrivateWindowAPI.spaces(for: intWindowId)?.first else { return objWindow }
            var objTagged = objWindow
            objTagged.strDesktopLabel = dictStrLabels[intSpaceId]
            return objTagged
        }
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
        if let intWindowId = objWindow.intWindowId {
            onRaised?(intWindowId)
        }

        if objWindow.blnIsMinimized, let objElement = objWindow.objElement {
            AXUIElementSetAttributeValue(objElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // Other-Space windows have no AX handle from the window list; recover it so
        // AXRaise can pull macOS over to that Space (activation alone won't when the
        // app is already frontmost).
        var objElement = objWindow.objElement
        if objElement == nil, let intWindowId = objWindow.intWindowId {
            objElement = PrivateWindowAPI.axElement(forWindowId: intWindowId, intPid: objApp.processIdentifier)
            objLogger.debug("Other-Space window \(intWindowId): AX element \(objElement == nil ? "not found" : "found", privacy: .public)")
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

        if let objElement {
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
        guard let objElement = axElement(for: objWindow),
              let objCloseButton: AXUIElement = attribute(objElement, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(objCloseButton, kAXPressAction as CFString)
    }

    // MARK: - Tabs

    /// One tab in a window's tab bar.
    struct TabInfo {
        let strTitle: String
        let blnIsSelected: Bool
        let objElement: AXUIElement
    }

    /// How deep to search a window's AX tree for its tab bar.
    private static let intMaxTabSearchDepth = 9

    /// Tabs of a window (Chrome, Safari, Terminal, Finder…), front tab marked.
    /// - Parameter objWindow: Window with an AX handle.
    /// - Returns: Tabs in bar order; empty when the window has no tab bar.
    func tabs(in objWindow: WindowInfo) -> [TabInfo] {
        guard let objElement = axElement(for: objWindow),
              let objTabGroup = findDescendant(of: objElement, intDepth: Self.intMaxTabSearchDepth, where: { objCandidate in
                  let strRole: String? = self.attribute(objCandidate, kAXRoleAttribute)
                  return strRole == kAXTabGroupRole
              }) else { return [] }

        // Chrome nests its tabs (subrole AXTabButton) deep inside scroll areas;
        // Safari, Terminal and Finder put radio buttons directly in the group.
        var arrObjTabButtons: [AXUIElement] = []
        collectDescendants(of: objTabGroup, intDepth: 8, into: &arrObjTabButtons) { objCandidate in
            let strRole: String? = self.attribute(objCandidate, kAXRoleAttribute)
            return strRole == kAXRadioButtonRole
        }

        let arrObjTabs = arrObjTabButtons.map { objButton in
            var strTitle: String = attribute(objButton, kAXTitleAttribute) ?? attribute(objButton, kAXDescriptionAttribute) ?? ""
            // Chrome appends hover-card details ("- Memory usage - 40 MB", "- Part of group …").
            for strSuffix in [" - Memory usage", " - Part of group"] {
                if let objRange = strTitle.range(of: strSuffix) {
                    strTitle = String(strTitle[..<objRange.lowerBound])
                }
            }
            let intValue: Int = attribute(objButton, kAXValueAttribute) ?? 0
            return TabInfo(strTitle: strTitle, blnIsSelected: intValue == 1, objElement: objButton)
        }

        // Segmented controls (e.g. Calendar's Day/Week/Month) are tab groups too;
        // real tabs carry their own close button (pinned tabs don't, so check them all).
        guard arrObjTabs.contains(where: { closeButton(inTab: $0.objElement) != nil }) else { return [] }
        return arrObjTabs
    }

    /// A tab's own close button.
    /// - Parameter objTab: Tab element.
    /// - Returns: The button, or `nil` if the tab has none.
    private func closeButton(inTab objTab: AXUIElement) -> AXUIElement? {
        findDescendant(of: objTab, intDepth: 3) { objCandidate in
            let strRole: String? = self.attribute(objCandidate, kAXRoleAttribute)
            let strSubrole: String? = self.attribute(objCandidate, kAXSubroleAttribute)
            let strDescription: String = self.attribute(objCandidate, kAXDescriptionAttribute) ?? self.attribute(objCandidate, kAXTitleAttribute) ?? ""
            return strRole == kAXButtonRole && (strSubrole == kAXCloseButtonSubrole || strDescription.localizedCaseInsensitiveContains("close"))
        }
    }

    /// Collects every matching element in an AX subtree (not descending into matches).
    /// - Parameters:
    ///   - objRoot: Where to start.
    ///   - intDepth: Levels below the root to search.
    ///   - arrObjResult: Receives matches in tree order.
    ///   - fnMatch: Predicate.
    private func collectDescendants(of objRoot: AXUIElement, intDepth: Int, into arrObjResult: inout [AXUIElement], where fnMatch: (AXUIElement) -> Bool) {
        guard intDepth > 0 else { return }
        let arrObjChildren: [AXUIElement] = attribute(objRoot, kAXChildrenAttribute) ?? []
        for objChild in arrObjChildren {
            if fnMatch(objChild) {
                arrObjResult.append(objChild)
            } else {
                collectDescendants(of: objChild, intDepth: intDepth - 1, into: &arrObjResult, where: fnMatch)
            }
        }
    }

    /// Closes a window's front tab: presses that tab's own close button when it
    /// exposes one, otherwise brings the window forward and sends ⌘W.
    /// - Parameters:
    ///   - objWindow: Window whose front tab to close.
    ///   - objApp: Owning app.
    func closeFrontTab(of objWindow: WindowInfo, in objApp: NSRunningApplication) {
        if let objTab = tabs(in: objWindow).first(where: \.blnIsSelected),
           let objCloseButton = closeButton(inTab: objTab.objElement) {
            AXUIElementPerformAction(objCloseButton, kAXPressAction as CFString)
            return
        }

        // Fallback: ⌘W goes to the key window, so make this one key first.
        raise(objWindow, of: objApp)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let objSource = CGEventSource(stateID: .hidSystemState)
            let intKeyW: CGKeyCode = 13
            for blnDown in [true, false] {
                let objEvent = CGEvent(keyboardEventSource: objSource, virtualKey: intKeyW, keyDown: blnDown)
                objEvent?.flags = .maskCommand
                objEvent?.postToPid(objApp.processIdentifier)
            }
        }
    }

    /// A window's AX handle, recovering it for other-desktop windows.
    /// - Parameter objWindow: Window.
    /// - Returns: AX element, or `nil` if it can't be found.
    private func axElement(for objWindow: WindowInfo) -> AXUIElement? {
        if let objElement = objWindow.objElement {
            return objElement
        }
        guard let intWindowId = objWindow.intWindowId, let intPid = pid(ofWindow: intWindowId) else { return nil }
        return PrivateWindowAPI.axElement(forWindowId: intWindowId, intPid: intPid)
    }

    /// Owning process of a window, from the window server.
    /// - Parameter intWindowId: Window ID.
    /// - Returns: PID, or `nil` if the window is gone.
    private func pid(ofWindow intWindowId: CGWindowID) -> pid_t? {
        let arrDictInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], intWindowId) as? [[String: Any]]
        return arrDictInfo?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    /// Depth-first search of an AX subtree.
    /// - Parameters:
    ///   - objRoot: Where to start (not itself tested).
    ///   - intDepth: Levels below the root to search.
    ///   - fnMatch: Predicate.
    /// - Returns: The first matching descendant.
    private func findDescendant(of objRoot: AXUIElement, intDepth: Int, where fnMatch: (AXUIElement) -> Bool) -> AXUIElement? {
        guard intDepth > 0 else { return nil }
        let arrObjChildren: [AXUIElement] = attribute(objRoot, kAXChildrenAttribute) ?? []
        for objChild in arrObjChildren {
            if fnMatch(objChild) {
                return objChild
            }
            if let objFound = findDescendant(of: objChild, intDepth: intDepth - 1, where: fnMatch) {
                return objFound
            }
        }
        return nil
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
                ?? (objApp.localizedName ?? "Window")

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
