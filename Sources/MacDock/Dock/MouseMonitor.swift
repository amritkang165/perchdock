import AppKit

/// Reports the cursor position on every move, system-wide.
///
/// The dock needs this for two things a tracking area can't do: noticing the
/// cursor at the screen edge while the dock is hidden, and letting clicks pass
/// through the panel's transparent margins (the panel ignores mouse events
/// until the cursor is actually over the bar).
@MainActor
final class MouseMonitor {
    private var objGlobalMonitor: Any?
    private var objLocalMonitor: Any?

    /// Called with the cursor's screen location (bottom-left origin).
    var onMove: ((CGPoint) -> Void)?

    /// Starts listening. Global monitors see events sent to other apps; the local
    /// monitor covers events delivered to MacDock's own panels.
    func start() {
        let objMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        objGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: objMask) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
        }
        objLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: objMask) { [weak self] objEvent in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
            return objEvent
        }
    }

    /// Stops listening (e.g. when a display's dock is removed).
    func stop() {
        if let objGlobalMonitor { NSEvent.removeMonitor(objGlobalMonitor) }
        if let objLocalMonitor { NSEvent.removeMonitor(objLocalMonitor) }
        objGlobalMonitor = nil
        objLocalMonitor = nil
    }
}
