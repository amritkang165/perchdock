import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Owns the dock panel and turns mouse input into actions.
///
/// Click behavior:
/// - app not running → launch it
/// - running, no windows → reopen (most apps open a new window)
/// - in the background → bring its most recent window forward
/// - already in front → raise its next window (repeat clicks cycle through all)
/// - Option-click → hide the app
///
/// Hovering an icon briefly opens the picker (Windows-taskbar style) to pick an
/// exact window; scrolling over an icon flips through its windows.
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
    private let objNewWindowTracker: NewWindowTracker
    private let objSettings: SettingsStore
    private let objState = DockState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<DockView>
    private let objPicker: WindowPickerController
    private let objDragIcon = DragIconController()
    private let objHoverLabel = HoverLabelController()
    private let objGrid = GridPopoverController()
    private let objMouseMonitor = MouseMonitor()

    /// Opens MacDock's Settings window (provided by the app delegate).
    var onOpenSettings: (() -> Void)?

    // Display the dock is on (`nil` = main display).
    private var intScreenId: CGDirectDisplayID?
    private var objMoveScreenTask: Task<Void, Never>?

    private var objShowPickerTask: Task<Void, Never>?
    private var objHidePickerTask: Task<Void, Never>?
    private var objOutsideClickMonitor: Any?
    /// App whose windows the picker is showing (a dock app or a group member).
    private var objPickerApp: NSRunningApplication?
    /// Re-opens the current picker with fresh windows.
    private var fnPickerRefresh: (() -> Void)?
    /// Group popover tile under the cursor.
    private var intGridHoveredTile: Int?
    /// Apps in the open group popover (empty for folder stacks).
    private var arrObjGridMembers: [DockItem] = []
    private var objLocalMiddleMonitor: Any?
    private var objGlobalMiddleMonitor: Any?
    private var dblLastMiddleTimestamp: TimeInterval = -1
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
    ///   - objNewWindowTracker: Flags recently opened windows.
    ///   - objBadges: Notification badges and progress from the system Dock.
    ///   - objSettings: User preferences.
    init(
        objTracker: AppTracker,
        objWindowService: WindowService,
        objThumbnailService: ThumbnailService,
        objNewWindowTracker: NewWindowTracker,
        objBadges: DockBadgeService,
        objSettings: SettingsStore
    ) {
        self.objTracker = objTracker
        self.objWindowService = objWindowService
        self.objNewWindowTracker = objNewWindowTracker
        self.objSettings = objSettings
        objPicker = WindowPickerController(objThumbnailService: objThumbnailService)

        objPanel = DockPanel(contentRect: .zero)
        objHostingView = TrackingHostingView(rootView: DockView(
            objTracker: objTracker,
            objSettings: objSettings,
            objState: objState,
            objNewWindowTracker: objNewWindowTracker,
            objBadges: objBadges
        ))
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
        objHostingView.onScrollWheel = { [weak self] objPoint, objEvent in
            self?.handleScroll(at: objPoint, objEvent: objEvent)
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
        objPicker.onMiddleClickWindow = { [weak self] objWindow in
            self?.handlePickerMiddleClick(objWindow)
        }
        objPicker.onRightClickWindow = { [weak self] objWindow, objEvent in
            self?.handlePickerRightClick(objWindow, objEvent: objEvent)
        }
        installMiddleClickMonitors()
        objGrid.onHide = { [weak self] in
            guard let self else { return }
            self.intGridHoveredTile = nil
            // A group member's preview goes with its popover.
            if (self.objPicker.intAnchorIndex ?? 0) < 0 {
                self.hidePicker()
            }
            self.updateAutoHide()
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
            _ = objSettings.blnCompact
            _ = objSettings.blnShowTrash
            _ = objSettings.blnShowMinimized
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; apply on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.objSettings.enmDisplayMode == .main {
                    self.intScreenId = nil
                }
                // Trash / minimized tiles come and go with their toggles.
                self.objTracker.rebuild()
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
        objGrid.hide()
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
            && fltCross >= -1 && fltCross <= objGeometry.fltHoverThickness

        // Let clicks fall through the transparent margins to windows underneath.
        objPanel.ignoresMouseEvents = !blnOverDock

        if blnOverDock != blnMouseOverDock {
            blnMouseOverDock = blnOverDock
            updateAutoHide()
        }

        objState.fltMouseMain = blnOverDock && objGeometry.fltMagnification > 1.001 ? fltMain : nil
        let intSlot = blnOverDock ? objGeometry.slotIndex(atMain: fltMain) : nil
        // Remember where the cursor last was on the picker's own icon: the start of
        // the path toward the picker.
        if objPicker.blnIsVisible, let intSlot, intSlot == objPicker.intAnchorIndex {
            objPickerPathStart = objScreenPoint
        }
        updateHoveredIndex(intSlot)
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
        guard objSettings.blnShowLabels, blnShown, !objPicker.blnIsVisible, !objGrid.blnIsVisible, objState.objDrag == nil,
              let intIndex = objState.intHoveredIndex,
              let objItem = objTracker.arrObjItems[safe: intIndex], !objItem.blnIsDivider else {
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

        let blnInUse = blnMouseOverDock || objPicker.blnMouseInside || objGrid.blnIsVisible || blnMenuOpen || objState.objDrag != nil
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
            let blnStillIdle = !self.blnMouseOverDock && !self.objPicker.blnMouseInside && !self.objGrid.blnIsVisible
                && !self.blnMenuOpen && self.objState.objDrag == nil
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
            guard objPicker.intAnchorIndex != intIndex else { return }
            if isHeadingToPicker(NSEvent.mouseLocation) {
                // Crossing a neighbor on the way up to the picker: hold the current
                // picker unless the cursor settles on this icon or veers away.
                objShowPickerTask = Task { [weak self] in
                    guard let self else { return }
                    await self.waitWhileHeadingToPicker()
                    guard !Task.isCancelled, self.objState.intHoveredIndex == intIndex, !self.objPicker.blnMouseInside else { return }
                    self.showPicker(forIndex: intIndex, arrObjWindows: nil)
                }
            } else {
                // Sweeping along the dock: switch instantly.
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
        guard let objPressPoint, let intPressIndex,
              let objDragged = objTracker.arrObjItems[safe: intPressIndex], objDragged.blnIsMovable else { return }
        let objGeometry = self.objGeometry
        let (fltMain, fltCross) = objGeometry.mainCross(fromPanelPoint: objPoint)
        let objScreenPoint = NSEvent.mouseLocation

        if objState.objDrag == nil {
            guard hypot(objPoint.x - objPressPoint.x, objPoint.y - objPressPoint.y) >= Self.fltDragThreshold else { return }

            // Begin: hide hover UI and lift the icon into the floating drag panel.
            hidePicker()
            objGrid.hide()
            objState.fltMouseMain = nil
            objState.objDrag = DockDrag(intIndex: intPressIndex, intTargetSlot: intPressIndex, blnOutside: false)
            objHoverLabel.hide()
            objDragIcon.begin(
                objIcon: objDragged.blnIsDivider ? DividerDragIcon.image : objDragged.objIcon,
                fltSize: objGeometry.fltIconSize,
                objScreenPoint: objScreenPoint
            )
        }
        guard let objDrag = objState.objDrag else { return }

        // Only pinned items can be removed by dragging them off.
        let blnOutside = objDragged.blnIsPinned
            && (fltCross > objGeometry.fltBarThickness + Self.fltRemoveDistance || fltCross < -Self.fltRemoveDistance)

        // Hovering a group (with an app) or the Trash (with anything pinned) targets
        // it; the layout freezes meanwhile so the target doesn't slide away.
        let intCandidate = blnOutside ? nil : dropTarget(forDragged: objDragged, objDrag: objDrag, fltMain: fltMain, fltCross: fltCross)
        updateDropTarget(intCandidate)
        if intCandidate == nil {
            objState.objDrag?.intTargetSlot = allowedSlot(for: objDragged, intIndex: intPressIndex,
                                                         intSlot: objGeometry.dropSlot(atMain: fltMain, intDragIndex: intPressIndex))
        }
        objState.objDrag?.blnOutside = blnOutside
        objDragIcon.move(to: objScreenPoint, blnRemoving: blnOutside)
    }

    /// Item under the cursor that would accept the dragged item, if any.
    /// - Parameters:
    ///   - objDragged: Item being dragged.
    ///   - objDrag: Current drag (for the current layout).
    ///   - fltMain: Cursor main coordinate.
    ///   - fltCross: Cursor cross coordinate.
    /// - Returns: Index of a group or the Trash, or `nil`.
    private func dropTarget(forDragged objDragged: DockItem, objDrag: DockDrag, fltMain: CGFloat, fltCross: CGFloat) -> Int? {
        let objGeometry = self.objGeometry
        guard fltCross >= -10, fltCross <= objGeometry.fltBarThickness + 10 else { return nil }
        let objLayout = objGeometry.layout(dragging: objDrag)
        // The middle of an icon targets it; its edges still reorder.
        let fltRadius = objGeometry.fltIconSize * 0.3

        for (intIndex, objItem) in objTracker.arrObjItems.enumerated() where intIndex != objDrag.intIndex {
            guard let fltCenter = objLayout.arrFltCenters[safe: intIndex], abs(fltMain - fltCenter) <= fltRadius else { continue }
            switch objItem.enmKind {
            case .group where objDragged.blnIsApp:
                return intIndex
            // App onto app: makes a new group of the two.
            case .app where objDragged.blnIsApp:
                return intIndex
            case .trash where objDragged.blnIsPinned:
                return intIndex
            default:
                return nil
            }
        }
        return nil
    }

    /// How long to hold an app over another app before they'd form a group, so
    /// sweeping past icons while reordering doesn't group them by accident.
    private static let objGroupDwell: Duration = .milliseconds(300)
    /// Pending app-onto-app target, armed after `objGroupDwell`.
    private var intPendingGroupTarget: Int?
    private var objGroupDwellTask: Task<Void, Never>?

    /// Applies the item under the cursor as the drop target. Groups and the Trash
    /// take effect at once; another app only after a short hold.
    /// - Parameter intCandidate: Accepting item under the cursor, or `nil`.
    private func updateDropTarget(_ intCandidate: Int?) {
        let blnIsApp = intCandidate.flatMap { objTracker.arrObjItems[safe: $0] }?.blnIsApp ?? false

        guard blnIsApp, let intCandidate else {
            cancelGroupDwell()
            objState.objDrag?.intDropTarget = intCandidate
            return
        }
        // Same app as before: already armed or still waiting.
        guard intPendingGroupTarget != intCandidate else { return }

        cancelGroupDwell()
        objState.objDrag?.intDropTarget = nil
        intPendingGroupTarget = intCandidate
        objState.intGroupPending = intCandidate
        objGroupDwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objGroupDwell)
            guard !Task.isCancelled, let self, self.intPendingGroupTarget == intCandidate, self.objState.objDrag != nil else { return }
            self.objState.objDrag?.intDropTarget = intCandidate
        }
    }

    /// Forgets a pending app-onto-app target.
    private func cancelGroupDwell() {
        objGroupDwellTask?.cancel()
        objGroupDwellTask = nil
        intPendingGroupTarget = nil
        objState.intGroupPending = nil
    }

    /// Where drop slots fall, counted among the items other than the dragged one.
    private struct DropSections {
        /// Last slot in the pinned section.
        let intPinnedEnd: Int
        /// Running-section slots, or `nil` when the dragged item can't go there.
        let objRunning: ClosedRange<Int>?
        /// Right-hand stack slots (before minimized windows and the Trash), or `nil`
        /// when the dragged item can't go there (only folders can).
        let objTrailing: ClosedRange<Int>?
    }

    /// Works out the pinned, running and right-hand slot ranges for a drag.
    /// - Parameter objDragged: Item being dragged.
    /// - Returns: Section boundaries.
    private func dropSections(for objDragged: DockItem) -> DropSections {
        let arrObjItems = objTracker.arrObjItems
        let blnDraggedLeftPinned = objDragged.blnIsPinned && !objDragged.blnIsTrailing
        let intPinnedOthers = arrObjItems.filter { $0.blnIsPinned && !$0.blnIsTrailing }.count - (blnDraggedLeftPinned ? 1 : 0)
        let intRunningOthers = arrObjItems.filter { $0.blnIsApp && !$0.blnIsPinned }.count - (objDragged.blnIsPinned ? 0 : 1)

        // Folders can also sit on the right: just after the trailing divider, among
        // the other right-hand stacks (slots count the items other than the dragged one).
        var objTrailing: ClosedRange<Int>?
        if case .folder = objDragged.enmKind {
            let arrObjOthers = arrObjItems.filter { $0.strBundleId != objDragged.strBundleId }
            let intStacks = arrObjOthers.filter(\.blnIsTrailing).count
            if let intDivider = arrObjOthers.firstIndex(where: { $0.strBundleId == AppTracker.strTrailingDividerId }) {
                objTrailing = (intDivider + 1)...(intDivider + 1 + intStacks)
            } else {
                // No right-hand section yet: the end of the dock starts one.
                objTrailing = arrObjOthers.count...arrObjOthers.count
            }
        }

        // Only running apps can live in the running section (others would vanish).
        guard objDragged.blnIsApp, objDragged.blnIsRunning, intRunningOthers > 0 || !objDragged.blnIsPinned else {
            return DropSections(intPinnedEnd: intPinnedOthers, objRunning: nil, objTrailing: objTrailing)
        }
        // The automatic divider sits between the sections when both have items.
        let intRunningStart = intPinnedOthers + (intPinnedOthers > 0 ? 1 : 0)
        return DropSections(intPinnedEnd: intPinnedOthers, objRunning: intRunningStart...(intRunningStart + intRunningOthers),
                            objTrailing: objTrailing)
    }

    /// Clamps a drop slot to where the item may go: the pinned section, or — for a
    /// running app — anywhere among the running apps, or — for a folder — the
    /// right-hand stacks.
    /// - Parameters:
    ///   - objDragged: Item being dragged.
    ///   - intIndex: Its current index.
    ///   - intSlot: Raw drop slot.
    /// - Returns: Allowed slot.
    private func allowedSlot(for objDragged: DockItem, intIndex: Int, intSlot: Int) -> Int {
        let objSections = dropSections(for: objDragged)
        if intSlot <= objSections.intPinnedEnd {
            return intSlot
        }
        if let objTrailing = objSections.objTrailing {
            // Past the left section: snap to whichever side is nearer.
            let fltMidpoint = Double(objSections.intPinnedEnd + objTrailing.lowerBound) / 2
            return Double(intSlot) >= fltMidpoint
                ? min(max(intSlot, objTrailing.lowerBound), objTrailing.upperBound)
                : objSections.intPinnedEnd
        }
        guard let objRunning = objSections.objRunning else {
            // Can't leave the pinned section: stop at its end (or snap back if it was running).
            return objDragged.blnIsPinned ? objSections.intPinnedEnd : intIndex
        }
        return min(max(intSlot, objRunning.lowerBound), objRunning.upperBound)
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
        cancelGroupDwell()
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

        // Dropped onto a group (joins it), another app (the two become a group)
        // or the Trash (leaves the dock).
        if let intTarget = objDrag.intDropTarget, let objTarget = objTracker.arrObjItems[safe: intTarget] {
            objDragIcon.vanish()
            objState.objDrag = nil
            switch objTarget.enmKind {
            case .group(let strGroupId, _):
                objTracker.add(objItem.strBundleId, toGroup: strGroupId)
            case .app:
                // The group takes the target app's place.
                let strGroupId = objTracker.createGroup(with: objTarget.strBundleId)
                objTracker.add(objItem.strBundleId, toGroup: strGroupId)
            case .trash:
                objTracker.unpin(objItem.strBundleId)
            default:
                break
            }
            return
        }

        // Land the floating icon on its slot, then commit the new order.
        let objGeometry = self.objGeometry
        let objTarget = screenPoint(
            main: objGeometry.layout(dragging: objDrag).arrFltCenters[safe: objDrag.intIndex] ?? objGeometry.baseCenter(objDrag.intTargetSlot),
            cross: objGeometry.iconCross(forSize: objGeometry.fltIconSize)
        )
        objDragIcon.land(at: objTarget)
        objState.objDrag = nil
        guard objDrag.intTargetSlot != objDrag.intIndex else { return }
        let objSections = dropSections(for: objItem)

        // Into the running section: unpin (if pinned) and keep the dropped position.
        if let objRunning = objSections.objRunning,
           objDrag.intTargetSlot > objSections.intPinnedEnd, objRunning.contains(objDrag.intTargetSlot) {
            objTracker.placeInRunning(objItem.strBundleId, at: objDrag.intTargetSlot - objRunning.lowerBound)
            return
        }
        // A folder onto the right-hand side, next to the Trash.
        if let objTrailing = objSections.objTrailing,
           objDrag.intTargetSlot > objSections.intPinnedEnd, objTrailing.contains(objDrag.intTargetSlot) {
            objTracker.placeInTrailing(objItem.strBundleId, at: objDrag.intTargetSlot - objTrailing.lowerBound)
            return
        }
        objTracker.move(objItem.strBundleId, toSlot: objDrag.intTargetSlot)
    }

    /// Performs the click action for an item, by kind.
    /// - Parameter intIndex: Clicked item.
    private func handleClick(onIndex intIndex: Int) {
        guard let objItem = objTracker.arrObjItems[safe: intIndex] else { return }
        objShowPickerTask?.cancel()

        switch objItem.enmKind {
        case .app:
            objGrid.hide()
            handleAppClick(objItem)
        case .divider:
            break
        case .group, .folder:
            hidePicker()
            toggleGrid(forIndex: intIndex)
        case .trash:
            objGrid.hide()
            StackService.openTrash()
        case .minimized(let objWindow, let objApp):
            objGrid.hide()
            objWindowService.raise(objWindow, of: objApp)
        }
    }

    /// Click on an app (in the bar or inside a group).
    /// - Parameter objItem: The app's item.
    private func handleAppClick(_ objItem: DockItem) {
        let objAppUrl = objItem.objAppUrl ?? objItem.objRunningApp?.bundleURL

        // Not running: launch it (bouncing until it's up).
        guard let objApp = objItem.objRunningApp, !objApp.isTerminated else {
            hidePicker()
            if let objAppUrl {
                objWindowService.open(objAppUrl)
                trackLaunch(of: objItem.strBundleId)
            }
            return
        }

        hidePicker()

        // Option-click hides the app, like Option-clicking in the native Dock.
        if NSEvent.modifierFlags.contains(.option) {
            objApp.hide()
            return
        }

        let arrObjWindows = markNew(objWindowService.windows(for: objApp))
        guard !arrObjWindows.isEmpty else {
            // No windows: reopen, like the native Dock.
            if let objAppUrl { objWindowService.open(objAppUrl) } else { objApp.activate() }
            return
        }

        // A window you haven't seen yet (e.g. one an agent just opened) wins.
        if arrObjWindows[0].blnIsNew {
            resetCycle()
            objWindowService.raise(arrObjWindows[0], of: objApp)
            return
        }

        // Already in front: each click brings up the app's next window (Windows-style).
        // Otherwise: bring the app forward with its most recent window.
        if NSWorkspace.shared.frontmostApplication == objApp && !objApp.isHidden {
            cycleWindows(of: objItem, intStep: 1, arrObjWindows: arrObjWindows)
        } else {
            resetCycle()
            objWindowService.raise(arrObjWindows[0], of: objApp)
        }
    }

    /// Longest an icon keeps bouncing for a slow launch.
    private static let objMaxLaunchBounce: Duration = .seconds(15)

    /// Bounces an icon until its app finishes launching (or a timeout).
    /// - Parameter strBundleId: App being launched.
    private func trackLaunch(of strBundleId: String) {
        objState.setStrLaunching.insert(strBundleId)
        Task { [weak self] in
            let objDeadline = ContinuousClock.now + Self.objMaxLaunchBounce
            while ContinuousClock.now < objDeadline {
                try? await Task.sleep(for: .milliseconds(250))
                let blnFinished = NSRunningApplication.runningApplications(withBundleIdentifier: strBundleId)
                    .contains { $0.isFinishedLaunching }
                if blnFinished { break }
            }
            self?.objState.setStrLaunching.remove(strBundleId)
        }
    }

    // MARK: - Window cycling

    /// Snapshot of an app's window order, so repeated clicks/scrolls walk every
    /// window even though each raise reshuffles the live order.
    private struct WindowCycle {
        let strBundleId: String
        let arrObjWindows: [WindowInfo]
        var intPosition: Int
        var objLastUse: ContinuousClock.Instant
    }

    /// Idle time after which a new click/scroll starts a fresh cycle.
    private static let objCycleTimeout: Duration = .seconds(2)
    private var objCycle: WindowCycle?

    /// Raises the next (or previous) window of an app.
    /// Cycles windows on this desktop; minimized and other-desktop windows are
    /// only used when there's nothing on this desktop.
    /// - Parameters:
    ///   - objItem: The app's dock item.
    ///   - intStep: +1 for next, -1 for previous.
    ///   - arrObjWindows: Pre-fetched windows (front to back), or `nil` to fetch.
    private func cycleWindows(of objItem: DockItem, intStep: Int, arrObjWindows: [WindowInfo]? = nil) {
        guard let objApp = objItem.objRunningApp, !objApp.isTerminated else { return }

        // Reuse the snapshot while the user keeps cycling the same app.
        if var objCycle, objCycle.strBundleId == objItem.strBundleId,
           ContinuousClock.now - objCycle.objLastUse < Self.objCycleTimeout {
            let intCount = objCycle.arrObjWindows.count
            objCycle.intPosition = ((objCycle.intPosition + intStep) % intCount + intCount) % intCount
            objCycle.objLastUse = .now
            self.objCycle = objCycle
            objWindowService.raise(objCycle.arrObjWindows[objCycle.intPosition], of: objApp)
            return
        }

        let arrObjAll = arrObjWindows ?? objWindowService.windows(for: objApp)
        let arrObjHere = arrObjAll.filter { !$0.blnIsOnOtherSpace && !$0.blnIsMinimized }
        let arrObjCandidates = arrObjHere.isEmpty ? arrObjAll : arrObjHere
        guard !arrObjCandidates.isEmpty else { return }

        // Position 0 is the window currently in front; step from there.
        let intCount = arrObjCandidates.count
        let intPosition = ((intStep % intCount) + intCount) % intCount
        objCycle = WindowCycle(strBundleId: objItem.strBundleId, arrObjWindows: arrObjCandidates, intPosition: intPosition, objLastUse: .now)
        objWindowService.raise(arrObjCandidates[intPosition], of: objApp)
    }

    /// Forgets the cycle snapshot.
    private func resetCycle() {
        objCycle = nil
    }

    /// Accumulated scroll distance toward the next window step.
    private var fltScrollAccumulator: CGFloat = 0
    /// Scroll distance (points) per window step on trackpads.
    private static let fltScrollStep: CGFloat = 24

    /// Scrolling over an icon flips through that app's windows.
    /// - Parameters:
    ///   - objPoint: Panel-local point.
    ///   - objEvent: Scroll event.
    private func handleScroll(at objPoint: CGPoint, objEvent: NSEvent) {
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        guard let intIndex = objGeometry.slotIndex(atMain: fltMain),
              let objItem = objTracker.arrObjItems[safe: intIndex], objItem.blnIsApp, objItem.blnIsRunning else { return }

        // Vertical wheel or either trackpad axis; down/right = next window.
        let fltDelta = abs(objEvent.scrollingDeltaY) >= abs(objEvent.scrollingDeltaX) ? -objEvent.scrollingDeltaY : objEvent.scrollingDeltaX
        let intStep: Int
        if objEvent.hasPreciseScrollingDeltas {
            // Trackpad: one step per `fltScrollStep` points.
            fltScrollAccumulator += fltDelta
            guard abs(fltScrollAccumulator) >= Self.fltScrollStep else { return }
            intStep = fltScrollAccumulator > 0 ? 1 : -1
            fltScrollAccumulator = 0
        } else {
            // Mouse wheel: one step per notch.
            guard fltDelta != 0 else { return }
            intStep = fltDelta > 0 ? 1 : -1
        }

        hidePicker()
        objShowPickerTask?.cancel()
        cycleWindows(of: objItem, intStep: intStep)
    }

    // MARK: - File drops

    /// Decides what dropping files at a point would do.
    /// - Parameters:
    ///   - arrObjUrls: Dragged files.
    ///   - objPoint: Panel-local point.
    /// - Returns: The operation the drop would perform, or `[]`.
    private func fileDragOperation(_ arrObjUrls: [URL], at objPoint: CGPoint) -> NSDragOperation {
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        let objItem = objGeometry.slotIndex(atMain: fltMain).flatMap { objTracker.arrObjItems[safe: $0] }

        switch objItem?.enmKind {
        case .trash?: return .delete
        case .folder?: return .move
        case .app? where !arrObjUrls.contains(where: isApplication): return .copy
        default:
            // Apps get pinned, folders become stacks.
            return arrObjUrls.contains(where: isApplication) || arrObjUrls.contains(where: isFolder) ? .copy : []
        }
    }

    /// Handles files dropped on the dock: onto the Trash (trash them), a stack (move
    /// them in), an app (open them with it), or between items (pin apps, add
    /// folders as stacks).
    /// - Parameters:
    ///   - arrObjUrls: Dropped files.
    ///   - objPoint: Panel-local point.
    /// - Returns: Whether anything was done.
    private func handleFileDrop(_ arrObjUrls: [URL], at objPoint: CGPoint) -> Bool {
        let objGeometry = self.objGeometry
        let (fltMain, _) = objGeometry.mainCross(fromPanelPoint: objPoint)
        let objItem = objGeometry.slotIndex(atMain: fltMain).flatMap { objTracker.arrObjItems[safe: $0] }

        switch objItem?.enmKind {
        case .trash?:
            return StackService.trash(arrObjUrls)
        case .folder(let objFolder)?:
            return StackService.move(arrObjUrls, into: objFolder)
        case .app? where !arrObjUrls.contains(where: isApplication):
            guard let objAppUrl = objItem?.objAppUrl else { return false }
            NSWorkspace.shared.open(arrObjUrls, withApplicationAt: objAppUrl, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return true
        default:
            break
        }

        // Between items: pin apps and add folders as stacks, in drop order.
        let intPinnedCount = objTracker.arrObjItems.filter { $0.blnIsPinned && !$0.blnIsTrailing }.count
        var intSlot = min(objGeometry.dropSlot(atMain: fltMain, intDragIndex: -1), intPinnedCount)
        var blnDidAnything = false
        for objUrl in arrObjUrls {
            if isApplication(objUrl), let strId = Bundle(url: objUrl)?.bundleIdentifier {
                objTracker.pin(strId, at: intSlot)
            } else if isFolder(objUrl) {
                objTracker.addFolder(objUrl, at: intSlot)
            } else {
                continue
            }
            intSlot += 1
            blnDidAnything = true
        }
        return blnDidAnything
    }

    /// Whether a URL is a plain folder (not a package like an app).
    /// - Parameter objUrl: File URL.
    /// - Returns: `true` for folders.
    private func isFolder(_ objUrl: URL) -> Bool {
        let objValues = try? objUrl.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return objValues?.isDirectory == true && objValues?.isPackage != true
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
        let intIndex = objGeometry.slotIndex(atMain: fltMain)

        hidePicker()
        objGrid.hide()
        objShowPickerTask?.cancel()

        let objMenu = intIndex.flatMap { objTracker.arrObjItems[safe: $0] }.map { buildMenu(for: $0) } ?? NSMenu()
        addDockItems(to: objMenu, afterIndex: intIndex)
        blnMenuOpen = true
        objHoverLabel.hide()
        updateAutoHide()
        // Blocks until the menu closes.
        NSMenu.popUpContextMenu(objMenu, with: objEvent, for: objHostingView)
        blnMenuOpen = false
        handleMouse(at: NSEvent.mouseLocation)
        updateAutoHide()
    }

    /// Adds the items every dock menu ends with: Add Divider, Add Folder, Settings.
    /// - Parameters:
    ///   - objMenu: Menu to extend.
    ///   - intIndex: Item that was right-clicked (new things go after it if it's pinned).
    private func addDockItems(to objMenu: NSMenu, afterIndex intIndex: Int?) {
        let intPinnedCount = objTracker.arrObjItems.filter { $0.blnIsPinned && !$0.blnIsTrailing }.count
        // After a pinned item; otherwise at the end of the pinned section.
        let intInsert = intIndex.map { $0 < intPinnedCount ? $0 + 1 : intPinnedCount } ?? intPinnedCount

        if !objMenu.items.isEmpty { objMenu.addItem(.separator()) }
        objMenu.addItem(ClosureMenuItem("Add Divider Here") { [weak self] in
            self?.objTracker.addDivider(at: intInsert)
        })
        objMenu.addItem(ClosureMenuItem("Add Folder to Dock…") { [weak self] in
            self?.chooseFolder(at: intInsert)
        })
        objMenu.addItem(.separator())
        objMenu.addItem(ClosureMenuItem("Dock Settings…") { [weak self] in
            self?.onOpenSettings?()
        })
    }

    /// Asks for a folder and adds it as a stack.
    /// - Parameter intIndex: Position among pinned items.
    private func chooseFolder(at intIndex: Int) {
        NSApp.activate()
        let objPanel = NSOpenPanel()
        objPanel.canChooseDirectories = true
        objPanel.canChooseFiles = false
        objPanel.allowsMultipleSelection = false
        objPanel.prompt = "Add to Dock"
        guard objPanel.runModal() == .OK, let objUrl = objPanel.url else { return }
        objTracker.addFolder(objUrl, at: intIndex)
    }

    /// Builds the context menu for a dock item, by kind.
    /// - Parameter objItem: The item.
    /// - Returns: A populated menu.
    private func buildMenu(for objItem: DockItem) -> NSMenu {
        switch objItem.enmKind {
        case .app:
            return buildAppMenu(for: objItem)

        case .divider(let blnIsAuto):
            let objMenu = NSMenu()
            if !blnIsAuto {
                objMenu.addItem(ClosureMenuItem("Remove Divider") { [weak self] in
                    self?.objTracker.unpin(objItem.strBundleId)
                })
            }
            return objMenu

        case .group(let strGroupId, let arrObjMembers):
            let objMenu = NSMenu()
            objMenu.addItem(NSMenuItem.sectionHeader(title: objItem.strName))
            for objMember in arrObjMembers {
                let objEntry = ClosureMenuItem(objMember.strName) { [weak self] in
                    self?.handleAppClick(objMember)
                }
                objEntry.image = Self.menuIcon(objMember.objIcon)
                objMenu.addItem(objEntry)
            }
            objMenu.addItem(.separator())
            objMenu.addItem(ClosureMenuItem("Edit Group…") { [weak self] in
                self?.editGroup(strGroupId)
            })
            objMenu.addItem(colorMenuItem(forGroup: strGroupId))
            objMenu.addItem(ClosureMenuItem("Ungroup") { [weak self] in
                self?.objTracker.ungroup(strGroupId)
            })
            objMenu.addItem(ClosureMenuItem("Remove Group from Dock") { [weak self] in
                self?.objTracker.unpin(objItem.strBundleId)
            })
            return objMenu

        case .folder(let objFolder):
            let objMenu = NSMenu()
            objMenu.addItem(ClosureMenuItem("Open “\(objItem.strName)”") {
                NSWorkspace.shared.open(objFolder)
            })
            objMenu.addItem(.separator())
            objMenu.addItem(ClosureMenuItem("Remove from Dock") { [weak self] in
                self?.objTracker.unpin(objItem.strBundleId)
            })
            return objMenu

        case .trash(let blnIsFull):
            let objMenu = NSMenu()
            objMenu.addItem(ClosureMenuItem("Open") {
                StackService.openTrash()
            })
            let objEmpty = ClosureMenuItem("Empty Trash") {
                StackService.emptyTrash()
            }
            // Unknown without Full Disk Access, so only disable when we know it's empty.
            objEmpty.isEnabled = blnIsFull || !FileManager.default.isReadableFile(atPath: StackService.objTrashUrl.path)
            objMenu.addItem(objEmpty)
            return objMenu

        case .minimized(let objWindow, let objApp):
            let objMenu = NSMenu()
            objMenu.addItem(ClosureMenuItem("Restore") { [weak self] in
                self?.objWindowService.raise(objWindow, of: objApp)
            })
            objMenu.addItem(ClosureMenuItem("Close Window") { [weak self] in
                self?.objWindowService.close(objWindow)
            })
            return objMenu
        }
    }

    /// Small icon for menu items.
    /// - Parameter objIcon: Full-size icon.
    /// - Returns: A 16-pt copy.
    private static func menuIcon(_ objIcon: NSImage) -> NSImage {
        let objCopy = objIcon.copy() as? NSImage ?? objIcon
        objCopy.size = NSSize(width: 16, height: 16)
        return objCopy
    }

    /// "Color ▸" submenu with a swatch per preset; the current one is checked.
    /// - Parameter strGroupId: Group.
    /// - Returns: Menu item with the submenu.
    private func colorMenuItem(forGroup strGroupId: String) -> NSMenuItem {
        let strCurrent = objTracker.group(strGroupId)?.strColorHex
        let objItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let objSubmenu = NSMenu()
        for objPreset in GroupColor.arrObjPresets {
            let objEntry = ClosureMenuItem(objPreset.strName, objState: objPreset.strHex == strCurrent ? .on : .off) { [weak self] in
                self?.objTracker.setGroupColor(strGroupId, to: objPreset.strHex)
            }
            objEntry.image = GroupColor.swatch(objPreset.strHex)
            objSubmenu.addItem(objEntry)
        }
        objItem.submenu = objSubmenu
        return objItem
    }

    /// Edits a group's name and color in one dialog.
    /// - Parameter strGroupId: Group.
    private func editGroup(_ strGroupId: String) {
        guard let objGroup = objTracker.group(strGroupId) else { return }
        NSApp.activate()

        let objAlert = NSAlert()
        objAlert.messageText = "Edit Group"
        objAlert.addButton(withTitle: "Save")
        objAlert.addButton(withTitle: "Cancel")

        // Name field above a color picker of swatches.
        let objField = NSTextField(string: objGroup.strName)
        objField.placeholderString = "Group name"
        let objColorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for objPreset in GroupColor.arrObjPresets {
            objColorPopup.addItem(withTitle: objPreset.strName)
            objColorPopup.lastItem?.image = GroupColor.swatch(objPreset.strHex)
        }
        let intCurrent = GroupColor.arrObjPresets.firstIndex { $0.strHex == objGroup.strColorHex } ?? 0
        objColorPopup.selectItem(at: intCurrent)

        let objColorRow = NSStackView(views: [NSTextField(labelWithString: "Color:"), objColorPopup])
        objColorRow.spacing = 8
        let objStack = NSStackView(views: [objField, objColorRow])
        objStack.orientation = .vertical
        objStack.alignment = .leading
        objStack.spacing = 10
        objStack.frame = NSRect(x: 0, y: 0, width: 240, height: 62)
        objField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        objAlert.accessoryView = objStack
        objAlert.window.initialFirstResponder = objField

        guard objAlert.runModal() == .alertFirstButtonReturn else { return }
        let strName = objField.stringValue.trimmingCharacters(in: .whitespaces)
        if !strName.isEmpty && strName != objGroup.strName {
            objTracker.renameGroup(strGroupId, to: strName)
        }
        let strHex = GroupColor.arrObjPresets[safe: objColorPopup.indexOfSelectedItem]?.strHex
        if strHex != objGroup.strColorHex {
            objTracker.setGroupColor(strGroupId, to: strHex)
        }
    }

    /// Builds the context menu for an app.
    /// - Parameter objItem: The app's item.
    /// - Returns: A populated menu.
    private func buildAppMenu(for objItem: DockItem) -> NSMenu {
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

        // Groups: start one with this app, or move it into an existing one.
        objMenu.addItem(ClosureMenuItem("New Group with “\(objItem.strName)”") { [weak self] in
            self?.objTracker.createGroup(with: strId)
        })
        let arrObjGroups = objTracker.groups()
        if !arrObjGroups.isEmpty {
            let objGroupsItem = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
            let objSubmenu = NSMenu()
            for objGroup in arrObjGroups {
                objSubmenu.addItem(ClosureMenuItem(objGroup.strName) { [weak self] in
                    self?.objTracker.add(strId, toGroup: objGroup.strId)
                })
            }
            objGroupsItem.submenu = objSubmenu
            objMenu.addItem(objGroupsItem)
        }

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

        // Only apps have window previews; an open group/stack grid takes precedence.
        guard objItem.blnIsApp, !objGrid.blnIsVisible, let objApp = objItem.objRunningApp, !objApp.isTerminated else {
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

        // Flag new windows and list them first, so the one an agent just opened is easy to spot.
        let arrObjResolved = markNew(arrObjWindows ?? objWindowService.windows(for: objApp))
        guard !arrObjResolved.isEmpty else {
            hidePicker()
            return
        }

        objPickerApp = objApp
        fnPickerRefresh = { [weak self] in self?.showPicker(forIndex: intIndex, arrObjWindows: nil) }
        objPicker.show(
            strAppName: objItem.strName,
            objAppIcon: objItem.objIcon,
            arrObjWindows: arrObjResolved,
            intAnchorIndex: intIndex,
            objAnchorPoint: anchorPoint(forIndex: intIndex)
        )
        objPickerPathStart = NSEvent.mouseLocation
        installOutsideClickMonitor()
    }

    /// Sets each window's "new" flag and moves new windows to the front (stable otherwise).
    /// - Parameter arrObjWindows: Windows front to back.
    /// - Returns: Flagged and reordered windows.
    private func markNew(_ arrObjWindows: [WindowInfo]) -> [WindowInfo] {
        let arrObjFlagged = arrObjWindows.map { objWindow in
            var objCopy = objWindow
            objCopy.blnIsNew = objNewWindowTracker.isNew(objWindow.intWindowId)
            return objCopy
        }
        return arrObjFlagged.filter(\.blnIsNew) + arrObjFlagged.filter { !$0.blnIsNew }
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
        guard let objApp = objPickerApp else { return }

        // A group member's window was chosen: the group popover is done too.
        if (objPicker.intAnchorIndex ?? 0) < 0 {
            objGrid.hide()
        }
        hidePicker()
        objWindowService.raise(objWindow, of: objApp)
    }

    /// Closes a window from the picker, then refreshes the picker (or hides it if none remain).
    /// - Parameter objWindow: Window to close.
    private func handlePickerClose(_ objWindow: WindowInfo) {
        guard objPicker.blnIsVisible else { return }
        objWindowService.close(objWindow)
        // Give the app a moment to actually close it (or show a save sheet).
        refreshPicker()
    }

    /// Middle-click on a card: closes the window, or — when it has several tabs —
    /// asks whether to close just the front tab or the whole window.
    /// - Parameter objWindow: Middle-clicked window.
    private func handlePickerMiddleClick(_ objWindow: WindowInfo) {
        guard let objApp = objPickerApp else { return }

        let arrObjTabs = objWindowService.tabs(in: objWindow)
        guard arrObjTabs.count > 1 else {
            handlePickerClose(objWindow)
            return
        }

        let strFrontTitle = arrObjTabs.first(where: \.blnIsSelected)?.strTitle ?? "Current Tab"
        let objMenu = NSMenu()
        objMenu.addItem(ClosureMenuItem("Close Tab “\(strFrontTitle.prefix(40))”") { [weak self] in
            guard let self else { return }
            self.objWindowService.closeFrontTab(of: objWindow, in: objApp)
            self.refreshPicker()
        })
        objMenu.addItem(ClosureMenuItem("Close All \(arrObjTabs.count) Tabs") { [weak self] in
            self?.handlePickerClose(objWindow)
        })

        blnMenuOpen = true
        objPicker.popUpMenu(objMenu)
        blnMenuOpen = false
        updateAutoHide()
    }

    /// Right-click on a card: bring it to this desktop, minimize or close it.
    /// - Parameters:
    ///   - objWindow: Right-clicked window.
    ///   - objEvent: The click (positions the menu).
    private func handlePickerRightClick(_ objWindow: WindowInfo, objEvent: NSEvent) {
        guard let objApp = objPickerApp else { return }

        let objMenu = NSMenu()
        if objWindow.blnIsOnOtherSpace {
            objMenu.addItem(ClosureMenuItem("Bring to This Desktop") { [weak self] in
                self?.bringWindowHere(objWindow, of: objApp)
            })
        }
        objMenu.addItem(ClosureMenuItem(objWindow.blnIsOnOtherSpace ? "Go to \(objWindow.strDesktopLabel ?? "Desktop")" : "Show") { [weak self] in
            self?.handlePickerSelection(objWindow)
        })
        objMenu.addItem(.separator())
        if !objWindow.blnIsMinimized, !objWindow.blnIsOnOtherSpace, let objElement = objWindow.objElement {
            objMenu.addItem(ClosureMenuItem("Minimize") { [weak self] in
                AXUIElementSetAttributeValue(objElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                self?.refreshPicker()
            })
        }
        objMenu.addItem(ClosureMenuItem("Close Window") { [weak self] in
            self?.handlePickerClose(objWindow)
        })

        blnMenuOpen = true
        objPicker.popUpMenu(objMenu)
        blnMenuOpen = false
        updateAutoHide()
    }

    /// Moves a window from another desktop onto this one and raises it: directly
    /// when macOS allows it, otherwise by carrying it over (see `WindowMover`).
    /// - Parameters:
    ///   - objWindow: Window on another desktop.
    ///   - objApp: Its app.
    func bringWindowHere(_ objWindow: WindowInfo, of objApp: NSRunningApplication) {
        hidePicker()
        guard let intWindowId = objWindow.intWindowId else { return }
        Task { [weak self] in
            guard let self else { return }
            let blnMoved = PrivateWindowAPI.moveToActiveSpace(intWindowId)
                ? true
                : await WindowMover.bringHere(objWindow, of: objApp, objWindowService: self.objWindowService)
            guard blnMoved else { return }
            // Now on this desktop: raise it via its fresh AX element.
            try? await Task.sleep(for: .milliseconds(120))
            let objHere = self.objWindowService.windows(for: objApp).first { $0.intWindowId == intWindowId }
            self.objWindowService.raise(objHere ?? objWindow, of: objApp)
        }
    }

    // MARK: - Group & stack grid

    /// Opens (or closes, on a second click) the grid for a group or folder stack.
    /// - Parameters:
    ///   - intIndex: Dock item index.
    ///   - blnRefresh: Re-fill an open popover in place instead of toggling it.
    private func toggleGrid(forIndex intIndex: Int, blnRefresh: Bool = false) {
        guard let objItem = objTracker.arrObjItems[safe: intIndex] else { return }
        if !blnRefresh && objGrid.strAnchorId == objItem.strBundleId {
            objGrid.hide()
            return
        }
        objHoverLabel.hide()

        switch objItem.enmKind {
        case .group(let strGroupId, let arrObjMembers):
            objGrid.onSelect = { [weak self] intTile in
                guard let self, let objMember = arrObjMembers[safe: intTile] else { return }
                self.objGrid.hide()
                self.handleAppClick(objMember)
            }
            objGrid.onRightClick = { [weak self] intTile, objEvent in
                guard let self, let objMember = arrObjMembers[safe: intTile] else { return }
                let objMenu = NSMenu()
                objMenu.addItem(ClosureMenuItem("Remove “\(objMember.strName)” from Group") { [weak self] in
                    self?.objGrid.hide()
                    self?.objTracker.remove(objMember.strBundleId, fromGroup: strGroupId)
                })
                if let objApp = objMember.objRunningApp, !objApp.isTerminated {
                    objMenu.addItem(ClosureMenuItem("Quit \(objMember.strName)") {
                        objApp.terminate()
                    })
                }
                NSMenu.popUpContextMenu(objMenu, with: objEvent, for: self.objHostingView)
            }
            objGrid.onFooter = nil
            arrObjGridMembers = arrObjMembers
            // Drag tiles to reorder the group; the popover re-fills with the saved order.
            objGrid.onReorder = { [weak self] intFrom, intTo in
                guard let self else { return }
                var arrStrOrder = arrObjMembers.map(\.strBundleId)
                let strMoved = arrStrOrder.remove(at: intFrom)
                arrStrOrder.insert(strMoved, at: min(intTo, arrStrOrder.count))
                self.objTracker.setGroupOrder(strGroupId, to: arrStrOrder)
                if let intGroupIndex = self.objTracker.arrObjItems.firstIndex(where: { $0.strBundleId == objItem.strBundleId }) {
                    self.toggleGrid(forIndex: intGroupIndex, blnRefresh: true)
                }
            }
            objGrid.onHoverTile = { [weak self] intTile in
                self?.handleGridTileHover(intTile, arrObjMembers: arrObjMembers)
            }
            // Click the group's name in the popover to rename it in place.
            objGrid.onRename = { [weak self] strName in
                self?.objTracker.renameGroup(strGroupId, to: strName)
            }
            objGrid.show(
                strTitle: objItem.strName,
                arrObjEntries: arrObjMembers.map { GridEntry(id: $0.strBundleId, strName: $0.strName, objIcon: $0.objIcon, blnIsRunning: $0.blnIsRunning) },
                strFooter: nil,
                strAnchorId: objItem.strBundleId,
                objAnchorPoint: anchorPoint(forIndex: intIndex),
                enmPosition: objSettings.enmPosition,
                objTint: objTracker.group(strGroupId)?.strColorHex.map { Color(strHex: $0).opacity(0.22) }
            )

        case .folder(let objFolder):
            let arrObjEntries = StackService.entries(in: objFolder)
            objGrid.onSelect = { [weak self] intTile in
                guard let objUrl = arrObjEntries[safe: intTile]?.objFileUrl else { return }
                self?.objGrid.hide()
                NSWorkspace.shared.open(objUrl)
            }
            objGrid.onRightClick = { [weak self] intTile, objEvent in
                guard let self, let objUrl = arrObjEntries[safe: intTile]?.objFileUrl else { return }
                let objMenu = NSMenu()
                objMenu.addItem(ClosureMenuItem("Open") { NSWorkspace.shared.open(objUrl) })
                objMenu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([objUrl]) })
                objMenu.addItem(.separator())
                objMenu.addItem(ClosureMenuItem("Move to Trash") { [weak self] in
                    StackService.trash([objUrl])
                    self?.objGrid.update(arrObjEntries: StackService.entries(in: objFolder))
                })
                NSMenu.popUpContextMenu(objMenu, with: objEvent, for: self.objHostingView)
            }
            objGrid.onFooter = { [weak self] in
                self?.objGrid.hide()
                NSWorkspace.shared.open(objFolder)
            }
            objGrid.onRename = nil
            objGrid.onHoverTile = nil
            objGrid.onReorder = nil
            arrObjGridMembers = []
            objGrid.show(
                strTitle: objItem.strName,
                arrObjEntries: arrObjEntries,
                strFooter: "Open in Finder",
                strAnchorId: objItem.strBundleId,
                objAnchorPoint: anchorPoint(forIndex: intIndex),
                enmPosition: objSettings.enmPosition
            )

        default:
            return
        }
        updateAutoHide()
    }

    /// Re-lists the picker's windows shortly after a change (e.g. a closed tab retitles its window).
    private func refreshPicker() {
        let intAnchor = objPicker.intAnchorIndex
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            // Skip if the picker has since closed or moved to another app.
            guard let self, self.objPicker.blnIsVisible, self.objPicker.intAnchorIndex == intAnchor else { return }
            self.fnPickerRefresh?()
        }
    }

    // MARK: - Middle-click to quit

    /// Watches middle-button releases (in MacDock and system-wide, since AppKit
    /// doesn't reliably route them to the dock's panels) to quit apps.
    private func installMiddleClickMonitors() {
        objLocalMiddleMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] objEvent in
            let intButton = objEvent.buttonNumber
            let dblTimestamp = objEvent.timestamp
            let blnHandled = MainActor.assumeIsolated {
                self?.handleMiddleClick(intButton: intButton, dblTimestamp: dblTimestamp) ?? false
            }
            return blnHandled ? nil : objEvent
        }
        objGlobalMiddleMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] objEvent in
            let intButton = objEvent.buttonNumber
            let dblTimestamp = objEvent.timestamp
            MainActor.assumeIsolated {
                _ = self?.handleMiddleClick(intButton: intButton, dblTimestamp: dblTimestamp)
            }
        }
    }

    /// Middle-click on a dock app or group-popover app quits it; on a group, quits
    /// the group's running apps. (Middle-clicks on preview cards close windows,
    /// handled by the picker.)
    /// - Parameters:
    ///   - intButton: Released button number.
    ///   - dblTimestamp: Event time (identifies the click).
    /// - Returns: Whether the click was used.
    private func handleMiddleClick(intButton: Int, dblTimestamp: TimeInterval) -> Bool {
        guard intButton == 2, dblTimestamp != dblLastMiddleTimestamp, objState.objDrag == nil else { return false }
        let objMouse = NSEvent.mouseLocation
        if objPicker.blnIsVisible && objPicker.objFrame.contains(objMouse) { return false }

        var arrObjTargets: [DockItem] = []
        var strGroupName: String?
        if objGrid.contains(objMouse) {
            // A tile in a group popover.
            guard let intTile = objGrid.intHoveredTile, let objMember = arrObjGridMembers[safe: intTile] else { return false }
            arrObjTargets = [objMember]
        } else if blnMouseOverDock, let intIndex = objState.intHoveredIndex, let objItem = objTracker.arrObjItems[safe: intIndex] {
            switch objItem.enmKind {
            case .app:
                arrObjTargets = [objItem]
            case .group(_, let arrObjMembers):
                arrObjTargets = arrObjMembers
                strGroupName = objItem.strName
            default:
                return false
            }
        } else {
            return false
        }

        dblLastMiddleTimestamp = dblTimestamp
        let arrObjApps = arrObjTargets.compactMap { objItem in
            objItem.objRunningApp.flatMap { $0.isTerminated ? nil : (objItem.strName, $0) }
        }
        guard !arrObjApps.isEmpty else { return true }
        // Act after the monitor returns: the confirmation is modal.
        Task { @MainActor [weak self] in
            self?.quitApps(arrObjApps, strGroupName: strGroupName)
        }
        return true
    }

    /// Quits apps, first asking when that would close several windows (or apps).
    /// - Parameters:
    ///   - arrObjApps: Display names and running apps.
    ///   - strGroupName: Group name, when quitting a whole group.
    private func quitApps(_ arrObjApps: [(String, NSRunningApplication)], strGroupName: String?) {
        let intWindows = arrObjApps.reduce(0) { $0 + objWindowService.windows(for: $1.1).count }

        if intWindows > 1 || arrObjApps.count > 1 {
            let objAlert = NSAlert()
            let strWindows = "\(intWindows) open window\(intWindows == 1 ? "" : "s")"
            if let strGroupName {
                objAlert.messageText = "Quit \(arrObjApps.count) app\(arrObjApps.count == 1 ? "" : "s") in “\(strGroupName)”?"
                objAlert.informativeText = "\(arrObjApps.map(\.0).joined(separator: ", ")) — \(strWindows) will close."
            } else {
                objAlert.messageText = "Quit \(arrObjApps[0].0)?"
                objAlert.informativeText = "It has \(strWindows), which will all close."
            }
            objAlert.addButton(withTitle: "Quit")
            objAlert.addButton(withTitle: "Cancel")

            // The alert needs MacDock in front; give focus back if the user cancels.
            let objPrevious = NSWorkspace.shared.frontmostApplication
            hidePicker()
            blnMenuOpen = true
            NSApp.activate()
            let enmResponse = objAlert.runModal()
            blnMenuOpen = false
            updateAutoHide()
            guard enmResponse == .alertFirstButtonReturn else {
                if let objPrevious, objPrevious != NSRunningApplication.current { objPrevious.activate() }
                return
            }
        }

        hidePicker()
        for (_, objApp) in arrObjApps {
            objApp.terminate()
        }
    }

    // MARK: - Group member previews

    /// Picker anchor IDs for group tiles: negative, so they never match a dock slot.
    /// - Parameter intTile: Tile index.
    /// - Returns: Anchor ID.
    private static func gridAnchor(forTile intTile: Int) -> Int { -1 - intTile }

    /// Hovering a group member's tile previews its windows (after the usual delay).
    /// - Parameters:
    ///   - intTile: Hovered tile, or `nil` when the cursor left the tiles.
    ///   - arrObjMembers: The group's apps.
    private func handleGridTileHover(_ intTile: Int?, arrObjMembers: [DockItem]) {
        intGridHoveredTile = intTile
        objShowPickerTask?.cancel()
        guard let intTile else {
            scheduleHidePicker()
            return
        }
        objHidePickerTask?.cancel()
        let intAnchor = Self.gridAnchor(forTile: intTile)
        guard objPicker.intAnchorIndex != intAnchor else { return }

        objShowPickerTask = Task { [weak self] in
            guard let self else { return }
            if self.objPicker.blnIsVisible {
                // Crossing other tiles on the way to the open picker: hold it.
                await self.waitWhileHeadingToPicker()
            } else {
                try? await Task.sleep(for: .seconds(self.objSettings.fltPreviewDelay))
            }
            guard !Task.isCancelled, self.intGridHoveredTile == intTile, !self.objPicker.blnMouseInside,
                  let objMember = arrObjMembers[safe: intTile] else { return }
            self.showGridPicker(for: objMember, intTile: intTile)
        }
    }

    /// Opens the picker for a group member, attached to the group popover.
    /// - Parameters:
    ///   - objMember: The member app.
    ///   - intTile: Its tile.
    private func showGridPicker(for objMember: DockItem, intTile: Int) {
        guard objGrid.blnIsVisible, let objApp = objMember.objRunningApp, !objApp.isTerminated,
              AccessibilityPermission.blnIsTrusted else {
            hidePicker()
            return
        }
        let arrObjWindows = markNew(objWindowService.windows(for: objApp))
        guard !arrObjWindows.isEmpty else {
            hidePicker()
            return
        }
        objPicker.blnLivePreviews = objSettings.blnLivePreviews
        objPicker.blnReduceOnBattery = objSettings.blnReducePreviewsOnBattery
        objPickerApp = objApp
        fnPickerRefresh = { [weak self] in self?.showGridPicker(for: objMember, intTile: intTile) }
        objPicker.show(
            strAppName: objMember.strName,
            objAppIcon: objMember.objIcon,
            arrObjWindows: arrObjWindows,
            intAnchorIndex: Self.gridAnchor(forTile: intTile),
            objAnchorPoint: objGrid.previewAnchor(forTile: intTile, enmPosition: objSettings.enmPosition)
        )
        objPickerPathStart = NSEvent.mouseLocation
        installOutsideClickMonitor()
    }

    /// Hides the picker after a short grace period unless the cursor returns to it or the dock.
    private func scheduleHidePicker() {
        objHidePickerTask?.cancel()
        objHidePickerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objHoverHideDelay)
            guard !Task.isCancelled, let self else { return }
            // Still travelling toward the picker (slowly): don't pull it away.
            await self.waitWhileHeadingToPicker()
            guard !Task.isCancelled else { return }
            if !self.objPicker.blnMouseInside && self.objState.intHoveredIndex == nil && self.intGridHoveredTile == nil {
                self.hidePicker()
                self.updateAutoHide()
            }
        }
    }

    // MARK: - Hover intent

    /// Last cursor point over the picker's own icon (apex of the "safe triangle").
    private var objPickerPathStart: CGPoint?

    /// Extra width on each side of the picker's near edge, for forgiving diagonals.
    private static let fltIntentSlack: CGFloat = 24
    /// Resting this long on another icon means "switch to it" even inside the triangle.
    private static let objIntentRestTime: Duration = .milliseconds(220)
    /// Upper bound on how long intent can hold a switch or hide.
    private static let objIntentMaxWait: Duration = .milliseconds(1200)

    /// Whether the cursor is inside the triangle from where it left the picker's
    /// icon to the picker's near edge — i.e. moving toward the picker (the
    /// "safe triangle" used by good dropdown menus).
    /// - Parameter objPoint: Cursor location in screen coordinates.
    /// - Returns: `true` while heading for the picker.
    private func isHeadingToPicker(_ objPoint: CGPoint) -> Bool {
        guard objPicker.blnIsVisible, let objApex = objPickerPathStart else { return false }
        let objFrame = objPicker.objFrame
        let fltSlack = Self.fltIntentSlack

        // Near-edge corners of the picker, plus the apex nudged back toward the dock edge.
        let (objCornerA, objCornerB, objStart): (CGPoint, CGPoint, CGPoint) = switch objSettings.enmPosition {
        case .bottom:
            (CGPoint(x: objFrame.minX - fltSlack, y: objFrame.minY), CGPoint(x: objFrame.maxX + fltSlack, y: objFrame.minY), CGPoint(x: objApex.x, y: objApex.y - 6))
        case .left:
            (CGPoint(x: objFrame.minX, y: objFrame.minY - fltSlack), CGPoint(x: objFrame.minX, y: objFrame.maxY + fltSlack), CGPoint(x: objApex.x - 6, y: objApex.y))
        case .right:
            (CGPoint(x: objFrame.maxX, y: objFrame.minY - fltSlack), CGPoint(x: objFrame.maxX, y: objFrame.maxY + fltSlack), CGPoint(x: objApex.x + 6, y: objApex.y))
        }
        return Self.triangle(objStart, objCornerA, objCornerB, contains: objPoint)
    }

    /// Waits while the cursor keeps moving toward the picker; returns once it
    /// leaves the triangle, rests in place, enters the picker, or time runs out.
    private func waitWhileHeadingToPicker() async {
        let objDeadline = ContinuousClock.now + Self.objIntentMaxWait
        var objLastPoint = NSEvent.mouseLocation
        var objLastMove = ContinuousClock.now

        while !Task.isCancelled, ContinuousClock.now < objDeadline {
            let objPoint = NSEvent.mouseLocation
            guard !objPicker.blnMouseInside, isHeadingToPicker(objPoint) else { return }
            if hypot(objPoint.x - objLastPoint.x, objPoint.y - objLastPoint.y) > 1 {
                objLastPoint = objPoint
                objLastMove = .now
            } else if ContinuousClock.now - objLastMove >= Self.objIntentRestTime {
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Point-in-triangle test (sign of the cross products).
    /// - Parameters:
    ///   - objA: First vertex.
    ///   - objB: Second vertex.
    ///   - objC: Third vertex.
    ///   - objPoint: Point to test.
    /// - Returns: `true` if the point is inside or on an edge.
    private static func triangle(_ objA: CGPoint, _ objB: CGPoint, _ objC: CGPoint, contains objPoint: CGPoint) -> Bool {
        /// Cross product sign of (q - p) × (r - p).
        func cross(_ objP: CGPoint, _ objQ: CGPoint, _ objR: CGPoint) -> CGFloat {
            (objQ.x - objP.x) * (objR.y - objP.y) - (objQ.y - objP.y) * (objR.x - objP.x)
        }
        let fltD1 = cross(objA, objB, objPoint)
        let fltD2 = cross(objB, objC, objPoint)
        let fltD3 = cross(objC, objA, objPoint)
        let blnHasNegative = fltD1 < 0 || fltD2 < 0 || fltD3 < 0
        let blnHasPositive = fltD1 > 0 || fltD2 > 0 || fltD3 > 0
        return !(blnHasNegative && blnHasPositive)
    }

    /// Hides the picker immediately and cancels pending hover work.
    private func hidePicker() {
        objShowPickerTask?.cancel()
        objHidePickerTask?.cancel()
        objPicker.hide()
        objPickerPathStart = nil
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

    /// Debug aid: shows the "about to make a group" state on an app, as if another
    /// app were held over it (pending first, then armed).
    /// - Parameter intIndex: Target app index.
    func debugPreviewGroup(atIndex intIndex: Int) {
        // An out-of-range drag index means no real icon is lifted.
        objState.objDrag = DockDrag(intIndex: objTracker.arrObjItems.count, intTargetSlot: 0, blnOutside: false)
        objState.intGroupPending = intIndex
        Task { [weak self] in
            try? await Task.sleep(for: Self.objGroupDwell)
            self?.objState.objDrag?.intDropTarget = intIndex
        }
    }

    /// Debug aid: opens the grid of a group or folder stack.
    /// - Parameter intIndex: Dock item index.
    func debugToggleGrid(atIndex intIndex: Int) {
        toggleGrid(forIndex: intIndex)
    }

    /// Debug aid: previews a group member's windows as if its tile were hovered.
    /// - Parameter intTile: Tile in the open group popover.
    func debugPreviewGridTile(_ intTile: Int) {
        guard let objMember = arrObjGridMembers[safe: intTile] else { return }
        showGridPicker(for: objMember, intTile: intTile)
    }

    /// Debug aid: shows a reorder drag in the open group popover.
    /// - Parameters:
    ///   - intFrom: Lifted tile.
    ///   - intTo: Landing spot.
    func debugReorderGrid(from intFrom: Int, to intTo: Int) {
        objGrid.debugReorder(from: intFrom, to: intTo)
    }

    /// Debug aid: starts renaming the open group popover's title.
    func debugEditGridTitle() {
        objGrid.debugBeginTitleEditing()
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
