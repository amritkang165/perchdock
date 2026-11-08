import AppKit
import ApplicationServices

/// Keeps windows out from under the dock while it's always shown, like the space
/// macOS reserves for its own Dock.
///
/// Apps can't change the screen's `visibleFrame`, so instead this watches the
/// frontmost app's windows: when one is created, zoomed or resized so that it
/// reaches into the dock's strip, it's trimmed to stop at the dock. Moving a window
/// under the dock is left alone (that's deliberate).
@MainActor
final class DockSpaceKeeper {
    /// Where the dock sits and must stay clear, or `nil` when nothing is reserved
    /// (auto-hide on). The rect is the dock's strip in AppKit screen coordinates.
    var fnReservedStrip: (() -> (objScreen: NSScreen, enmPosition: DockPosition, objStrip: CGRect)?)?

    /// Gap left between a trimmed window and the dock.
    private static let fltMargin: CGFloat = 4
    /// Windows that only poke into the strip by less than this are left alone.
    private static let fltMinOverlap: CGFloat = 2
    /// Wait after the last change before fitting (zoom animations resize in steps).
    private static let objSettleDelay: Duration = .milliseconds(250)

    private var objObserver: AXObserver?
    private var intObservedPid: pid_t = 0
    private var objActivationObserver: NSObjectProtocol?
    private var arrObjPending: [AXUIElement] = []
    private var objFitTask: Task<Void, Never>?

    /// Starts following the frontmost app.
    func start() {
        objActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] objNote in
            let objApp = objNote.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.observe(objApp) }
        }
        observe(NSWorkspace.shared.frontmostApplication)
    }

    /// The part of a screen windows may use: its visible frame minus the dock's strip.
    /// - Parameter objScreen: Screen.
    /// - Returns: Usable frame in AppKit coordinates.
    func usableFrame(of objScreen: NSScreen) -> CGRect {
        var objFrame = objScreen.visibleFrame
        guard let objReserved = fnReservedStrip?(), objReserved.objScreen == objScreen else { return objFrame }
        let objStrip = objReserved.objStrip
        switch objReserved.enmPosition {
        case .bottom:
            let fltEdge = max(objFrame.minY, objStrip.maxY + Self.fltMargin)
            objFrame = CGRect(x: objFrame.minX, y: fltEdge, width: objFrame.width, height: objFrame.maxY - fltEdge)
        case .left:
            let fltEdge = max(objFrame.minX, objStrip.maxX + Self.fltMargin)
            objFrame = CGRect(x: fltEdge, y: objFrame.minY, width: objFrame.maxX - fltEdge, height: objFrame.height)
        case .right:
            let fltEdge = min(objFrame.maxX, objStrip.minX - Self.fltMargin)
            objFrame = CGRect(x: objFrame.minX, y: objFrame.minY, width: fltEdge - objFrame.minX, height: objFrame.height)
        }
        return objFrame
    }

    // MARK: - Observation

    /// Swaps the AX observer over to a newly active app.
    /// - Parameter objApp: The app that became frontmost.
    private func observe(_ objApp: NSRunningApplication?) {
        guard let objApp, objApp.processIdentifier != intObservedPid,
              objApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        stopObserving()

        let intPid = objApp.processIdentifier
        var objNewObserver: AXObserver?
        guard AXObserverCreate(intPid, Self.fnCallback, &objNewObserver) == .success, let objNewObserver else { return }

        let objAppElement = AXUIElementCreateApplication(intPid)
        let pRefcon = Unmanaged.passUnretained(self).toOpaque()
        for strNotification in [kAXWindowCreatedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(objNewObserver, objAppElement, strNotification as CFString, pRefcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(objNewObserver), .defaultMode)
        objObserver = objNewObserver
        intObservedPid = intPid
    }

    /// Detaches the current AX observer.
    private func stopObserving() {
        if let objObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(objObserver), .defaultMode)
        }
        objObserver = nil
        intObservedPid = 0
        arrObjPending.removeAll()
        objFitTask?.cancel()
    }

    /// AX callback (runs on the main run loop): queues the window for fitting.
    private static let fnCallback: AXObserverCallback = { _, objElement, _, pRefcon in
        guard let pRefcon else { return }
        let objKeeper = Unmanaged<DockSpaceKeeper>.fromOpaque(pRefcon).takeUnretainedValue()
        // The observer's source is on the main run loop, so this already runs on the main thread.
        nonisolated(unsafe) let objWindow = objElement
        MainActor.assumeIsolated { objKeeper.windowChanged(objWindow) }
    }

    /// Debounces changes, then fits the affected windows once they settle.
    /// - Parameter objElement: The window that was created or resized.
    private func windowChanged(_ objElement: AXUIElement) {
        guard fnReservedStrip?() != nil else { return }
        if !arrObjPending.contains(where: { CFEqual($0, objElement) }) {
            arrObjPending.append(objElement)
        }
        objFitTask?.cancel()
        objFitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objSettleDelay)
            // Still dragging a window edge: wait for the release.
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self else { return }
            let arrObjWindows = self.arrObjPending
            self.arrObjPending.removeAll()
            arrObjWindows.forEach { self.fit($0) }
        }
    }

    // MARK: - Fitting

    /// Trims a standard window so it stops at the dock, if it reaches into the strip.
    /// - Parameter objElement: AX window.
    private func fit(_ objElement: AXUIElement) {
        guard let objReserved = fnReservedStrip?(),
              stringAttribute(objElement, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              let objAXFrame = axFrame(of: objElement) else { return }

        // AX frames use a top-left origin at the primary display's top.
        let fltPrimaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let objFrame = CGRect(x: objAXFrame.minX, y: fltPrimaryHeight - objAXFrame.maxY,
                              width: objAXFrame.width, height: objAXFrame.height)
        let objStrip = objReserved.objStrip
        guard objFrame.intersects(objStrip),
              objReserved.objScreen.frame.contains(CGPoint(x: objFrame.midX, y: objFrame.midY)) else { return }

        let objUsable = usableFrame(of: objReserved.objScreen)
        var objTarget = objFrame
        switch objReserved.enmPosition {
        case .bottom:
            guard objUsable.minY - objFrame.minY > Self.fltMinOverlap else { return }
            objTarget.origin.y = objUsable.minY
            objTarget.size.height = objFrame.maxY - objUsable.minY
        case .left:
            guard objUsable.minX - objFrame.minX > Self.fltMinOverlap else { return }
            objTarget.origin.x = objUsable.minX
            objTarget.size.width = objFrame.maxX - objUsable.minX
        case .right:
            guard objFrame.maxX - objUsable.maxX > Self.fltMinOverlap else { return }
            objTarget.size.width = objUsable.maxX - objFrame.minX
        }
        // Too little left to be useful (a narrow window parked by the dock): leave it.
        guard objTarget.width >= 200, objTarget.height >= 150 else { return }

        // Size first so the move isn't clamped, then position, then size again.
        var objPosition = CGPoint(x: objTarget.minX, y: fltPrimaryHeight - objTarget.maxY)
        var objSize = objTarget.size
        guard let objSizeValue = AXValueCreate(.cgSize, &objSize),
              let objPositionValue = AXValueCreate(.cgPoint, &objPosition) else { return }
        AXUIElementSetAttributeValue(objElement, kAXSizeAttribute as CFString, objSizeValue)
        AXUIElementSetAttributeValue(objElement, kAXPositionAttribute as CFString, objPositionValue)
        AXUIElementSetAttributeValue(objElement, kAXSizeAttribute as CFString, objSizeValue)
    }

    /// Reads a string attribute.
    /// - Parameters:
    ///   - objElement: AX element.
    ///   - strAttribute: Attribute name.
    /// - Returns: The value, if it's a string.
    private func stringAttribute(_ objElement: AXUIElement, _ strAttribute: String) -> String? {
        var objValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, strAttribute as CFString, &objValue) == .success else { return nil }
        return objValue as? String
    }

    /// A window's frame in AX coordinates (top-left origin).
    /// - Parameter objElement: AX window.
    /// - Returns: Frame, or `nil` if unreadable.
    private func axFrame(of objElement: AXUIElement) -> CGRect? {
        var objPositionRef: CFTypeRef?
        var objSizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, kAXPositionAttribute as CFString, &objPositionRef) == .success,
              AXUIElementCopyAttributeValue(objElement, kAXSizeAttribute as CFString, &objSizeRef) == .success,
              let objPositionRef, let objSizeRef else { return nil }
        var objPoint = CGPoint.zero
        var objDimensions = CGSize.zero
        AXValueGetValue(objPositionRef as! AXValue, .cgPoint, &objPoint)
        AXValueGetValue(objSizeRef as! AXValue, .cgSize, &objDimensions)
        return CGRect(origin: objPoint, size: objDimensions)
    }
}
