import AppKit
import ApplicationServices
import os

/// Brings a window from another desktop onto the current one.
///
/// Recent macOS releases block moving other apps' windows between Spaces
/// directly, so this does what a person would: go to the window's desktop,
/// hold its title bar, and press Control-Arrow back to the original desktop —
/// macOS carries a held window along. The cursor is put back afterwards.
@MainActor
enum WindowMover {
    private static let objLogger = Logger(subsystem: "com.slynck.perchdock", category: "move")

    /// Left / Right arrow key codes (Control-Arrow switches desktops).
    private static let intKeyLeft: CGKeyCode = 123
    private static let intKeyRight: CGKeyCode = 124

    /// Time for one desktop-switch animation to finish.
    private static let objSwitchSettle: Duration = .milliseconds(450)

    /// Moves a window to the current desktop.
    /// - Parameters:
    ///   - objWindow: Window on another desktop.
    ///   - objApp: Its app.
    ///   - objWindowService: Used to raise the window.
    /// - Returns: `true` if the window ended up on the current desktop.
    static func bringHere(_ objWindow: WindowInfo, of objApp: NSRunningApplication, objWindowService: WindowService) async -> Bool {
        guard let intWindowId = objWindow.intWindowId,
              let intHome = PrivateWindowAPI.activeSpace(),
              let intTarget = PrivateWindowAPI.spaces(for: intWindowId)?.first, intTarget != intHome else { return false }

        // Both desktops must be on the same display for Control-Arrow to walk between them.
        guard let arrIntOrder = PrivateWindowAPI.spaceOrder().first(where: { $0.contains(intHome) && $0.contains(intTarget) }),
              let intHomeIndex = arrIntOrder.firstIndex(of: intHome),
              let intTargetIndex = arrIntOrder.firstIndex(of: intTarget) else {
            objLogger.notice("Desktops are on different displays; switching instead")
            objWindowService.raise(objWindow, of: objApp)
            return false
        }

        let objSavedCursor = CGEvent(source: nil)?.location ?? .zero

        // 1. Go to the window's desktop and bring it to the front there.
        guard await switchDesktop(to: intTarget) else {
            objLogger.notice("Didn't reach the window's desktop")
            return false
        }
        let objHere = objWindowService.windows(for: objApp).first(where: { $0.intWindowId == intWindowId }) ?? objWindow
        objWindowService.raise(objHere, of: objApp)
        try? await Task.sleep(for: .milliseconds(150))

        // 2. Find a safe spot on its title bar (not a tab or button).
        guard let objElement = PrivateWindowAPI.axElement(forWindowId: intWindowId, intPid: objApp.processIdentifier)
                ?? objWindowService.windows(for: objApp).first(where: { $0.intWindowId == intWindowId })?.objElement,
              let objGrab = grabPoint(of: objElement, intPid: objApp.processIdentifier) else {
            objLogger.notice("No title bar spot to hold")
            return false
        }

        // 3. Hold the title bar, ride Control-Arrow back home, let go.
        let intSteps = intHomeIndex - intTargetIndex
        let objShortcut = spaceShortcut(blnRight: intSteps > 0)
        let objFrameBefore = frame(of: objElement)
        postMouse(.mouseMoved, at: objGrab)
        try? await Task.sleep(for: .milliseconds(40))
        postMouse(.leftMouseDown, at: objGrab)
        try? await Task.sleep(for: .milliseconds(60))
        // A few small drags so the window server treats it as a window move.
        var objCurrent = objGrab
        for _ in 0..<6 {
            objCurrent.x += 2
            postMouse(.leftMouseDragged, at: objCurrent)
            try? await Task.sleep(for: .milliseconds(16))
        }
        // If the window isn't following the cursor, the hold didn't take: let go
        // and stay here with the window in front rather than leaving without it.
        guard frame(of: objElement) != objFrameBefore else {
            postMouse(.leftMouseUp, at: objCurrent)
            CGWarpMouseCursorPosition(objSavedCursor)
            objLogger.notice("Window didn't follow the hold; staying on its desktop")
            return false
        }
        for _ in 0..<abs(intSteps) {
            postKey(objShortcut.intKey, objFlags: objShortcut.objFlags)
            try? await Task.sleep(for: objSwitchSettle)
        }
        // Keep the drag alive on arrival, then let go.
        for _ in 0..<3 {
            objCurrent.x -= 2
            postMouse(.leftMouseDragged, at: objCurrent)
            try? await Task.sleep(for: .milliseconds(16))
        }
        postMouse(.leftMouseUp, at: objCurrent)
        try? await Task.sleep(for: .milliseconds(60))
        CGWarpMouseCursorPosition(objSavedCursor)

        let blnMoved = PrivateWindowAPI.spaces(for: intWindowId)?.contains(intHome) ?? false
        objLogger.notice("Bring here \(intWindowId): \(blnMoved ? "moved" : "failed", privacy: .public)")
        return blnMoved
    }

    /// Switches to another desktop on the same display by pressing Control-Arrow
    /// the right number of times (the "Move left/right a space" shortcuts, on by
    /// default).
    /// - Parameter intSpace: Destination Space ID.
    /// - Returns: `true` once it's showing.
    static func switchDesktop(to intSpace: UInt64) async -> Bool {
        guard let intHome = PrivateWindowAPI.activeSpace() else { return false }
        if intHome == intSpace { return true }
        guard let arrIntOrder = PrivateWindowAPI.spaceOrder().first(where: { $0.contains(intHome) && $0.contains(intSpace) }),
              let intHomeIndex = arrIntOrder.firstIndex(of: intHome),
              let intTargetIndex = arrIntOrder.firstIndex(of: intSpace) else { return false }

        let intSteps = intTargetIndex - intHomeIndex
        let objShortcut = spaceShortcut(blnRight: intSteps > 0)
        for _ in 0..<abs(intSteps) {
            postKey(objShortcut.intKey, objFlags: objShortcut.objFlags)
            try? await Task.sleep(for: .milliseconds(60))
        }
        let blnArrived = await waitForActiveSpace(intSpace)
        // Let the slide animation finish before acting on windows there.
        if blnArrived {
            try? await Task.sleep(for: objSwitchSettle)
        } else {
            objLogger.notice("Control-Arrow didn't reach the desktop (shortcut disabled?)")
        }
        return blnArrived
    }

    /// Waits until a Space is showing.
    /// - Parameter intSpace: Space ID.
    /// - Returns: `true` if it became active within 1.5 s.
    private static func waitForActiveSpace(_ intSpace: UInt64) async -> Bool {
        let objDeadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < objDeadline {
            if PrivateWindowAPI.activeSpace() == intSpace { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// A point on the window's top strip that belongs to the window itself (not a
    /// tab, button or text field), scanning from the middle outwards.
    /// - Parameters:
    ///   - objElement: Window's AX element.
    ///   - intPid: Owning process.
    /// - Returns: Point in global display coordinates (top-left origin), or `nil`.
    private static func grabPoint(of objElement: AXUIElement, intPid: pid_t) -> CGPoint? {
        guard let objFrame = frame(of: objElement) else { return nil }
        let objAxApp = AXUIElementCreateApplication(intPid)
        let setStrBlockedRoles: Set<String> = ["AXButton", "AXRadioButton", "AXTextField", "AXPopUpButton", "AXMenuButton",
                                               "AXCheckBox", "AXTab", "AXLink", "AXComboBox", "AXSearchField"]
        // Row of the traffic-light buttons: always title bar.
        var fltY = objFrame.minY + 10
        var arrFltCandidates: [CGFloat] = []
        var objZoomButton: CFTypeRef?
        if AXUIElementCopyAttributeValue(objElement, kAXZoomButtonAttribute as CFString, &objZoomButton) == .success,
           let objZoomButton, let objButtonFrame = frame(of: objZoomButton as! AXUIElement) {
            fltY = objButtonFrame.midY
            // Just right of the green button is title bar in nearly every app.
            arrFltCandidates += [objButtonFrame.maxX + 14, objButtonFrame.maxX + 30]
        }

        // Then middle, alternating right/left (tab strips grow from the left).
        arrFltCandidates.append(objFrame.midX)
        for intStep in 1...20 {
            arrFltCandidates += [objFrame.midX + objFrame.width * CGFloat(intStep) * 0.022,
                                 objFrame.midX - objFrame.width * CGFloat(intStep) * 0.022]
        }
        for fltX in arrFltCandidates {
            guard fltX > objFrame.minX + 60, fltX < objFrame.maxX - 20 else { continue }
            var objHit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(objAxApp, Float(fltX), Float(fltY), &objHit) == .success, let objHit else { continue }
            var objRole: CFTypeRef?
            AXUIElementCopyAttributeValue(objHit, kAXRoleAttribute as CFString, &objRole)
            if !setStrBlockedRoles.contains(objRole as? String ?? "") {
                return CGPoint(x: fltX, y: fltY)
            }
        }
        return nil
    }

    /// Window frame in global display coordinates (top-left origin).
    /// - Parameter objElement: Window's AX element.
    /// - Returns: Frame, or `nil`.
    private static func frame(of objElement: AXUIElement) -> CGRect? {
        var objPosition: CFTypeRef?
        var objSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, kAXPositionAttribute as CFString, &objPosition) == .success,
              AXUIElementCopyAttributeValue(objElement, kAXSizeAttribute as CFString, &objSize) == .success,
              let objPosition, let objSize else { return nil }
        var objPoint = CGPoint.zero
        var objDimensions = CGSize.zero
        // AX returns these as AXValue wrappers.
        AXValueGetValue(objPosition as! AXValue, .cgPoint, &objPoint)
        AXValueGetValue(objSize as! AXValue, .cgSize, &objDimensions)
        return CGRect(origin: objPoint, size: objDimensions)
    }

    /// Posts a mouse event at a point.
    /// - Parameters:
    ///   - enmType: Event type.
    ///   - objPoint: Global display coordinates.
    private static func postMouse(_ enmType: CGEventType, at objPoint: CGPoint) {
        let objEvent = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: enmType,
                               mouseCursorPosition: objPoint, mouseButton: .left)
        // Real presses carry a click count; some apps ignore drags without it.
        if enmType != .mouseMoved {
            objEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        objEvent?.post(tap: .cghidEventTap)
    }

    /// Symbolic hotkey IDs for "Move left a space" / "Move right a space".
    private static let intHotkeyLeft = 79
    private static let intHotkeyRight = 81

    /// The user's "Move left/right a space" shortcut. The window server only fires
    /// it when key and modifier flags match the setting exactly.
    /// - Parameter blnRight: Right instead of left.
    /// - Returns: Key code and flags (default Control-Arrow with Fn).
    private static func spaceShortcut(blnRight: Bool) -> (intKey: CGKeyCode, objFlags: CGEventFlags) {
        let objDefault: (CGKeyCode, CGEventFlags) = (blnRight ? intKeyRight : intKeyLeft, [.maskControl, .maskSecondaryFn])
        let strId = String(blnRight ? intHotkeyRight : intHotkeyLeft)
        guard let dictHotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let dictEntry = dictHotkeys[strId] as? [String: Any],
              (dictEntry["enabled"] as? Bool) != false,
              let dictValue = dictEntry["value"] as? [String: Any],
              let arrIntParams = dictValue["parameters"] as? [Int], arrIntParams.count == 3 else { return objDefault }
        // parameters = [character, key code, modifier flags]
        return (CGKeyCode(arrIntParams[1]), CGEventFlags(rawValue: UInt64(arrIntParams[2])))
    }

    /// Posts a key press (down and up).
    /// - Parameters:
    ///   - intKey: Virtual key code.
    ///   - objFlags: Modifier flags.
    private static func postKey(_ intKey: CGKeyCode, objFlags: CGEventFlags) {
        let objSource = CGEventSource(stateID: .hidSystemState)
        for blnDown in [true, false] {
            let objEvent = CGEvent(keyboardEventSource: objSource, virtualKey: intKey, keyDown: blnDown)
            objEvent?.flags = objFlags
            objEvent?.post(tap: .cghidEventTap)
        }
    }
}
