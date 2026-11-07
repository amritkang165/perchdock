import CoreGraphics
import Foundation

/// All dock measurements for the current settings, shared by drawing and hit-testing.
///
/// Positions are expressed on two axes so one implementation serves every edge:
/// - **main**: along the bar (left→right for bottom, top→bottom for left/right),
///   measured from the panel's leading edge;
/// - **cross**: away from the screen edge, 0 at the panel's screen-side edge.
///
/// Items have their own base widths: icons use the icon size, dividers are thin
/// and never magnify.
///
/// The panel is wider than the bar by `fltSideMargin` on each end so magnified
/// icons have room to spread; clicks there pass through to windows below.
struct DockGeometry {
    let enmPosition: DockPosition
    let fltIconSize: CGFloat
    let fltMagnification: CGFloat
    let blnCompact: Bool
    let intCount: Int
    /// Which items are dividers (thin, not magnified).
    let arrBlnDivider: [Bool]
    /// Which items are wide tiles (the large Now Playing widget: fixed width, not magnified).
    let arrBlnWide: [Bool]

    static let fltIndicatorSize: CGFloat = 5
    static let fltScreenGap: CGFloat = 4
    /// How many icon slots on each side of the cursor magnification reaches.
    static let fltInfluenceRadius: CGFloat = 3

    /// Item centers and sizes along the main axis, plus the bar's extent.
    struct Layout {
        var arrFltCenters: [CGFloat]
        var arrFltSizes: [CGFloat]
        var fltBarStart: CGFloat
        var fltBarEnd: CGFloat
    }

    /// Builds geometry from settings and the current items.
    /// - Parameters:
    ///   - objSettings: User preferences.
    ///   - arrObjItems: Dock items in display order.
    @MainActor
    init(objSettings: SettingsStore, arrObjItems: [DockItem]) {
        enmPosition = objSettings.enmPosition
        fltIconSize = CGFloat(objSettings.fltIconSize)
        fltMagnification = CGFloat(objSettings.fltEffectiveMagnification)
        blnCompact = objSettings.blnCompact
        intCount = arrObjItems.count
        arrBlnDivider = arrObjItems.map(\.blnIsDivider)
        let blnLarge = objSettings.blnUsesLargeNowPlaying
        arrBlnWide = arrObjItems.map { blnLarge && $0.enmWidget == .nowPlaying }
    }

    // MARK: - Dimensions

    private var fltSpacingRatio: CGFloat { blnCompact ? 0.06 : 0.15 }
    var fltSpacing: CGFloat { (fltIconSize * fltSpacingRatio).rounded() }
    var fltPadding: CGFloat { (fltIconSize * (blnCompact ? 0.08 : 0.15)).rounded() }
    /// Icon slot (icon plus gap), the unit for magnification falloff.
    var fltSlot: CGFloat { fltIconSize + fltSpacing }
    var fltCornerRadius: CGFloat { min(22, fltBarThickness * 0.32) }

    /// Width of a divider item (the line sits in its middle).
    var fltDividerWidth: CGFloat { max(6, (fltIconSize * 0.3).rounded()) }

    /// Base (un-magnified) width of an item.
    /// - Parameter intIndex: Item index.
    /// - Returns: Width along the main axis.
    func baseWidth(_ intIndex: Int) -> CGFloat {
        guard arrBlnDivider.indices.contains(intIndex) else { return fltIconSize }
        if arrBlnDivider[intIndex] { return fltDividerWidth }
        if arrBlnWide[intIndex] { return fltWideWidth }
        return fltIconSize
    }

    /// Length along the bar of a wide tile (the large Now Playing widget; tall on side docks).
    var fltWideWidth: CGFloat { nowPlayingLayout.fltMainLength }

    /// Layout of the large Now Playing tile for this dock's size and orientation.
    var nowPlayingLayout: NowPlayingLargeLayout {
        NowPlayingLargeLayout(fltIconSize: fltIconSize, blnVertical: enmPosition.blnIsVertical)
    }

    /// Whether an item keeps its size under the cursor (dividers and wide tiles).
    /// - Parameter intIndex: Item index.
    /// - Returns: `true` if it never magnifies.
    func isFixedSize(_ intIndex: Int) -> Bool {
        arrBlnDivider.indices.contains(intIndex) && (arrBlnDivider[intIndex] || arrBlnWide[intIndex])
    }

    /// Bar thickness: padding, running indicator, icon, padding.
    var fltBarThickness: CGFloat { fltPadding * 2 + Self.fltIndicatorSize + fltIconSize }

    /// Bar length with no magnification.
    var fltBaseLength: CGFloat {
        guard intCount > 0 else { return fltIconSize + fltPadding * 2 }
        let fltWidths = (0..<intCount).reduce(0) { $0 + baseWidth($1) }
        return fltWidths + CGFloat(intCount - 1) * fltSpacing + fltPadding * 2
    }

    /// Largest total growth magnification can add (cosine falloff sums to ~3 icons).
    var fltMaxExtra: CGFloat { fltIconSize * (fltMagnification - 1) * Self.fltInfluenceRadius }

    /// Transparent room at each end of the bar for magnified icons to spread into.
    var fltSideMargin: CGFloat { ceil(fltMaxExtra) + 2 }

    var fltPanelLength: CGFloat { fltBaseLength + fltSideMargin * 2 }

    /// How high a bouncing icon jumps (launching, or a new notification).
    var fltBounceHeight: CGFloat { (fltIconSize * 0.45).rounded() }

    /// Interactive thickness: the bar plus headroom for the tallest magnified icon.
    /// Only this part catches the mouse; the rest of the panel is click-through.
    var fltHoverThickness: CGFloat { fltBarThickness + ceil(fltIconSize * (fltMagnification - 1)) + 4 }

    /// Panel thickness: room for magnified icons and for bounces.
    var fltPanelThickness: CGFloat { max(fltHoverThickness, fltBarThickness + fltBounceHeight + 4) }

    /// Panel size in screen orientation.
    var objPanelSize: CGSize {
        enmPosition.blnIsVertical
            ? CGSize(width: fltPanelThickness, height: fltPanelLength)
            : CGSize(width: fltPanelLength, height: fltPanelThickness)
    }

    /// Cross position of an icon's center, given its current size.
    /// - Parameter fltSize: Icon size.
    /// - Returns: Cross coordinate.
    func iconCross(forSize fltSize: CGFloat) -> CGFloat {
        fltPadding + Self.fltIndicatorSize + fltSize / 2
    }

    /// Cross position of the running indicator.
    var fltIndicatorCross: CGFloat { fltPadding * 0.5 + Self.fltIndicatorSize * 0.5 }

    // MARK: - Base slots

    /// Leading edge of the un-magnified bar.
    var fltBarStart: CGFloat { fltSideMargin }

    /// Centers for a sequence of item widths laid end to end from the bar start.
    /// - Parameter arrFltWidths: Widths in order.
    /// - Returns: Centers.
    private func centers(forWidths arrFltWidths: [CGFloat]) -> [CGFloat] {
        var fltCursor = fltBarStart + fltPadding
        return arrFltWidths.map { fltWidth in
            defer { fltCursor += fltWidth + fltSpacing }
            return fltCursor + fltWidth / 2
        }
    }

    /// Center of item `intIndex` with no magnification.
    /// - Parameter intIndex: Item index.
    /// - Returns: Main coordinate.
    func baseCenter(_ intIndex: Int) -> CGFloat {
        var fltCursor = fltBarStart + fltPadding
        for intPrevious in 0..<min(intIndex, intCount) {
            fltCursor += baseWidth(intPrevious) + fltSpacing
        }
        return fltCursor + baseWidth(intIndex) / 2
    }

    /// Item under a main coordinate. Gaps are split between neighbors so sweeping
    /// across the bar never hits a dead zone. Because magnification keeps the
    /// cursor's point fixed, base slots also identify the magnified icon.
    /// - Parameter fltMain: Main coordinate.
    /// - Returns: Item index or `nil`.
    func slotIndex(atMain fltMain: CGFloat) -> Int? {
        var fltSlotStart = fltBarStart + fltPadding - fltSpacing / 2
        guard fltMain >= fltSlotStart else { return nil }
        for intIndex in 0..<intCount {
            let fltSlotEnd = fltSlotStart + baseWidth(intIndex) + fltSpacing
            if fltMain < fltSlotEnd { return intIndex }
            fltSlotStart = fltSlotEnd
        }
        return nil
    }

    /// Slot a dragged item would land in: how many of the other items sit before
    /// the cursor once the dragged one is lifted out.
    /// - Parameters:
    ///   - fltMain: Main coordinate.
    ///   - intDragIndex: Item being dragged.
    /// - Returns: Slot index in `0..<intCount`.
    func dropSlot(atMain fltMain: CGFloat, intDragIndex: Int) -> Int {
        let arrIntOthers = (0..<intCount).filter { $0 != intDragIndex }
        let arrFltCenters = centers(forWidths: arrIntOthers.map(baseWidth))
        return arrFltCenters.filter { $0 < fltMain }.count
    }

    // MARK: - Layouts

    /// Layout with magnification around the cursor.
    ///
    /// Each icon grows by a cosine falloff of its distance to the cursor. Growth
    /// is distributed so the point under the cursor stays put: icons before it
    /// push toward the start, icons after it toward the end.
    /// - Parameter fltMouseMain: Cursor main coordinate, or `nil` when not hovering.
    /// - Returns: Item centers/sizes and bar extent.
    func layout(mouseMain fltMouseMain: CGFloat?) -> Layout {
        let arrFltBaseWidths = (0..<intCount).map(baseWidth)
        let arrFltBaseCenters = centers(forWidths: arrFltBaseWidths)
        var arrFltSizes = arrFltBaseWidths

        if let fltMouseMain, fltMagnification > 1.001 {
            for intIndex in 0..<intCount where !isFixedSize(intIndex) {
                let fltDistance = abs(fltMouseMain - arrFltBaseCenters[intIndex]) / fltSlot
                guard fltDistance < Self.fltInfluenceRadius else { continue }
                let fltFalloff = (cos(.pi * fltDistance / Self.fltInfluenceRadius) + 1) / 2
                arrFltSizes[intIndex] = fltIconSize * (1 + (fltMagnification - 1) * fltFalloff)
            }
        }

        let arrFltExtras = zip(arrFltSizes, arrFltBaseWidths).map { $0 - $1 }

        // How far the cursor's point would move if everything grew to the right;
        // subtracting it pins that point in place.
        var fltShift: CGFloat = 0
        if let fltMouseMain {
            for intIndex in 0..<intCount {
                let fltSlotWidth = arrFltBaseWidths[intIndex] + fltSpacing
                let fltSlotStart = arrFltBaseCenters[intIndex] - fltSlotWidth / 2
                let fltSlotEnd = fltSlotStart + fltSlotWidth
                if fltMouseMain >= fltSlotEnd {
                    fltShift += arrFltExtras[intIndex]
                } else if fltMouseMain > fltSlotStart {
                    fltShift += arrFltExtras[intIndex] * (fltMouseMain - fltSlotStart) / fltSlotWidth
                }
            }
        }

        var arrFltCenters: [CGFloat] = []
        var fltCumulative: CGFloat = 0
        for intIndex in 0..<intCount {
            arrFltCenters.append(arrFltBaseCenters[intIndex] + fltCumulative + arrFltExtras[intIndex] / 2 - fltShift)
            fltCumulative += arrFltExtras[intIndex]
        }

        return Layout(
            arrFltCenters: arrFltCenters,
            arrFltSizes: arrFltSizes,
            fltBarStart: fltBarStart - fltShift,
            fltBarEnd: fltBarStart + fltBaseLength + fltCumulative - fltShift
        )
    }

    /// Layout while an item is being dragged: the others slide apart to open a gap
    /// at the target slot (or close up when it's dragged off to be removed).
    /// - Parameter objDrag: Current drag.
    /// - Returns: Item centers/sizes and bar extent.
    func layout(dragging objDrag: DockDrag) -> Layout {
        // Reordered sequence: others in order, dragged one at its target slot.
        var arrIntOrder = (0..<intCount).filter { $0 != objDrag.intIndex }
        if objDrag.intIndex < intCount {
            arrIntOrder.insert(objDrag.intIndex, at: min(objDrag.intTargetSlot, arrIntOrder.count))
        }

        // When dragged outside, the dragged item takes no room.
        let arrFltWidths = arrIntOrder.map { intIndex in
            objDrag.blnOutside && intIndex == objDrag.intIndex ? -fltSpacing : baseWidth(intIndex)
        }
        let arrFltOrderedCenters = centers(forWidths: arrFltWidths)

        var arrFltCenters = Array(repeating: 0 as CGFloat, count: intCount)
        for (intPosition, intIndex) in arrIntOrder.enumerated() {
            arrFltCenters[intIndex] = arrFltOrderedCenters[intPosition]
        }

        return Layout(
            arrFltCenters: arrFltCenters,
            arrFltSizes: (0..<intCount).map(baseWidth),
            fltBarStart: fltBarStart,
            fltBarEnd: fltBarStart + fltBaseLength
        )
    }

    // MARK: - Coordinate conversion

    /// Converts a panel point (bottom-left origin) to main/cross coordinates.
    /// - Parameter objPoint: Panel-local point.
    /// - Returns: `(main, cross)`.
    func mainCross(fromPanelPoint objPoint: CGPoint) -> (fltMain: CGFloat, fltCross: CGFloat) {
        let objSize = objPanelSize
        switch enmPosition {
        case .bottom: return (objPoint.x, objPoint.y)
        case .left: return (objSize.height - objPoint.y, objPoint.x)
        case .right: return (objSize.height - objPoint.y, objSize.width - objPoint.x)
        }
    }

    /// Converts main/cross coordinates to a panel point (bottom-left origin).
    /// - Parameters:
    ///   - fltMain: Main coordinate.
    ///   - fltCross: Cross coordinate.
    /// - Returns: Panel-local point.
    func panelPoint(main fltMain: CGFloat, cross fltCross: CGFloat) -> CGPoint {
        let objSize = objPanelSize
        switch enmPosition {
        case .bottom: return CGPoint(x: fltMain, y: fltCross)
        case .left: return CGPoint(x: fltCross, y: objSize.height - fltMain)
        case .right: return CGPoint(x: objSize.width - fltCross, y: objSize.height - fltMain)
        }
    }

    /// Converts main/cross coordinates to SwiftUI view coordinates (top-left origin).
    /// - Parameters:
    ///   - fltMain: Main coordinate.
    ///   - fltCross: Cross coordinate.
    /// - Returns: View point.
    func viewPoint(main fltMain: CGFloat, cross fltCross: CGFloat) -> CGPoint {
        let objPoint = panelPoint(main: fltMain, cross: fltCross)
        return CGPoint(x: objPoint.x, y: objPanelSize.height - objPoint.y)
    }

    /// Panel frame on a screen, docked (or tucked away off the edge when hidden).
    /// - Parameters:
    ///   - objScreenFrame: Full frame of the target screen.
    ///   - blnShown: `false` to place it just beyond the screen edge.
    /// - Returns: Frame in screen coordinates.
    func panelFrame(in objScreenFrame: CGRect, blnShown: Bool) -> CGRect {
        let objSize = objPanelSize
        let fltTuck = blnShown ? 0 : fltPanelThickness + Self.fltScreenGap + 2
        switch enmPosition {
        case .bottom:
            return CGRect(
                x: (objScreenFrame.midX - objSize.width / 2).rounded(),
                y: objScreenFrame.minY + Self.fltScreenGap - fltTuck,
                width: objSize.width, height: objSize.height
            )
        case .left:
            return CGRect(
                x: objScreenFrame.minX + Self.fltScreenGap - fltTuck,
                y: (objScreenFrame.midY - objSize.height / 2).rounded(),
                width: objSize.width, height: objSize.height
            )
        case .right:
            return CGRect(
                x: objScreenFrame.maxX - Self.fltScreenGap - objSize.width + fltTuck,
                y: (objScreenFrame.midY - objSize.height / 2).rounded(),
                width: objSize.width, height: objSize.height
            )
        }
    }
}

/// An in-progress item drag inside the dock.
struct DockDrag: Equatable {
    /// Item being dragged.
    let intIndex: Int
    /// Slot the item would land in if released now.
    var intTargetSlot: Int
    /// Dragged far enough off the dock that releasing removes it.
    var blnOutside: Bool
    /// Item the cursor is over that accepts a drop (a group, or the Trash), if any.
    var intDropTarget: Int? = nil
}
