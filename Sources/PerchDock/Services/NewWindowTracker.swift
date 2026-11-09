import AppKit
import ApplicationServices
import Observation

/// Notices windows that appear while you're busy elsewhere — e.g. a Chrome
/// window Claude or Cursor just opened — and flags them as "new" until you look.
///
/// Polls the window server list (about a millisecond per poll). Windows that
/// exist at launch count as already seen; a new window is "seen" once the user
/// clicks or types in it, raises it from the dock, or after 10 minutes.
@MainActor
@Observable
final class NewWindowTracker {
    /// How often the window list is checked.
    private static let objPollInterval: Duration = .milliseconds(1500)
    /// How long a window stays "new" if never looked at.
    private static let objMaxAge: Duration = .seconds(600)
    /// Smallest size a window must have to count (skips helper windows).
    private static let fltMinWindowSide: CGFloat = 80

    /// Apps (by PID) that currently have at least one new window.
    private(set) var setIntPidsWithNew: Set<pid_t> = []

    @ObservationIgnored private var setIntKnownIds: Set<CGWindowID> = []
    @ObservationIgnored private var dictObjNew: [CGWindowID: (intPid: pid_t, objSince: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var objPollTask: Task<Void, Never>?
    @ObservationIgnored private var blnHasBaseline = false
    // Set by any click or key press since the last poll.
    @ObservationIgnored private var blnUserActivity = false
    @ObservationIgnored private var objActivityMonitor: Any?

    /// Starts polling.
    func start() {
        guard objPollTask == nil else { return }
        // Windows that grab focus on their own (agents, automation) aren't "seen"
        // until the user actually clicks or types while they're focused.
        objActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.blnUserActivity = true }
        }
        objPollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.objPollInterval)
            }
        }
    }

    /// Whether a window is flagged as new.
    /// - Parameter intWindowId: Window ID.
    /// - Returns: `true` if it appeared recently and hasn't been looked at.
    func isNew(_ intWindowId: CGWindowID?) -> Bool {
        guard let intWindowId else { return false }
        return dictObjNew[intWindowId] != nil
    }

    /// Clears a window's "new" flag (e.g. the user raised it from the dock).
    /// - Parameter intWindowId: Window ID.
    func markSeen(_ intWindowId: CGWindowID?) {
        guard let intWindowId, dictObjNew.removeValue(forKey: intWindowId) != nil else { return }
        publish()
    }

    // MARK: - Polling

    /// Diffs the window list against what's known and expires seen/old windows.
    private func poll() {
        let dictIntPidsById = currentWindows()
        let objNow = ContinuousClock.now

        if blnHasBaseline {
            for (intWindowId, intPid) in dictIntPidsById where !setIntKnownIds.contains(intWindowId) {
                // Only real windows: they live on some Space (drops hidden helpers).
                guard let arrIntSpaces = PrivateWindowAPI.spaces(for: intWindowId), !arrIntSpaces.isEmpty else { continue }
                dictObjNew[intWindowId] = (intPid, objNow)
            }
        }
        setIntKnownIds = Set(dictIntPidsById.keys)
        blnHasBaseline = true

        // Forget windows that closed or got too old.
        dictObjNew = dictObjNew.filter { intWindowId, objEntry in
            dictIntPidsById[intWindowId] != nil && objNow - objEntry.objSince < Self.objMaxAge
        }

        // Clicking or typing in a focused new window means the user has seen it.
        if blnUserActivity, let intFocusedId = focusedWindowId() {
            dictObjNew.removeValue(forKey: intFocusedId)
        }
        blnUserActivity = false

        publish()
    }

    /// Updates the observable per-app summary when it changes.
    private func publish() {
        let setIntPids = Set(dictObjNew.values.map(\.intPid))
        if setIntPids != setIntPidsWithNew {
            setIntPidsWithNew = setIntPids
        }
    }

    /// Normal-layer, reasonably sized windows of regular apps, on any Space.
    /// - Returns: Owner PID per window ID.
    private func currentWindows() -> [CGWindowID: pid_t] {
        guard let arrDictWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let intOwnPid = ProcessInfo.processInfo.processIdentifier

        var dictIntPids: [CGWindowID: pid_t] = [:]
        for dictWindow in arrDictWindows {
            guard (dictWindow[kCGWindowLayer as String] as? Int) == 0,
                  let intRawId = dictWindow[kCGWindowNumber as String] as? Int,
                  let intPid = dictWindow[kCGWindowOwnerPID as String] as? pid_t, intPid != intOwnPid else { continue }
            let dictBounds = dictWindow[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            guard (dictBounds["Width"] ?? 0) >= Self.fltMinWindowSide, (dictBounds["Height"] ?? 0) >= Self.fltMinWindowSide else { continue }
            dictIntPids[CGWindowID(intRawId)] = intPid
        }
        return dictIntPids
    }

    /// The focused window of the frontmost app.
    /// - Returns: Its window ID, or `nil`.
    private func focusedWindowId() -> CGWindowID? {
        guard AXIsProcessTrusted(), let objApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let objAxApp = AXUIElementCreateApplication(objApp.processIdentifier)
        AXUIElementSetMessagingTimeout(objAxApp, 0.2)
        var objValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objAxApp, kAXFocusedWindowAttribute as CFString, &objValue) == .success,
              let objValue, CFGetTypeID(objValue) == AXUIElementGetTypeID() else { return nil }
        return PrivateWindowAPI.windowId(for: objValue as! AXUIElement)
    }
}
