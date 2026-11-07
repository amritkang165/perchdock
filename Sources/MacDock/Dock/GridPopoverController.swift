import AppKit
import SwiftUI
import Observation

/// One tile in a grid popover (a grouped app or a file in a folder stack).
struct GridEntry: Identifiable {
    let id: String
    let strName: String
    let objIcon: NSImage
    /// Shows a running dot (grouped apps).
    var blnIsRunning = false
    /// File behind the tile, for drag-out (folder stacks).
    var objFileUrl: URL? = nil
}

/// Fixed grid metrics shared by drawing and hit-testing.
enum GridPopoverLayout {
    static let fltTileWidth: CGFloat = 86
    static let fltTileHeight: CGFloat = 92
    static let fltIconSize: CGFloat = 52
    static let fltPadding: CGFloat = 10
    static let fltHeaderHeight: CGFloat = 28
    static let fltFooterHeight: CGFloat = 30
    static let intMaxColumns = 5

    /// Columns for a number of tiles.
    /// - Parameter intCount: Tiles.
    /// - Returns: Column count (at least 1).
    static func columns(forCount intCount: Int) -> Int {
        max(1, min(intCount, intMaxColumns))
    }

    /// Popover size.
    /// - Parameters:
    ///   - intCount: Tiles.
    ///   - blnFooter: Whether a footer button row is shown.
    /// - Returns: Size in points.
    static func size(forCount intCount: Int, blnFooter: Bool) -> CGSize {
        let intColumns = columns(forCount: intCount)
        let intRows = max(1, Int(ceil(Double(max(intCount, 1)) / Double(intColumns))))
        return CGSize(
            width: max(CGFloat(intColumns) * fltTileWidth + fltPadding * 2, 200),
            height: fltHeaderHeight + CGFloat(intRows) * fltTileHeight + fltPadding * 2 + (blnFooter ? fltFooterHeight : 0)
        )
    }

    /// What a point (top-left origin) is over.
    enum Hit: Equatable {
        case title
        case tile(Int)
        case footer
    }

    /// Hit-tests a point.
    /// - Parameters:
    ///   - objPoint: Point with top-left origin.
    ///   - intCount: Tiles.
    ///   - blnFooter: Whether there's a footer.
    /// - Returns: What's under the point, or `nil`.
    static func hit(at objPoint: CGPoint, intCount: Int, blnFooter: Bool) -> Hit? {
        let objSize = size(forCount: intCount, blnFooter: blnFooter)
        if blnFooter && objPoint.y > objSize.height - fltFooterHeight - fltPadding / 2 {
            return .footer
        }
        if objPoint.y < fltHeaderHeight + fltPadding / 2 {
            return .title
        }
        let intColumns = columns(forCount: intCount)
        // Center the grid when the minimum width is wider than the tiles.
        let fltGridStart = (objSize.width - CGFloat(intColumns) * fltTileWidth) / 2
        let fltX = objPoint.x - fltGridStart
        let fltY = objPoint.y - fltHeaderHeight - fltPadding
        guard fltX >= 0, fltY >= 0 else { return nil }
        let intColumn = Int(fltX / fltTileWidth)
        let intRow = Int(fltY / fltTileHeight)
        guard intColumn < intColumns else { return nil }
        let intIndex = intRow * intColumns + intColumn
        return intIndex < intCount ? .tile(intIndex) : nil
    }
}

/// Grid popover contents.
@MainActor
@Observable
final class GridPopoverState {
    var strTitle = ""
    var arrObjEntries: [GridEntry] = []
    var strFooter: String?
    var strEmptyText = "Empty"
    /// Light color wash (a group's color), or `nil`.
    var objTint: Color?
    var objHovered: GridPopoverLayout.Hit?
    /// Whether clicking the title renames it (groups, not folders).
    var blnTitleEditable = false
    /// Whether the title is being renamed inline.
    var blnEditingTitle = false
    /// Name being typed while renaming.
    var strDraftTitle = ""
    /// Return pressed in the rename field.
    @ObservationIgnored var fnCommitTitle: (() -> Void)?
    /// Escape pressed in the rename field.
    @ObservationIgnored var fnCancelTitle: (() -> Void)?
}

/// Grid of tiles in a glass card.
struct GridPopoverView: View {
    @Bindable var objState: GridPopoverState
    @FocusState private var blnTitleFocused: Bool

    var body: some View {
        let arrObjEntries = objState.arrObjEntries
        let intColumns = GridPopoverLayout.columns(forCount: arrObjEntries.count)
        let arrObjColumns = Array(repeating: GridItem(.fixed(GridPopoverLayout.fltTileWidth), spacing: 0), count: intColumns)

        VStack(spacing: 0) {
            Group {
                if objState.blnEditingTitle {
                    titleField
                } else {
                    titleLabel
                }
            }
            .frame(height: GridPopoverLayout.fltHeaderHeight)
            .padding(.top, GridPopoverLayout.fltPadding / 2)

            if arrObjEntries.isEmpty {
                Text(objState.strEmptyText)
                    .foregroundStyle(.secondary)
                    .frame(height: GridPopoverLayout.fltTileHeight)
            } else {
                LazyVGrid(columns: arrObjColumns, spacing: 0) {
                    ForEach(Array(arrObjEntries.enumerated()), id: \.element.id) { intIndex, objEntry in
                        tile(objEntry, blnHovered: objState.objHovered == .tile(intIndex))
                    }
                }
            }

            if let strFooter = objState.strFooter {
                Text(strFooter)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(
                        Capsule().fill(Color.primary.opacity(objState.objHovered == .footer ? 0.18 : 0.08))
                    )
                    .frame(height: GridPopoverLayout.fltFooterHeight)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, GridPopoverLayout.fltPadding / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dockGlass(cornerRadius: 16, tint: objState.objTint)
    }

    /// The title; editable titles hint on hover with a pill and a pencil.
    private var titleLabel: some View {
        let blnTitleHovered = objState.blnTitleEditable && objState.objHovered == .title
        return HStack(spacing: 4) {
            Text(objState.strTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if blnTitleHovered {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(blnTitleHovered ? 0.1 : 0)))
    }

    /// Inline rename field: Return saves, Escape cancels.
    private var titleField: some View {
        TextField("Group Name", text: $objState.strDraftTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .focused($blnTitleFocused)
            .padding(.horizontal, 8)
            .frame(width: 200, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
            )
            .onSubmit { objState.fnCommitTitle?() }
            .onExitCommand { objState.fnCancelTitle?() }
            // Focus once the panel has become key.
            .onAppear { blnTitleFocused = true }
    }

    /// One tile: icon, name, and a running dot.
    /// - Parameters:
    ///   - objEntry: Tile data.
    ///   - blnHovered: Whether to highlight it.
    /// - Returns: The tile view.
    private func tile(_ objEntry: GridEntry, blnHovered: Bool) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: objEntry.objIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: GridPopoverLayout.fltIconSize, height: GridPopoverLayout.fltIconSize)
                .scaleEffect(blnHovered ? 1.08 : 1)
            Text(objEntry.strName)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: GridPopoverLayout.fltTileWidth - 10, height: 28, alignment: .top)
            Circle()
                .fill(Color.primary.opacity(0.6))
                .frame(width: 4, height: 4)
                .opacity(objEntry.blnIsRunning ? 1 : 0)
        }
        .frame(width: GridPopoverLayout.fltTileWidth, height: GridPopoverLayout.fltTileHeight)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(blnHovered ? 0.1 : 0))
        )
    }
}

/// Shows a group's apps or a folder's files as a grid above their dock icon.
/// Stays open until a tile is chosen, the user clicks elsewhere, or presses Escape.
@MainActor
final class GridPopoverController: NSObject, NSDraggingSource {
    private let objState = GridPopoverState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<GridPopoverView>
    private var objOutsideMonitor: Any?
    private var objKeyMonitor: Any?
    private var objPressPoint: CGPoint?
    private var blnDragStarted = false

    /// Dock item the popover belongs to.
    private(set) var strAnchorId: String?

    /// Whether it's on screen.
    var blnIsVisible: Bool { strAnchorId != nil }

    /// Tile chosen.
    var onSelect: ((Int) -> Void)?
    /// Tile right-clicked (for a per-tile menu).
    var onRightClick: ((Int, NSEvent) -> Void)?
    /// Footer button pressed.
    var onFooter: (() -> Void)?
    /// Popover closed.
    var onHide: (() -> Void)?
    /// Hovered tile changed (`nil` when off the tiles), e.g. to preview an app's windows.
    var onHoverTile: ((Int?) -> Void)?
    /// Title edited inline; set to make the title clickable (groups).
    var onRename: ((String) -> Void)? {
        didSet { objState.blnTitleEditable = onRename != nil }
    }

    /// App that was frontmost before the field took the keyboard (gets it back after).
    private var objPreviousApp: NSRunningApplication?

    override init() {
        objPanel = DockPanel(contentRect: .zero)
        objHostingView = TrackingHostingView(rootView: GridPopoverView(objState: objState))
        super.init()
        objPanel.contentView = objHostingView
        objState.fnCommitTitle = { [weak self] in self?.endTitleEditing(blnCommit: true) }
        objState.fnCancelTitle = { [weak self] in self?.endTitleEditing(blnCommit: false) }

        objHostingView.onMouseMoved = { [weak self] objPoint in
            self?.updateHover(objPoint)
        }
        objHostingView.onMouseExited = { [weak self] in
            guard let self else { return }
            let blnWasTile = self.intHoveredTile != nil
            self.objState.objHovered = nil
            if blnWasTile { self.onHoverTile?(nil) }
        }
        objHostingView.onMouseDown = { [weak self] objPoint in
            self?.objPressPoint = objPoint
            self?.blnDragStarted = false
        }
        objHostingView.onMouseDragged = { [weak self] objPoint in
            self?.handleDrag(objPoint)
        }
        objHostingView.onMouseUp = { [weak self] objPoint in
            self?.handleClick(objPoint)
        }
        objHostingView.onRightMouseDown = { [weak self] objPoint, objEvent in
            guard let self, case .tile(let intIndex)? = self.hit(objPoint) else { return }
            self.onRightClick?(intIndex, objEvent)
        }
    }

    /// Shows the popover above (or beside) a dock icon.
    /// - Parameters:
    ///   - strTitle: Header.
    ///   - arrObjEntries: Tiles.
    ///   - strFooter: Optional footer button title.
    ///   - strAnchorId: Dock item ID (used to toggle on a second click).
    ///   - objAnchorPoint: Screen point on the icon's outer edge.
    ///   - enmPosition: Dock edge.
    ///   - objTint: Optional color wash.
    func show(strTitle: String, arrObjEntries: [GridEntry], strFooter: String?, strAnchorId: String,
              objAnchorPoint: CGPoint, enmPosition: DockPosition, objTint: Color? = nil) {
        objState.strTitle = strTitle
        objState.objTint = objTint
        objState.arrObjEntries = arrObjEntries
        objState.strFooter = strFooter
        objState.objHovered = nil
        let blnWasVisible = blnIsVisible
        self.strAnchorId = strAnchorId

        let objSize = GridPopoverLayout.size(forCount: arrObjEntries.count, blnFooter: strFooter != nil)
        let objFrame = Self.frame(forSize: objSize, objAnchorPoint: objAnchorPoint, enmPosition: enmPosition)
        let objOffset: CGVector = switch enmPosition {
        case .bottom: CGVector(dx: 0, dy: -8)
        case .left: CGVector(dx: -8, dy: 0)
        case .right: CGVector(dx: 8, dy: 0)
        }

        if !blnWasVisible {
            objPanel.setFrame(objFrame.offsetBy(dx: objOffset.dx, dy: objOffset.dy), display: false)
            objPanel.alphaValue = 0
            objPanel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.16
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(objFrame, display: true)
            objPanel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// Updates the tiles in place (e.g. a member was removed).
    /// - Parameter arrObjEntries: New tiles.
    func update(arrObjEntries: [GridEntry]) {
        objState.arrObjEntries = arrObjEntries
        let objSize = GridPopoverLayout.size(forCount: arrObjEntries.count, blnFooter: objState.strFooter != nil)
        var objFrame = objPanel.frame
        objFrame.origin.x += (objFrame.width - objSize.width) / 2
        objFrame.size = objSize
        objPanel.setFrame(objFrame, display: true)
    }

    /// Fades the popover out.
    func hide() {
        guard blnIsVisible else { return }
        strAnchorId = nil
        // Clicking away while renaming keeps the new name, like Finder.
        endTitleEditing(blnCommit: true)
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.1
            objPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.blnIsVisible else { return }
                self.objPanel.orderOut(nil)
            }
        })
        onHide?()
    }

    /// Whether a screen point is inside the popover.
    /// - Parameter objScreenPoint: Point in screen coordinates.
    /// - Returns: `true` when inside.
    func contains(_ objScreenPoint: CGPoint) -> Bool {
        blnIsVisible && objPanel.frame.contains(objScreenPoint)
    }

    // MARK: - Layout

    /// Frame next to the icon, clamped to the screen.
    /// - Parameters:
    ///   - objSize: Popover size.
    ///   - objAnchorPoint: Icon's outer edge.
    ///   - enmPosition: Dock edge.
    /// - Returns: Frame in screen coordinates.
    private static func frame(forSize objSize: CGSize, objAnchorPoint: CGPoint, enmPosition: DockPosition) -> NSRect {
        let fltGap: CGFloat = 8
        var objOrigin: CGPoint = switch enmPosition {
        case .bottom: CGPoint(x: objAnchorPoint.x - objSize.width / 2, y: objAnchorPoint.y + fltGap)
        case .left: CGPoint(x: objAnchorPoint.x + fltGap, y: objAnchorPoint.y - objSize.height / 2)
        case .right: CGPoint(x: objAnchorPoint.x - fltGap - objSize.width, y: objAnchorPoint.y - objSize.height / 2)
        }
        if let objScreen = NSScreen.screens.first(where: { $0.frame.contains(objAnchorPoint) }) ?? NSScreen.main {
            let objBounds = objScreen.visibleFrame.insetBy(dx: 8, dy: 8)
            objOrigin.x = min(max(objOrigin.x, objBounds.minX), objBounds.maxX - objSize.width)
            objOrigin.y = min(max(objOrigin.y, objBounds.minY), objBounds.maxY - objSize.height)
        }
        return NSRect(x: objOrigin.x.rounded(), y: objOrigin.y.rounded(), width: objSize.width, height: objSize.height)
    }

    // MARK: - Mouse

    /// Hit-tests a panel point (bottom-left origin).
    /// - Parameter objPoint: Panel point.
    /// - Returns: What's under it.
    private func hit(_ objPoint: CGPoint) -> GridPopoverLayout.Hit? {
        let objTopLeft = CGPoint(x: objPoint.x, y: objPanel.frame.height - objPoint.y)
        return GridPopoverLayout.hit(at: objTopLeft, intCount: objState.arrObjEntries.count, blnFooter: objState.strFooter != nil)
    }

    /// Highlights the tile under the cursor.
    /// - Parameter objPoint: Panel point.
    private func updateHover(_ objPoint: CGPoint) {
        let objHit = hit(objPoint)
        guard objHit != objState.objHovered else { return }
        let intOldTile = intHoveredTile
        withAnimation(.easeOut(duration: 0.1)) {
            objState.objHovered = objHit
        }
        if intHoveredTile != intOldTile {
            onHoverTile?(intHoveredTile)
        }
    }

    /// Tile under the cursor, if any.
    var intHoveredTile: Int? {
        if case .tile(let intIndex)? = objState.objHovered { return intIndex }
        return nil
    }

    /// Screen frame of the popover.
    var objFrame: NSRect { objPanel.frame }

    /// Where a window picker for a tile should attach: on the popover's outer edge
    /// (away from the dock), lined up with the tile.
    /// - Parameters:
    ///   - intIndex: Tile index.
    ///   - enmPosition: Dock edge.
    /// - Returns: Screen point.
    func previewAnchor(forTile intIndex: Int, enmPosition: DockPosition) -> CGPoint {
        let objPanelFrame = objPanel.frame
        let intCount = objState.arrObjEntries.count
        let intColumns = GridPopoverLayout.columns(forCount: intCount)
        let fltGridStart = (objPanelFrame.width - CGFloat(intColumns) * GridPopoverLayout.fltTileWidth) / 2
        let fltTileMidX = objPanelFrame.minX + fltGridStart + (CGFloat(intIndex % intColumns) + 0.5) * GridPopoverLayout.fltTileWidth
        // Rows count down from the top (below the header).
        let fltTileMidY = objPanelFrame.maxY - GridPopoverLayout.fltPadding - GridPopoverLayout.fltHeaderHeight
            - (CGFloat(intIndex / intColumns) + 0.5) * GridPopoverLayout.fltTileHeight
        return switch enmPosition {
        case .bottom: CGPoint(x: fltTileMidX, y: objPanelFrame.maxY)
        case .left: CGPoint(x: objPanelFrame.maxX, y: fltTileMidY)
        case .right: CGPoint(x: objPanelFrame.minX, y: fltTileMidY)
        }
    }

    /// Fires the action for a click (unless the press turned into a drag-out).
    /// - Parameter objPoint: Panel point.
    private func handleClick(_ objPoint: CGPoint) {
        defer { objPressPoint = nil }
        guard !blnDragStarted else { return }
        let objHit = hit(objPoint)
        // Clicking anywhere else in the popover finishes a rename.
        if objHit != .title {
            endTitleEditing(blnCommit: true)
        }
        switch objHit {
        case .title where onRename != nil: beginTitleEditing()
        case .tile(let intIndex): onSelect?(intIndex)
        case .footer: onFooter?()
        case .title, nil: break
        }
    }

    // MARK: - Inline rename

    /// Swaps the title for a text field and gives the popover the keyboard.
    private func beginTitleEditing() {
        guard !objState.blnEditingTitle else { return }

        // Typing needs a key window, which needs MacDock active for a moment.
        objPreviousApp = NSWorkspace.shared.frontmostApplication
        objPanel.blnAllowsKey = true
        NSApp.activate()
        objPanel.makeKey()

        objState.strDraftTitle = objState.strTitle
        objState.blnEditingTitle = true
    }

    /// Debug aid: starts renaming as if the title were clicked.
    func debugBeginTitleEditing() {
        beginTitleEditing()
    }

    /// Ends renaming, saves (if asked and changed), and hands the keyboard back.
    /// - Parameter blnCommit: Whether to keep the typed name.
    private func endTitleEditing(blnCommit: Bool) {
        guard objState.blnEditingTitle else { return }
        objState.blnEditingTitle = false
        let strName = objState.strDraftTitle.trimmingCharacters(in: .whitespaces)

        if blnCommit, !strName.isEmpty, strName != objState.strTitle {
            objState.strTitle = strName
            onRename?(strName)
        }

        objPanel.blnAllowsKey = false
        objPanel.resignKey()
        // Give focus back to whatever the user was using.
        if let objPreviousApp, objPreviousApp != NSRunningApplication.current {
            objPreviousApp.activate()
        }
        objPreviousApp = nil
    }

    /// Starts dragging a file out of a folder stack (to Finder, Mail, …).
    /// - Parameter objPoint: Panel point.
    private func handleDrag(_ objPoint: CGPoint) {
        guard !blnDragStarted, let objPressPoint,
              hypot(objPoint.x - objPressPoint.x, objPoint.y - objPressPoint.y) > 4,
              case .tile(let intIndex)? = hit(objPressPoint),
              let objEntry = objState.arrObjEntries[safe: intIndex],
              let objFileUrl = objEntry.objFileUrl,
              let objEvent = objHostingView.objLastMouseDown else { return }
        blnDragStarted = true

        let objItem = NSDraggingItem(pasteboardWriter: objFileUrl as NSURL)
        let fltIcon = GridPopoverLayout.fltIconSize
        objItem.setDraggingFrame(NSRect(x: objPressPoint.x - fltIcon / 2, y: objPressPoint.y - fltIcon / 2, width: fltIcon, height: fltIcon),
                                 contents: objEntry.objIcon)
        objHostingView.beginDraggingSession(with: [objItem], event: objEvent, source: self)
    }

    /// Files can be copied, moved or linked by the drop target.
    /// - Parameters:
    ///   - session: Drag session.
    ///   - context: Inside or outside the app.
    /// - Returns: Allowed operations.
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    /// Closes the popover once a file has been dropped somewhere.
    /// - Parameters:
    ///   - session: Drag session.
    ///   - screenPoint: Drop point.
    ///   - operation: Performed operation.
    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            if operation != [] { hide() }
        }
    }

    // MARK: - Dismissal

    /// Closes on clicks in other apps and on Escape.
    private func installMonitors() {
        if objOutsideMonitor == nil {
            objOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        if objKeyMonitor == nil {
            // Global key monitoring needs Accessibility, which MacDock already has.
            objKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] objEvent in
                guard objEvent.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    /// Removes dismissal monitors.
    private func removeMonitors() {
        for objMonitor in [objOutsideMonitor, objKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(objMonitor)
        }
        objOutsideMonitor = nil
        objKeyMonitor = nil
    }
}
