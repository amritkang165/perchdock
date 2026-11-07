import CoreGraphics

/// Fixed geometry shared by the dock view (drawing) and controller (hit-testing),
/// so both always agree on where each icon is.
///
/// Coordinates are panel-local with a bottom-left origin. The panel is exactly as
/// wide as the bar; the bar occupies the bottom `fltBarHeight` points and the
/// strip above it is headroom for the hover zoom.
enum DockLayout {
    static let fltIconSize: CGFloat = 52
    static let fltIconSpacing: CGFloat = 8
    static let fltBarPadding: CGFloat = 8
    static let fltIndicatorHeight: CGFloat = 6
    static let fltHoverScale: CGFloat = 1.18
    static let fltCornerRadius: CGFloat = 22
    static let fltScreenGap: CGFloat = 6

    /// Height of the visible bar: icon, running indicator and padding.
    static var fltBarHeight: CGFloat {
        fltIconSize + fltIndicatorHeight + fltBarPadding * 2
    }

    /// Extra transparent space above the bar so a zoomed icon isn't clipped.
    static var fltTopHeadroom: CGFloat {
        ceil(fltIconSize * (fltHoverScale - 1)) + 2
    }

    /// Total panel height.
    static var fltPanelHeight: CGFloat {
        fltBarHeight + fltTopHeadroom
    }

    /// Width of the bar (and panel) for a number of icons.
    /// - Parameter intCount: Number of dock items.
    /// - Returns: Width in points.
    static func barWidth(forItemCount intCount: Int) -> CGFloat {
        let intSafeCount = max(intCount, 1)
        return CGFloat(intSafeCount) * fltIconSize
            + CGFloat(intSafeCount - 1) * fltIconSpacing
            + fltBarPadding * 2
    }

    /// Horizontal center of an icon, in panel coordinates.
    /// - Parameter intIndex: Item index.
    /// - Returns: The icon's mid-X.
    static func iconMidX(at intIndex: Int) -> CGFloat {
        fltBarPadding + CGFloat(intIndex) * (fltIconSize + fltIconSpacing) + fltIconSize / 2
    }

    /// Finds the icon under a point. The gap between icons is split between
    /// neighbors so there are no dead zones while sweeping across the bar.
    /// - Parameters:
    ///   - objPoint: Panel-local point (bottom-left origin).
    ///   - intCount: Number of dock items.
    /// - Returns: Item index, or `nil` if the point isn't over the bar.
    static func iconIndex(at objPoint: CGPoint, itemCount intCount: Int) -> Int? {
        guard intCount > 0, objPoint.y >= 0, objPoint.y <= fltBarHeight else { return nil }

        let fltRelativeX = objPoint.x - fltBarPadding + fltIconSpacing / 2
        guard fltRelativeX >= 0 else { return nil }

        let intIndex = Int(fltRelativeX / (fltIconSize + fltIconSpacing))
        return intIndex < intCount ? intIndex : nil
    }
}
