import AppKit

/// Owns the dock panel and turns hover and clicks into actions.
///
/// Click behavior:
/// - app not running → launch it
/// - running, no windows → reopen (most apps open a new window)
/// - one window → raise it
/// - several windows → show the picker so you choose the exact window
///
/// Hovering an icon for a moment also shows the picker (Windows-taskbar style).
@MainActor
final class DockController {
    private static let objHoverShowDelay: Duration = .milliseconds(320)
    private static let objHoverHideDelay: Duration = .milliseconds(220)

    private let objTracker: AppTracker
    private let objWindowService: WindowService
    private let objState = DockState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<DockView>
    private let objPicker: WindowPickerController

    private var objShowPickerTask: Task<Void, Never>?
    private var objHidePickerTask: Task<Void, Never>?
    private var objOutsideClickMonitor: Any?
    private var objScreenObserver: NSObjectProtocol?

    /// Wires the panel, picker and app tracker together.
    /// - Parameters:
    ///   - objTracker: Source of dock items.
    ///   - objWindowService: Window listing and raising.
    ///   - objThumbnailService: Window thumbnails for the picker.
    init(objTracker: AppTracker, objWindowService: WindowService, objThumbnailService: ThumbnailService) {
        self.objTracker = objTracker
        self.objWindowService = objWindowService
        objPicker = WindowPickerController(objThumbnailService: objThumbnailService)

        objPanel = DockPanel(contentRect: .zero)
        objHostingView = TrackingHostingView(rootView: DockView(objTracker: objTracker, objState: objState))
        objPanel.contentView = objHostingView

        objHostingView.onMouseMoved = { [weak self] objPoint in
            self?.handleDockHover(objPoint)
        }
        objHostingView.onMouseUp = { [weak self] objPoint in
            self?.handleDockClick(objPoint)
        }

        objPicker.onMouseInsideChanged = { [weak self] blnInside in
            self?.handlePickerHover(blnInside)
        }
        objPicker.onSelectWindow = { [weak self] objWindow in
            self?.handlePickerSelection(objWindow)
        }
        objPicker.onCloseWindow = { [weak self] objWindow in
            self?.handlePickerClose(objWindow)
        }

        objTracker.onItemsChanged = { [weak self] in
            self?.layoutPanel(blnAnimated: true)
        }

        // Re-center when displays are added, removed or rearranged.
        objScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel(blnAnimated: false) }
        }
    }

    /// Positions and shows the dock.
    func show() {
        layoutPanel(blnAnimated: false)
        objPanel.orderFrontRegardless()
    }

    /// Debug aid: rapidly switches the picker across every running app, the
    /// situation that exposes stale-index bugs when window counts differ.
    /// - Parameter intRounds: Number of passes over the dock.
    func debugCyclePickers(intRounds: Int) {
        Task { [weak self] in
            for _ in 0..<intRounds {
                guard let self else { return }
                for intIndex in self.objTracker.arrObjItems.indices where self.objTracker.arrObjItems[intIndex].blnIsRunning {
                    self.showPicker(forIndex: intIndex, arrObjWindows: nil)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            self?.hidePicker()
        }
    }

    // MARK: - Layout

    /// Sizes the panel to fit the icons and centers it at the bottom of the main display.
    /// - Parameter blnAnimated: Whether to animate the size change.
    private func layoutPanel(blnAnimated: Bool) {
        // The first screen is the one with the menu bar.
        guard let objScreen = NSScreen.screens.first else { return }

        // Indices shift when items change; drop any stale hover/picker.
        objState.intHoveredIndex = nil
        hidePicker()

        let fltWidth = DockLayout.barWidth(forItemCount: objTracker.arrObjItems.count)
        let objFrame = NSRect(
            x: (objScreen.frame.midX - fltWidth / 2).rounded(),
            y: objScreen.frame.minY + DockLayout.fltScreenGap,
            width: fltWidth,
            height: DockLayout.fltPanelHeight
        )

        if blnAnimated {
            NSAnimationContext.runAnimationGroup { objContext in
                objContext.duration = 0.2
                objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
                objPanel.animator().setFrame(objFrame, display: true)
            }
        } else {
            objPanel.setFrame(objFrame, display: true)
        }
    }

    /// Screen point at the top-center of an icon, where the picker anchors.
    /// - Parameter intIndex: Dock item index.
    /// - Returns: Screen coordinates.
    private func anchorPoint(forIndex intIndex: Int) -> CGPoint {
        CGPoint(
            x: objPanel.frame.minX + DockLayout.iconMidX(at: intIndex),
            y: objPanel.frame.minY + DockLayout.fltBarHeight
        )
    }

    // MARK: - Dock interaction

    /// Tracks the hovered icon and schedules the picker to show or hide.
    /// - Parameter objPoint: Panel-local mouse point, or `nil` when the mouse leaves.
    private func handleDockHover(_ objPoint: CGPoint?) {
        let intIndex = objPoint.flatMap { DockLayout.iconIndex(at: $0, itemCount: objTracker.arrObjItems.count) }
        guard intIndex != objState.intHoveredIndex else { return }
        objState.intHoveredIndex = intIndex

        objShowPickerTask?.cancel()

        guard let intIndex else {
            scheduleHidePicker()
            return
        }

        objHidePickerTask?.cancel()

        if objPicker.blnIsVisible {
            // A picker is open: sweeping to another icon switches instantly.
            if objPicker.intAnchorIndex != intIndex {
                showPicker(forIndex: intIndex, arrObjWindows: nil)
            }
        } else {
            // Otherwise wait briefly so passing over icons doesn't flash pickers.
            objShowPickerTask = Task { [weak self] in
                try? await Task.sleep(for: Self.objHoverShowDelay)
                guard !Task.isCancelled else { return }
                self?.showPicker(forIndex: intIndex, arrObjWindows: nil)
            }
        }
    }

    /// Performs the click action for the icon under the mouse.
    /// - Parameter objPoint: Panel-local click point.
    private func handleDockClick(_ objPoint: CGPoint) {
        guard let intIndex = DockLayout.iconIndex(at: objPoint, itemCount: objTracker.arrObjItems.count) else { return }
        objShowPickerTask?.cancel()

        let objItem = objTracker.arrObjItems[intIndex]
        let objAppUrl = objItem.objAppUrl ?? objItem.objRunningApp?.bundleURL

        // Not running: launch it.
        guard let objApp = objItem.objRunningApp, !objApp.isTerminated else {
            hidePicker()
            if let objAppUrl { objWindowService.open(objAppUrl) }
            return
        }

        let arrObjWindows = objWindowService.windows(for: objApp)

        switch arrObjWindows.count {
        case 0:
            // No windows on this Space: reopen, like the native Dock.
            hidePicker()
            if let objAppUrl { objWindowService.open(objAppUrl) } else { objApp.activate() }
        case 1:
            hidePicker()
            objWindowService.raise(arrObjWindows[0], of: objApp)
        default:
            // Several windows: let the user choose the exact one.
            showPicker(forIndex: intIndex, arrObjWindows: arrObjWindows)
        }
    }

    // MARK: - Picker

    /// Opens the picker for a dock item, if it has any windows.
    /// - Parameters:
    ///   - intIndex: Dock item index.
    ///   - arrObjWindows: Pre-fetched windows, or `nil` to fetch now.
    private func showPicker(forIndex intIndex: Int, arrObjWindows: [WindowInfo]?) {
        guard objTracker.arrObjItems.indices.contains(intIndex) else { return }
        let objItem = objTracker.arrObjItems[intIndex]

        guard let objApp = objItem.objRunningApp, !objApp.isTerminated else {
            hidePicker()
            return
        }

        // Without Accessibility we can't list windows; say so instead of showing nothing.
        guard AccessibilityPermission.blnIsTrusted else {
            objPicker.showPermissionNotice(
                strAppName: objItem.strName,
                intAnchorIndex: intIndex,
                objAnchorPoint: anchorPoint(forIndex: intIndex)
            )
            installOutsideClickMonitor()
            return
        }

        let arrObjResolved = arrObjWindows ?? objWindowService.windows(for: objApp)
        guard !arrObjResolved.isEmpty else {
            hidePicker()
            return
        }

        objPicker.show(
            strAppName: objItem.strName,
            objAppIcon: objItem.objIcon,
            arrObjWindows: arrObjResolved,
            intAnchorIndex: intIndex,
            objAnchorPoint: anchorPoint(forIndex: intIndex)
        )
        installOutsideClickMonitor()
    }

    /// Keeps the picker open while the mouse is over it; schedules hiding when it leaves.
    /// - Parameter blnInside: Whether the mouse is inside the picker.
    private func handlePickerHover(_ blnInside: Bool) {
        if blnInside {
            objHidePickerTask?.cancel()
        } else {
            scheduleHidePicker()
        }
    }

    /// Raises the window chosen in the picker.
    /// - Parameter objWindow: Selected window.
    private func handlePickerSelection(_ objWindow: WindowInfo) {
        guard let intIndex = objPicker.intAnchorIndex,
              objTracker.arrObjItems.indices.contains(intIndex),
              let objApp = objTracker.arrObjItems[intIndex].objRunningApp else { return }

        hidePicker()
        objWindowService.raise(objWindow, of: objApp)
    }

    /// Closes a window from the picker, then refreshes the picker (or hides it if none remain).
    /// - Parameter objWindow: Window to close.
    private func handlePickerClose(_ objWindow: WindowInfo) {
        guard let intIndex = objPicker.intAnchorIndex else { return }
        objWindowService.close(objWindow)

        // Give the app a moment to actually close it (or show a save sheet).
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.objPicker.intAnchorIndex == intIndex else { return }
            self.showPicker(forIndex: intIndex, arrObjWindows: nil)
        }
    }

    /// Hides the picker after a short grace period unless the mouse returns to it or the dock.
    private func scheduleHidePicker() {
        objHidePickerTask?.cancel()
        objHidePickerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objHoverHideDelay)
            guard !Task.isCancelled, let self else { return }
            if !self.objPicker.blnMouseInside && self.objState.intHoveredIndex == nil {
                self.hidePicker()
            }
        }
    }

    /// Hides the picker immediately and cancels pending hover work.
    private func hidePicker() {
        objShowPickerTask?.cancel()
        objHidePickerTask?.cancel()
        objPicker.hide()
        removeOutsideClickMonitor()
    }

    /// Closes the picker when the user clicks in another app.
    /// Global monitors only see other apps' events, so dock clicks aren't affected.
    private func installOutsideClickMonitor() {
        guard objOutsideClickMonitor == nil else { return }
        objOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePicker() }
        }
    }

    /// Removes the outside-click monitor.
    private func removeOutsideClickMonitor() {
        if let objOutsideClickMonitor {
            NSEvent.removeMonitor(objOutsideClickMonitor)
        }
        objOutsideClickMonitor = nil
    }
}
