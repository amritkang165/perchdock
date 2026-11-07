import AppKit
import Observation
import UniformTypeIdentifiers

/// Owns the dock panel and turns mouse input into actions.
///
/// Click behavior:
/// - app not running → launch it
/// - running, no windows → reopen (most apps open a new window)
/// - one window → raise it
/// - several windows → show the picker so you choose the exact window
///
/// Hovering an icon briefly also opens the picker (Windows-taskbar style).
/// Dragging reorders; dragging off the dock removes; right-click opens a menu.
@MainActor
final class DockController {
    private static let objHoverHideDelay: Duration = .milliseconds(220)
    /// Points the cursor must move after pressing before a press becomes a drag.
    private static let fltDragThreshold: CGFloat = 5
    /// How far beyond the bar a dragged icon must go to be removed on release.
    private static let fltRemoveDistance: CGFloat = 60

    private let objTracker: AppTracker
    private let objWindowService: WindowService
    private let objSettings: SettingsStore
    private let objState = DockState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<DockView>
    private let objPicker: WindowPickerController
    private let objDragIcon = DragIconController()
    private let objHoverLabel = HoverLabelController()
    private let objMouseMonitor = MouseMonitor()

    // Display the dock is on (`nil` = main display).
    private var intScreenId: CGDirectDisplayID?
    private var objMoveScreenTask: Task<Void, Never>?

    private var objShowPickerTask: Task<Void, Never>?
    private var objHidePickerTask: Task<Void, Never>?
    private var objOutsideClickMonitor: Any?
    private var objScreenObserver: NSObjectProtocol?

    // Auto-hide.
    private var blnShown = true
    private var blnMouseOverDock = false
    private var blnMenuOpen = false
    private var objAutoHideTask: Task<Void, Never>?
    private var objAutoShowTask: Task<Void, Never>?

    // Press/drag tracking.
    private var objPressPoint: CGPoint?
    private var intPressIndex: Int?

    /// Wires the panel, picker, app tracker and settings together.
    /// - Parameters:
    ///   - objTracker: Source of dock items.
    ///   - objWindowService: Window listing and raising.
    ///   - objThumbnailService: Window thumbnails for the picker.
    ///   - objSettings: User preferences.
    init(objTracker: AppTracker, objWindowService: WindowService, objThumbnailService: ThumbnailService, objSettings: SettingsStore) {
        self.objTracker = objTracker
        self.objWindowService = objWindowService
        self.objSettings = objSettings
        objPicker = WindowPickerController(objThumbnailService: objThumbnailService)

        objPanel = DockPanel(contentRect: .zero)
        objHostingView = TrackingHostingView(rootView: DockView(objTracker: objTracker, objSettings: objSettings, objState: objState))
        objPanel.contentView = objHostingView
        objHostingView.enableFileDrops()

        wireCallbacks()
        observeSettings()
    }

    /// Positions and shows the dock, and starts following the cursor.
    func show() {
        blnShown = !objSettings.blnAutoHide
        layoutPanel(blnAnimated: false)
        objPanel.orderFrontRegardless()
        objMouseMonitor.start()
    }

    // MARK: - Wiring

    /// Connects view, picker, tracker and system callbacks.
    private func wireCallbacks() {
        objHostingView.onMouseMoved = { [weak self] _ in
            self?.handleMouse(at: NSEvent.mouseLocation)
        }
        objHostingView.onMouseDown = { [weak self] objPoint in
            self?.handleMouseDown(objPoint)
        }
        objHostingView.onMouseDragged = { [weak self] objPoint in
            self?.handleMouseDragged(objPoint)
        }
        objHostingView.onMouseUp = { [weak self] objPoint in
            self?.handleMouseUp(objPoint)
        }
        objHostingView.onRightMouseDown = { [weak self] objPoint, objEvent in
            self?.showContextMenu(at: objPoint, objEvent: objEvent)
        }
        objHostingView.onFileDragUpdated = { [weak self] arrObjUrls, objPoint in
            self?.fileDragOperation(arrObjUrls, at: objPoint) ?? []
        }
        objHostingView.onFileDrop = { [weak self] arrObjUrls, objPoint in
            self?.handleFileDrop(arrObjUrls, at: objPoint) ?? false
        }

        objMouseMonitor.onMove = { [weak self] objScreenPoint in
            self?.handleMouse(at: objScreenPoint)
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

        // Re-dock when displays are added, removed or rearranged.
        objScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel(blnAnimated: false) }
        }
    }

    /// Re-lays out the panel whenever a geometry or auto-hide setting changes.
    private func observeSettings() {
        withObservationTracking {
            _ = objSettings.fltIconSize
            _ = objSettings.fltEffectiveMagnification
            _ = objSettings.enmPosition
            _ = objSettings.blnAutoHide
            _ = objSettings.enmDisplayMode
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; apply on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.objSettings.enmDisplayMode == .main {
                    self.intScreenId = nil
                }
                self.blnShown = !self.objSettings.blnAutoHide || self.blnMouseOverDock
                self.layoutPanel(blnAnimated: true)
                self.observeSettings()
            }
        }
    }

    // MARK: - Geometry

    /// Geometry for the current settings and items.
    private var objGeometry: DockGeometry {
        DockGeometry(objSettings: objSettings, arrObjItems: objTracker.arrObjItems)
    }

    /// Screen the dock lives on: the chosen display if it's still connected,
    /// otherwise the one with the menu bar.
    private var objScreen: NSScreen? {
        if let intScreenId, let objMatch = NSScreen.screens.first(where: { Self.displayId(of: $0) == intScreenId }) {
            return objMatch
        }
        return NSScreen.screens.first
    }

    /// Core Graphics display ID of a screen.
    /// - Parameter objScreen: Screen.
    /// - Returns: Display ID, or `nil` if unavailable.
    private static func displayId(of objScreen: NSScreen) -> CGDirectDisplayID? {
        (objScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Converts a screen point into panel coordinates (bottom-left origin).
    /// - Parameter objScreenPoint: Point in screen coordinates.
    /// - Returns: Panel-local point.
    private func panelPoint(fromScreen objScreenPoint: CGPoint) -> CGPoint {
        CGPoint(x: objScreenPoint.x - objPanel.frame.minX, y: objScreenPoint.y - objPanel.frame.minY)
    }

    /// Converts dock main/cross coordinates into a screen point.
    /// - Parameters:
    ///   - fltMain: Main coordinate.
    ///   - fltCross: Cross coordinate.
    /// - Returns: Screen point.
    private func screenPoint(main fltMain: CGFloat, cross fltCross: CGFloat) -> CGPoint {
        let objPoint = objGeometry.panelPoint(main: fltMain, cross: fltCross)
        return CGPoint(x: objPanel.frame.minX + objPoint.x, y: objPanel.frame.minY + objPoint.y)
    }

    /// Sizes the panel for the current items and settings and docks it (or tucks it away).
    /// - Parameter blnAnimated: Whether to animate the change.
    private func layoutPanel(blnAnimated: Bool) {
        guard let objScreen else { return }

        // Indices shift when items change; drop any stale hover/picker.
        objState.intHoveredIndex = nil
        objState.fltMouseMain = nil
        hidePicker()
        objPicker.enmPosition = objSettings.enmPosition

        let objFrame = objGeometry.panelFrame(in: objScreen.frame, blnShown: blnShown)
        animatePanel(to: objFrame, blnAnimated: blnAnimated, fltDuration: 0.2)
    }

    /// Moves the panel, optionally with a short ease-out animation.
    /// - Parameters:
    ///   - objFrame: Target frame.
    ///   - blnAnimated: Whether to animate.
    ///   - fltDuration: Animation length in seconds.
    private func animatePanel(to objFrame: CGRect, blnAnimated: Bool, fltDuration: Double) {
        guard blnAnimated else {
            objPanel.setFrame(objFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = fltDuration
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(objFrame, display: true)
        }
    }

    // MARK: - Hover & auto-hide

    /// Central cursor handler (from the system-wide monitor and the panel itself):
    /// updates hover/magnification, click-through, and auto-hide.
    /// - Parameter objScreenPoint: Cursor location in screen coordinates.
    private func handleMouse(at objScreenPoint: CGPoint) {
        // During a drag the drag handlers own the state.
        guard objState.objDrag == nil, objPressPoint == nil else { return }

        let objGeometry = self.objGeometry
        let (fltMain, fltCross) = objGeometry.mainCross(fromPanelPoint: panelPoint(fromScreen: objScreenPoint))
        let objLayout = objGeometry.layout(mouseMain: objState.fltMouseMain)

        // "Over the dock" = over the bar, or over a magnified icon poking above it.
        let blnOverDock = blnShown
            && fltMain >= objLayout.fltBarStart && fltMain <= objLayout.fltBarEnd
            && fltCross >= -1 && fltCross <= objGeometry.fltPanelThickness

        // Let clicks fall through the transparent margins to windows underneath.
        objPanel.ignoresMouseEvents = !blnOverDock

        if blnOverDock != blnMouseOverDock {
            blnMouseOverDock = blnOverDock
            updateAutoHide()
        }

        objState.fltMouseMain = blnOverDock && objGeometry.fltMagnification > 1.001 ? fltMain : nil
        updateHoveredIndex(blnOverDock ? objGeometry.slotIndex(atMain: fltMain) : nil)
        updateHoverLabel()

        // Hidden dock: watch for the cursor reaching the screen edge.
        if objSettings.blnAutoHide && !blnShown {
            handleEdgeProximity(objScreenPoint)
        }
        // Follow mode: watch for the cursor pushing the dock edge of another display.
        if objSettings.enmDisplayMode == .followCursor {
            handleDisplayFollow(objScreenPoint)
        }
    }

    /// Shows the hovered app's name, or hides the label when previews, a drag or
    /// nothing is hovered.
    private func updateHoverLabel() {
        guard objSettings.blnShowLabels, blnShown, !objPicker.blnIsVisible, objState.objDrag == nil,
              let intIndex = objState.intHoveredIndex,
              let objItem = objTracker.arrObjItems[safe: intIndex] else {
            objHoverLabel.hide()
            return
        }
        objHoverLabel.show(strText: objItem.strName, objAnchorPoint: anchorPoint(forIndex: intIndex), enmPosition: objSettings.enmPosition)
    }

    /// Whether a screen point is touching the dock edge of a screen.
    /// - Parameters:
    ///   - objScreenPoint: Cursor location.
    ///   - objTargetScreen: Screen to test (defaults to the dock's screen).
    /// - Returns: `true` within 1pt of that screen's dock edge.
    private func isAtDockEdge(_ objScreenPoint: CGPoint, of objTargetScreen: NSScreen? = nil) -> Bool {
        guard let objFrame = (objTargetScreen ?? objScreen)?.frame,
              objFrame.insetBy(dx: -1, dy: -1).contains(objScreenPoint) else { return false }
        switch objSettings.enmPosition {
        case .bottom: return objScreenPoint.y <= objFrame.minY + 1
        case .left: return objScreenPoint.x <= objFrame.minX + 1
        case .right: return objScreenPoint.x >= objFrame.maxX - 1
        }
    }

    /// Moves the dock to another display when the cursor rests on that display's
    /// dock edge, like the native Dock.
    /// - Parameter objScreenPoint: Cursor location.
    private func handleDisplayFollow(_ objScreenPoint: CGPoint) {
        guard let objTarget = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(objScreenPoint) }),
              objTarget != objScreen, isAtDockEdge(objScreenPoint, of: objTarget) else {
            objMoveScreenTask?.cancel()
            objMoveScreenTask = nil
            return
        }
        guard objMoveScreenTask == nil else { return }

        objMoveScreenTask = Task { [weak self] in
            guard let self else { return }
            // A short dwell, so merely crossing the edge doesn't yank the dock over.
            try? await Task.sleep(for: .seconds(max(self.objSettings.fltShowDelay, 0.2)))
            guard !Task.isCancelled else { return }
            self.objMoveScreenTask = nil
            guard self.isAtDockEdge(NSEvent.mouseLocation, of: objTarget) else { return }
            self.moveDock(to: objTarget)
        }
    }

    /// Re-docks on another display, sliding in from its edge.
    /// - Parameter objTarget: Destination screen.
    private func moveDock(to objTarget: NSScreen) {
        hidePicker()
        objHoverLabel.hide()
        intScreenId = Self.displayId(of: objTarget)

        // Start tucked beyond the new edge, then slide in.
        objPanel.setFrame(objGeometry.panelFrame(in: objTarget.frame, blnShown: false), display: false)
        blnShown = false
        setShown(true)
    }

    /// Schedules the dock to appear while the cursor rests at the edge.
    /// - Parameter objScreenPoint: Cursor location.
    private func handleEdgeProximity(_ objScreenPoint: CGPoint) {
        guard isAtDockEdge(objScreenPoint) else {
            objAutoShowTask?.cancel()
            objAutoShowTask = nil
            return
        }
        guard objAutoShowTask == nil else { return }

        objAutoShowTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.objSettings.fltShowDelay))
            guard !Task.isCancelled else { return }
            self.objAutoShowTask = nil
            if self.isAtDockEdge(NSEvent.mouseLocation) {
                self.setShown(true)
            }
        }
    }

    /// Hides the dock after a grace period when nothing needs it; keeps it while
    /// the cursor, picker, a menu or a drag is using it.
    private func updateAutoHide() {
        guard objSettings.blnAutoHide else {
            if !blnShown { setShown(true) }
            return
        }

        let blnInUse = blnMouseOverDock || objPicker.blnMouseInside || blnMenuOpen || objState.objDrag != nil
        if blnInUse || !blnShown {
            objAutoHideTask?.cancel()
            objAutoHideTask = nil
            return
        }
        guard objAutoHideTask == nil else { return }

        objAutoHideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.objSettings.fltHideDelay))
            guard !Task.isCancelled else { return }
            self.objAutoHideTask = nil
            let blnStillIdle = !self.blnMouseOverDock && !self.objPicker.blnMouseInside && !self.blnMenuOpen && self.objState.objDrag == nil
            if blnStillIdle {
                self.setShown(false)
            }
        }
    }

    /// Slides the dock in or out.
    /// - Parameter blnVisible: Target state.
    private func setShown(_ blnVisible: Bool) {
        guard blnShown != blnVisible, let objScreen else { return }
        blnShown = blnVisible
        if !blnVisible {
            hidePicker()
            objHoverLabel.hide()
            objState.fltMouseMain = nil
            updateHoveredIndex(nil)
            objPanel.ignoresMouseEvents = true
        }
        let objFrame = objGeometry.panelFrame(in: objScreen.frame, blnShown: blnVisible)
        animatePanel(to: objFrame, blnAnimated: true, fltDuration: blnVisible ? 0.18 : 0.16)

        // Shown via the edge but never entered: hide again after the grace period.
        if blnVisible {
            updateAutoHide()
        }
    }

    /// Tracks the hovered icon and schedules the picker to show or hide.
    /// - Parameter intIndex: Icon under the cursor, or `nil`.
    private func updateHoveredIndex(_ intIndex: Int?) {
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
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.objSettings.fltPreviewDelay))
                guard !Task.isCancelled else { return }
                self.showPicker(forIndex: intIndex, arrObjWindows: nil)
            }
        }
    }

    // MARK: - Press, drag, click

    /// Records a press; it becomes a click or a drag depending on movement.
    /// - Parameter objPoint: Panel-local point.
    private func handleMouseDown(_ objPoint: CGPoint) {
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        objPressPoint = objPoint
        intPressIndex = objGeometry.slotIndex(atMain: fltMain)
        objShowPickerTask?.cancel()
    }

    /// Starts or updates a drag-reorder once the press has moved far enough.
    /// - Parameter objPoint: Panel-local point (may be outside the panel).
    private func handleMouseDragged(_ objPoint: CGPoint) {
        guard let objPressPoint, let intPressIndex else { return }
        let objGeometry = self.objGeometry
        let (fltMain, fltCross) = objGeometry.mainCross(fromPanelPoint: objPoint)
        let objScreenPoint = NSEvent.mouseLocation

        if objState.objDrag == nil {
            guard hypot(objPoint.x - objPressPoint.x, objPoint.y - objPressPoint.y) >= Self.fltDragThreshold else { return }

            // Begin: hide hover UI and lift the icon into the floating drag panel.
            hidePicker()
            objState.fltMouseMain = nil
            objState.objDrag = DockDrag(intIndex: intPressIndex, intTargetSlot: intPressIndex, blnOutside: false)
            objHoverLabel.hide()
            objDragIcon.begin(
                objIcon: objTracker.arrObjItems[intPressIndex].objIcon,
                fltSize: objGeometry.fltIconSize,
                objScreenPoint: objScreenPoint
            )
        }

        // Only pinned items can be removed by dragging them off.
        let blnPinned = objTracker.arrObjItems[safe: intPressIndex]?.blnIsPinned ?? false
        let blnOutside = blnPinned && (fltCross > objGeometry.fltBarThickness + Self.fltRemoveDistance || fltCross < -Self.fltRemoveDistance)

        objState.objDrag?.intTargetSlot = objGeometry.dropSlot(atMain: fltMain)
        objState.objDrag?.blnOutside = blnOutside
        objDragIcon.move(to: objScreenPoint, blnRemoving: blnOutside)
    }

    /// Finishes a drag, or performs the click action.
    /// - Parameter objPoint: Panel-local point.
    private func handleMouseUp(_ objPoint: CGPoint) {
        defer {
            objPressPoint = nil
            intPressIndex = nil
            handleMouse(at: NSEvent.mouseLocation)
        }

        if let objDrag = objState.objDrag {
            finishDrag(objDrag)
            return
        }
        if let intPressIndex {
            handleClick(onIndex: intPressIndex)
        }
    }

    /// Commits a drag: removes the item, or moves it to the target slot.
    /// - Parameter objDrag: The finished drag.
    private func finishDrag(_ objDrag: DockDrag) {
        guard let objItem = objTracker.arrObjItems[safe: objDrag.intIndex] else {
            objState.objDrag = nil
            return
        }

        if objDrag.blnOutside {
            objDragIcon.vanish()
            objState.objDrag = nil
            objTracker.unpin(objItem.strBundleId)
            return
        }

        // Land the floating icon on its slot, then commit the new order.
        let objGeometry = self.objGeometry
        let objTarget = screenPoint(
            main: objGeometry.baseCenter(objDrag.intTargetSlot),
            cross: objGeometry.iconCross(forSize: objGeometry.fltIconSize)
        )
        objDragIcon.land(at: objTarget)
        objState.objDrag = nil
        if objDrag.intTargetSlot != objDrag.intIndex {
            objTracker.move(objItem.strBundleId, toSlot: objDrag.intTargetSlot)
        }
    }

    /// Performs the click action for an icon.
    /// - Parameter intIndex: Clicked item.
    private func handleClick(onIndex intIndex: Int) {
        guard let objItem = objTracker.arrObjItems[safe: intIndex] else { return }
        objShowPickerTask?.cancel()
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
            // No windows: reopen, like the native Dock.
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

    // MARK: - File drops

    /// Decides what dropping files at a point would do.
    /// - Parameters:
    ///   - arrObjUrls: Dragged files.
    ///   - objPoint: Panel-local point.
    /// - Returns: `.copy` to pin apps or open files with the app under the cursor; `[]` otherwise.
    private func fileDragOperation(_ arrObjUrls: [URL], at objPoint: CGPoint) -> NSDragOperation {
        if arrObjUrls.contains(where: isApplication) {
            return .copy
        }
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        return objGeometry.slotIndex(atMain: fltMain) != nil ? .copy : []
    }

    /// Pins dropped apps at the drop slot, or opens dropped files with the app under the cursor.
    /// - Parameters:
    ///   - arrObjUrls: Dropped files.
    ///   - objPoint: Panel-local point.
    /// - Returns: Whether anything was done.
    private func handleFileDrop(_ arrObjUrls: [URL], at objPoint: CGPoint) -> Bool {
        let objGeometry = self.objGeometry
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)

        let arrStrAppIds = arrObjUrls.filter(isApplication).compactMap { Bundle(url: $0)?.bundleIdentifier }
        if !arrStrAppIds.isEmpty {
            let intPinnedCount = objTracker.arrObjItems.filter(\.blnIsPinned).count
            var intSlot = min(objGeometry.dropSlot(atMain: fltMain), intPinnedCount)
            for strId in arrStrAppIds {
                objTracker.pin(strId, at: intSlot)
                intSlot += 1
            }
            return true
        }

        guard let intIndex = objGeometry.slotIndex(atMain: fltMain),
              let objAppUrl = objTracker.arrObjItems[safe: intIndex]?.objAppUrl else { return false }
        let objConfig = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(arrObjUrls, withApplicationAt: objAppUrl, configuration: objConfig, completionHandler: nil)
        return true
    }

    /// Whether a URL is an application bundle.
    /// - Parameter objUrl: File URL.
    /// - Returns: `true` for `.app` bundles.
    private func isApplication(_ objUrl: URL) -> Bool {
        (try? objUrl.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) ?? false
    }

    // MARK: - Context menu

    /// Shows the right-click menu for the icon under the cursor.
    /// - Parameters:
    ///   - objPoint: Panel-local point.
    ///   - objEvent: The triggering event (positions the menu).
    private func showContextMenu(at objPoint: CGPoint, objEvent: NSEvent) {
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        guard let intIndex = objGeometry.slotIndex(atMain: fltMain),
              let objItem = objTracker.arrObjItems[safe: intIndex] else { return }

        hidePicker()
        objShowPickerTask?.cancel()

        let objMenu = buildMenu(for: objItem)
        blnMenuOpen = true
        objHoverLabel.hide()
        updateAutoHide()
        // Blocks until the menu closes.
        NSMenu.popUpContextMenu(objMenu, with: objEvent, for: objHostingView)
        blnMenuOpen = false
        handleMouse(at: NSEvent.mouseLocation)
        updateAutoHide()
    }

    /// Builds the context menu for a dock item.
    /// - Parameter objItem: The item.
    /// - Returns: A populated menu.
    private func buildMenu(for objItem: DockItem) -> NSMenu {
        let objMenu = NSMenu()
        let objApp = objItem.objRunningApp.flatMap { $0.isTerminated ? nil : $0 }

        // Windows, so any one can be picked directly.
        if let objApp {
            let arrObjWindows = objWindowService.windows(for: objApp)
            if !arrObjWindows.isEmpty {
                objMenu.addItem(NSMenuItem.sectionHeader(title: "Windows"))
                for objWindow in arrObjWindows {
                    var strTitle = objWindow.strTitle
                    if let strDesktop = objWindow.strDesktopLabel { strTitle += "  —  \(strDesktop)" }
                    if objWindow.blnIsMinimized { strTitle += "  (minimized)" }
                    objMenu.addItem(ClosureMenuItem(strTitle) { [weak self] in
                        self?.objWindowService.raise(objWindow, of: objApp)
                    })
                }
                objMenu.addItem(.separator())
            }
        }

        let strId = objItem.strBundleId
        objMenu.addItem(ClosureMenuItem("Keep in Dock", objState: objItem.blnIsPinned ? .on : .off) { [weak self] in
            guard let self else { return }
            if objItem.blnIsPinned {
                self.objTracker.unpin(strId)
            } else {
                self.objTracker.pin(strId)
            }
        })

        if let objAppUrl = objItem.objAppUrl ?? objApp?.bundleURL {
            objMenu.addItem(ClosureMenuItem("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([objAppUrl])
            })
        }

        objMenu.addItem(.separator())

        if let objApp {
            objMenu.addItem(ClosureMenuItem(objApp.isHidden ? "Show" : "Hide") {
                if objApp.isHidden { objApp.unhide() } else { objApp.hide() }
            })
            // Holding Option turns Quit into Force Quit, as in the native Dock.
            let blnForce = NSEvent.modifierFlags.contains(.option)
            objMenu.addItem(ClosureMenuItem(blnForce ? "Force Quit" : "Quit") {
                if blnForce { objApp.forceTerminate() } else { objApp.terminate() }
            })
        } else if let objAppUrl = objItem.objAppUrl {
            objMenu.addItem(ClosureMenuItem("Open") { [weak self] in
                self?.objWindowService.open(objAppUrl)
            })
        }

        return objMenu
    }

    // MARK: - Picker

    /// Screen point on an icon's outer edge (away from the screen edge), where the picker anchors.
    /// - Parameter intIndex: Dock item index.
    /// - Returns: Screen coordinates.
    private func anchorPoint(forIndex intIndex: Int) -> CGPoint {
        let objGeometry = self.objGeometry
        let objLayout = objGeometry.layout(mouseMain: objState.fltMouseMain)
        let fltCenter = objLayout.arrFltCenters[safe: intIndex] ?? objGeometry.baseCenter(intIndex)
        let fltSize = objLayout.arrFltSizes[safe: intIndex] ?? objGeometry.fltIconSize
        let fltOuterCross = max(objGeometry.fltBarThickness, objGeometry.iconCross(forSize: fltSize) + fltSize / 2)
        return screenPoint(main: fltCenter, cross: fltOuterCross)
    }

    /// Opens the picker for a dock item, if it has any windows.
    /// - Parameters:
    ///   - intIndex: Dock item index.
    ///   - arrObjWindows: Pre-fetched windows, or `nil` to fetch now.
    private func showPicker(forIndex intIndex: Int, arrObjWindows: [WindowInfo]?) {
        guard blnShown, let objItem = objTracker.arrObjItems[safe: intIndex] else { return }
        objPicker.blnLivePreviews = objSettings.blnLivePreviews
        objPicker.blnReduceOnBattery = objSettings.blnReducePreviewsOnBattery

        guard let objApp = objItem.objRunningApp, !objApp.isTerminated else {
            hidePicker()
            return
        }
        // The picker shows the name itself.
        objHoverLabel.hide()

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

    /// Keeps the picker (and dock) open while the cursor is over the picker.
    /// - Parameter blnInside: Whether the cursor is inside the picker.
    private func handlePickerHover(_ blnInside: Bool) {
        if blnInside {
            objHidePickerTask?.cancel()
        } else {
            scheduleHidePicker()
        }
        updateAutoHide()
    }

    /// Raises the window chosen in the picker.
    /// - Parameter objWindow: Selected window.
    private func handlePickerSelection(_ objWindow: WindowInfo) {
        guard let intIndex = objPicker.intAnchorIndex,
              let objApp = objTracker.arrObjItems[safe: intIndex]?.objRunningApp else { return }

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

    /// Hides the picker after a short grace period unless the cursor returns to it or the dock.
    private func scheduleHidePicker() {
        objHidePickerTask?.cancel()
        objHidePickerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objHoverHideDelay)
            guard !Task.isCancelled, let self else { return }
            if !self.objPicker.blnMouseInside && self.objState.intHoveredIndex == nil {
                self.hidePicker()
                self.updateAutoHide()
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

    // MARK: - Debug

    /// Debug aid: magnifies as if the cursor rested on an icon, without moving the
    /// real cursor (the next real mouse move clears it).
    /// - Parameter intIndex: Icon to center the magnification on.
    func debugMagnify(atIndex intIndex: Int) {
        objState.fltMouseMain = objGeometry.baseCenter(intIndex)
        // Show the name label too, but skip the picker's hover schedule.
        objState.intHoveredIndex = intIndex
        Task { @MainActor [weak self] in
            // Wait for the magnified layout so the label anchors to the grown icon.
            try? await Task.sleep(for: .milliseconds(300))
            self?.updateHoverLabel()
        }
    }

    /// Debug aid: opens the picker for one icon (stays until the mouse moves).
    /// - Parameter intIndex: Dock item index.
    func debugShowPicker(atIndex intIndex: Int) {
        showPicker(forIndex: intIndex, arrObjWindows: nil)
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
}
