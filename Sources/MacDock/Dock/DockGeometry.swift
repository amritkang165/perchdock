import CoreGraphics
import Foundation

/// All dock measurements for the current settings, shared by drawing and hit-testing.
///
/// Positions are expressed on two axes so one implementation serves every edge:
/// - **main**: along the bar (left→right for bottom, top→bottom for left/right),
///   measured from the panel's leading edge;
/// - **cross**: away from the screen edge, 0 at the panel's screen-side edge.
///
/// The panel is wider than the bar by `fltSideMargin` on each end so magnified
/// icons have room to spread; clicks there pass through to windows below.
struct DockGeometry {
    let enmPosition: DockPosition
    let fltIconSize: CGFloat
    let fltMagnification: CGFloat
    let intCount: Int
    /// Index of the last pinned item when a separator follows it (pinned and
    /// unpinned items both present); `nil` for no separator.
    let intSeparatorAfter: Int?

    static let fltIndicatorSize: CGFloat = 5
    static let fltScreenGap: CGFloat = 4
    /// How many icon slots on each side of the cursor magnification reaches.
    static let fltInfluenceRadius: CGFloat = 3

    /// Icon centers and sizes along the main axis, plus the bar's extent.
    struct Layout {
        var arrFltCenters: [CGFloat]
        var arrFltSizes: [CGFloat]
        var fltBarStart: CGFloat
        var fltBarEnd: CGFloat
    }

    /// Builds geometry from settings and the current items.
    /// - Parameters:
    ///   - objSettings: User preferences.
    ///   - arrObjItems: Dock items in display order (pinned first).
    @MainActor
    init(objSettings: SettingsStore, arrObjItems: [DockItem]) {
        enmPosition = objSettings.enmPosition
        fltIconSize = CGFloat(objSettings.fltIconSize)
        fltMagnification = CGFloat(objSettings.fltEffectiveMagnification)
        intCount = arrObjItems.count

        let intPinnedCount = arrObjItems.filter(\.blnIsPinned).count
        intSeparatorAfter = intPinnedCount > 0 && intPinnedCount < arrObjItems.count ? intPinnedCount - 1 : nil
    }

    // MARK: - Dimensions

    var fltSpacing: CGFloat { (fltIconSize * 0.15).rounded() }
    var fltPadding: CGFloat { (fltIconSize * 0.15).rounded() }
    var fltSlot: CGFloat { fltIconSize + fltSpacing }
    var fltCornerRadius: CGFloat { min(22, fltBarThickness * 0.32) }

    /// Bar thickness: padding, running indicator, icon, padding.
    var fltBarThickness: CGFloat { fltPadding * 2 + Self.fltIndicatorSize + fltIconSize }

    /// Extra room the separator adds between the pinned and running groups.
    var fltSeparatorGap: CGFloat { intSeparatorAfter == nil ? 0 : fltSpacing + 4 }

    /// Bar length with no magnification.
    var fltBaseLength: CGFloat {
        let intSafeCount = max(intCount, 1)
        return CGFloat(intSafeCount) * fltIconSize + CGFloat(intSafeCount - 1) * fltSpacing + fltPadding * 2 + fltSeparatorGap
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

    /// Cross position of the running-indicator dot.
    var fltIndicatorCross: CGFloat { fltPadding * 0.5 + Self.fltIndicatorSize * 0.5 }

    // MARK: - Base slots

    /// Leading edge of the un-magnified bar.
    var fltBarStart: CGFloat { fltSideMargin }

    /// Center of slot `intIndex` with no magnification.
    /// - Parameter intIndex: Item index.
    /// - Returns: Main coordinate.
    func baseCenter(_ intIndex: Int) -> CGFloat {
        let fltGap = intSeparatorAfter.map { intIndex > $0 ? fltSeparatorGap : 0 } ?? 0
        return fltBarStart + fltPadding + CGFloat(intIndex) * fltSlot + fltIconSize / 2 + fltGap
    }

    /// Main coordinate of the separator line with no magnification.
    var fltBaseSeparatorMain: CGFloat? {
        intSeparatorAfter.map { (baseCenter($0) + baseCenter($0 + 1)) / 2 }
    }

    /// Removes the separator gap from a main coordinate, so slot math can treat
    /// the bar as evenly spaced.
    /// - Parameter fltMain: Main coordinate.
    /// - Returns: Coordinate with the gap collapsed.
    private func collapsingSeparator(_ fltMain: CGFloat) -> CGFloat {
        guard let fltSeparator = fltBaseSeparatorMain else { return fltMain }
        if fltMain <= fltSeparator - fltSeparatorGap / 2 { return fltMain }
        if fltMain >= fltSeparator + fltSeparatorGap / 2 { return fltMain - fltSeparatorGap }
        return fltSeparator - fltSeparatorGap / 2
    }

    /// Item under a main coordinate. Gaps are split between neighbors so sweeping
    /// across the bar never hits a dead zone. Because magnification keeps the
    /// cursor's point fixed, base slots also identify the magnified icon.
    /// - Parameter fltMain: Main coordinate.
    /// - Returns: Item index or `nil`.
    func slotIndex(atMain fltMain: CGFloat) -> Int? {
        let fltRelative = collapsingSeparator(fltMain) - fltBarStart - fltPadding + fltSpacing / 2
        guard fltRelative >= 0 else { return nil }
        let intIndex = Int(fltRelative / fltSlot)
        return intIndex < intCount ? intIndex : nil
    }

    /// Nearest slot for dropping a dragged icon.
    /// - Parameter fltMain: Main coordinate.
    /// - Returns: Slot index clamped to the item range.
    func dropSlot(atMain fltMain: CGFloat) -> Int {
        let fltRelative = collapsingSeparator(fltMain) - fltBarStart - fltPadding + fltSpacing / 2
        return min(max(Int((fltRelative / fltSlot).rounded(.down)), 0), max(intCount - 1, 0))
    }

    /// Separator position in a (possibly magnified) layout: midway between the
    /// last pinned icon's far edge and the first running icon's near edge.
    /// - Parameter objLayout: Current layout.
    /// - Returns: Main coordinate, or `nil` without a separator.
    func separatorMain(in objLayout: Layout) -> CGFloat? {
        guard let intAfter = intSeparatorAfter,
              intAfter + 1 < objLayout.arrFltCenters.count else { return nil }
        let fltLeadingEdge = objLayout.arrFltCenters[intAfter] + objLayout.arrFltSizes[intAfter] / 2
        let fltTrailingEdge = objLayout.arrFltCenters[intAfter + 1] - objLayout.arrFltSizes[intAfter + 1] / 2
        return (fltLeadingEdge + fltTrailingEdge) / 2
    }

    // MARK: - Layouts

    /// Layout with magnification around the cursor.
    ///
    /// Each icon grows by a cosine falloff of its distance to the cursor. Growth
    /// is distributed so the point under the cursor stays put: icons before it
    /// push toward the start, icons after it toward the end.
    /// - Parameter fltMouseMain: Cursor main coordinate, or `nil` when not hovering.
    /// - Returns: Icon centers/sizes and bar extent.
    func layout(mouseMain fltMouseMain: CGFloat?) -> Layout {
        var arrFltSizes = Array(repeating: fltIconSize, count: intCount)

        if let fltMouseMain, fltMagnification > 1.001 {
            for intIndex in 0..<intCount {
                let fltDistance = abs(fltMouseMain - baseCenter(intIndex)) / fltSlot
                guard fltDistance < Self.fltInfluenceRadius else { continue }
                let fltFalloff = (cos(.pi * fltDistance / Self.fltInfluenceRadius) + 1) / 2
                arrFltSizes[intIndex] = fltIconSize * (1 + (fltMagnification - 1) * fltFalloff)
            }
        }

        let arrFltExtras = arrFltSizes.map { $0 - fltIconSize }

        // How far the cursor's point would move if everything grew to the right;
        // subtracting it pins that point in place.
        var fltShift: CGFloat = 0
        if let fltMouseMain {
            for intIndex in 0..<intCount {
                let fltSlotStart = baseCenter(intIndex) - fltSlot / 2
                let fltSlotEnd = baseCenter(intIndex) + fltSlot / 2
                if fltMouseMain >= fltSlotEnd {
                    fltShift += arrFltExtras[intIndex]
                } else if fltMouseMain > fltSlotStart {
                    fltShift += arrFltExtras[intIndex] * (fltMouseMain - fltSlotStart) / fltSlot
                }
            }
        }

        var arrFltCenters: [CGFloat] = []
        var fltCumulative: CGFloat = 0
        for intIndex in 0..<intCount {
            arrFltCenters.append(baseCenter(intIndex) + fltCumulative + arrFltExtras[intIndex] / 2 - fltShift)
            fltCumulative += arrFltExtras[intIndex]
        }

        return Layout(
            arrFltCenters: arrFltCenters,
            arrFltSizes: arrFltSizes,
            fltBarStart: fltBarStart - fltShift,
            fltBarEnd: fltBarStart + fltBaseLength + fltCumulative - fltShift
        )
    }

    /// Layout while an icon is being dragged: other icons slide apart to open a gap
    /// at the target slot (or close up when the icon is dragged off to be removed).
    /// - Parameter objDrag: Current drag.
    /// - Returns: Icon centers/sizes and bar extent.
    func layout(dragging objDrag: DockDrag) -> Layout {
        var arrFltCenters = Array(repeating: 0 as CGFloat, count: intCount)
        var intSlot = 0
        for intIndex in 0..<intCount where intIndex != objDrag.intIndex {
            if !objDrag.blnOutside && intSlot == objDrag.intTargetSlot {
                intSlot += 1
            }
            arrFltCenters[intIndex] = baseCenter(intSlot)
            intSlot += 1
        }
        if objDrag.intIndex < intCount {
            arrFltCenters[objDrag.intIndex] = baseCenter(objDrag.intTargetSlot)
        }

        return Layout(
            arrFltCenters: arrFltCenters,
            arrFltSizes: Array(repeating: fltIconSize, count: intCount),
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

/// An in-progress icon drag inside the dock.
struct DockDrag: Equatable {
    /// Item being dragged.
    let intIndex: Int
    /// Slot the icon would land in if released now.
    var intTargetSlot: Int
    /// Dragged far enough off the dock that releasing removes it.
    var blnOutside: Bool
}
