import SwiftUI
import Observation

/// Geometry shared by the picker view (drawing) and its controller (hit-testing).
/// Cards are laid out in a grid of up to `intMaxColumns` per row.
enum WindowPickerLayout {
    static let fltPadding: CGFloat = 8
    static let fltHeaderHeight: CGFloat = 22
    static let fltCornerRadius: CGFloat = 18

    static let fltCardWidth: CGFloat = 200
    static let fltCardPadding: CGFloat = 6
    static let fltCardSpacing: CGFloat = 8
    static let fltThumbHeight: CGFloat = 112
    static let fltTitleHeight: CGFloat = 20
    static let fltTitleGap: CGFloat = 4
    static let fltCloseSize: CGFloat = 18
    static let fltCloseInset: CGFloat = 4
    static let intMaxColumns = 4

    static let fltNoticeWidth: CGFloat = 300
    static let fltNoticeRowHeight: CGFloat = 30

    /// What a point in the picker is over.
    enum Hit: Equatable {
        case card(Int)
        case close(Int)
        case notice
    }

    static var fltThumbWidth: CGFloat { fltCardWidth - fltCardPadding * 2 }
    static var fltCardHeight: CGFloat { fltCardPadding * 2 + fltThumbHeight + fltTitleGap + fltTitleHeight }

    /// Number of grid columns for a window count.
    /// - Parameter intCount: Number of windows.
    /// - Returns: Column count (at least 1).
    static func columns(forCount intCount: Int) -> Int {
        max(1, min(intCount, intMaxColumns))
    }

    /// Number of grid rows for a window count.
    /// - Parameter intCount: Number of windows.
    /// - Returns: Row count (at least 1).
    static func rows(forCount intCount: Int) -> Int {
        max(1, (intCount + intMaxColumns - 1) / intMaxColumns)
    }

    /// Panel size for the current content.
    /// - Parameters:
    ///   - intCount: Number of windows.
    ///   - blnNotice: Whether the permission notice is shown instead of cards.
    /// - Returns: Size in points.
    static func size(forCount intCount: Int, blnNotice: Bool) -> CGSize {
        if blnNotice {
            return CGSize(width: fltNoticeWidth, height: fltPadding * 2 + fltHeaderHeight + fltNoticeRowHeight)
        }
        let intColumns = columns(forCount: intCount)
        let intRows = rows(forCount: intCount)
        return CGSize(
            width: fltPadding * 2 + CGFloat(intColumns) * fltCardWidth + CGFloat(intColumns - 1) * fltCardSpacing,
            height: fltPadding * 2 + fltHeaderHeight + CGFloat(intRows) * fltCardHeight + CGFloat(intRows - 1) * fltCardSpacing
        )
    }

    /// Finds the card (or its close button) under a point.
    /// - Parameters:
    ///   - objPoint: Panel-local point (bottom-left origin).
    ///   - intCount: Number of windows.
    ///   - blnNotice: Whether the permission notice is shown.
    /// - Returns: What was hit, or `nil` for padding, header and gaps.
    static func hit(at objPoint: CGPoint, count intCount: Int, blnNotice: Bool) -> Hit? {
        let objSize = size(forCount: intCount, blnNotice: blnNotice)

        // Convert to content coordinates measured from the top-left, below the header.
        let fltX = objPoint.x - fltPadding
        let fltY = objSize.height - objPoint.y - fltPadding - fltHeaderHeight
        guard fltX >= 0, fltY >= 0 else { return nil }

        if blnNotice {
            return fltY <= fltNoticeRowHeight ? .notice : nil
        }

        let intColumns = columns(forCount: intCount)
        let intColumn = Int(fltX / (fltCardWidth + fltCardSpacing))
        let intRow = Int(fltY / (fltCardHeight + fltCardSpacing))
        let fltInCardX = fltX - CGFloat(intColumn) * (fltCardWidth + fltCardSpacing)
        let fltInCardY = fltY - CGFloat(intRow) * (fltCardHeight + fltCardSpacing)

        guard intColumn < intColumns, fltInCardX <= fltCardWidth, fltInCardY <= fltCardHeight else { return nil }
        let intIndex = intRow * intColumns + intColumn
        guard intIndex < intCount else { return nil }

        // Close button sits in the thumbnail's top-right corner (with a little slop).
        let objCloseRect = CGRect(
            x: fltCardWidth - fltCardPadding - fltCloseInset - fltCloseSize,
            y: fltCardPadding + fltCloseInset,
            width: fltCloseSize,
            height: fltCloseSize
        ).insetBy(dx: -3, dy: -3)
        if objCloseRect.contains(CGPoint(x: fltInCardX, y: fltInCardY)) {
            return .close(intIndex)
        }
        return .card(intIndex)
    }
}

/// Observable contents of the picker.
@MainActor
@Observable
final class WindowPickerState {
    var strAppName = ""
    var objAppIcon: NSImage?
    var arrObjWindows: [WindowInfo] = []
    /// Thumbnails keyed by `WindowInfo.id`.
    var dictObjThumbnails: [Int: NSImage] = [:]
    /// 60 fps live views keyed by `WindowInfo.id` (current-desktop windows only).
    var dictObjLiveViews: [Int: LiveThumbnailView] = [:]
    var objHoveredHit: WindowPickerLayout.Hit?
    /// When true, a single "grant Accessibility" row replaces the cards.
    var blnNeedsPermission = false

    /// Index of the card under the mouse (including when over its close button).
    var intHoveredCard: Int? {
        switch objHoveredHit {
        case .card(let intIndex), .close(let intIndex): return intIndex
        default: return nil
        }
    }
}

/// Glass popover showing an app's windows as thumbnail cards.
struct WindowPickerView: View {
    let objState: WindowPickerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(objState.strAppName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: WindowPickerLayout.fltHeaderHeight, alignment: .leading)

            if objState.blnNeedsPermission {
                PermissionRowView(blnIsHovered: objState.objHoveredHit == .notice)
            } else {
                cardGrid
            }
        }
        .padding(WindowPickerLayout.fltPadding)
        .fixedSize()
        .dockGlass(cornerRadius: WindowPickerLayout.fltCornerRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// A card plus its position, so rows never index back into a list that may have shrunk.
    private struct Cell: Identifiable {
        let intIndex: Int
        let objWindow: WindowInfo
        var id: Int { objWindow.id }
    }

    /// A row of cells, identified by its first window.
    private struct Row: Identifiable {
        let arrObjCells: [Cell]
        var id: Int { arrObjCells.first?.id ?? 0 }
    }

    /// Cards in rows of up to `intMaxColumns`.
    private var cardGrid: some View {
        // Snapshot the windows into rows up front; ForEach only sees value copies.
        let arrObjCells = objState.arrObjWindows.enumerated().map { Cell(intIndex: $0.offset, objWindow: $0.element) }
        let intColumns = WindowPickerLayout.columns(forCount: arrObjCells.count)
        let arrObjRows = stride(from: 0, to: arrObjCells.count, by: intColumns).map {
            Row(arrObjCells: Array(arrObjCells[$0..<min($0 + intColumns, arrObjCells.count)]))
        }

        return VStack(alignment: .leading, spacing: WindowPickerLayout.fltCardSpacing) {
            ForEach(arrObjRows) { objRow in
                HStack(spacing: WindowPickerLayout.fltCardSpacing) {
                    ForEach(objRow.arrObjCells) { objCell in
                        WindowCardView(
                            objWindow: objCell.objWindow,
                            objThumbnail: objState.dictObjThumbnails[objCell.objWindow.id],
                            objLiveView: objState.dictObjLiveViews[objCell.objWindow.id],
                            objAppIcon: objState.objAppIcon,
                            blnIsHovered: objState.intHoveredCard == objCell.intIndex,
                            blnIsCloseHovered: objState.objHoveredHit == .close(objCell.intIndex)
                        )
                    }
                }
            }
        }
    }
}

/// One window: thumbnail (or app icon placeholder), title, and a hover close button.
private struct WindowCardView: View {
    let objWindow: WindowInfo
    let objThumbnail: NSImage?
    let objLiveView: LiveThumbnailView?
    let objAppIcon: NSImage?
    let blnIsHovered: Bool
    let blnIsCloseHovered: Bool

    var body: some View {
        VStack(spacing: WindowPickerLayout.fltTitleGap) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: WindowPickerLayout.fltThumbWidth, height: WindowPickerLayout.fltThumbHeight)
                    // Live frames draw over the snapshot (or placeholder) once streaming starts.
                    .overlay {
                        if let objLiveView {
                            LiveThumbnailHost(objView: objLiveView)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            if objWindow.blnIsNew {
                                newBadge
                            }
                            if let strDesktopLabel = objWindow.strDesktopLabel {
                                desktopBadge(strDesktopLabel)
                            }
                        }
                        .padding(WindowPickerLayout.fltCloseInset)
                    }

                if blnIsHovered {
                    closeButton
                        .padding(WindowPickerLayout.fltCloseInset)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }

            HStack(spacing: 4) {
                // The desktop badge already says where it is; fall back to an icon without one.
                if objWindow.blnIsOnOtherSpace && objWindow.strDesktopLabel == nil {
                    Image(systemName: "rectangle.on.rectangle")
                }
                if objWindow.blnIsMinimized {
                    Image(systemName: "minus.rectangle")
                }
                Text(objWindow.strTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .foregroundStyle(objWindow.blnIsMinimized || objWindow.blnIsOnOtherSpace ? Color.secondary : Color.primary)
            .frame(width: WindowPickerLayout.fltThumbWidth, height: WindowPickerLayout.fltTitleHeight)
        }
        .padding(WindowPickerLayout.fltCardPadding)
        .frame(width: WindowPickerLayout.fltCardWidth, height: WindowPickerLayout.fltCardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(blnIsHovered ? 0.1 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(blnIsHovered ? 0.9 : 0), lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.1), value: blnIsHovered)
    }

    /// Live thumbnail if captured, otherwise a soft tile with the app icon.
    @ViewBuilder
    private var thumbnail: some View {
        if let objThumbnail {
            Image(nsImage: objThumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .opacity(objWindow.blnIsMinimized ? 0.6 : 1)
                .transition(.opacity)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    if let objAppIcon {
                        Image(nsImage: objAppIcon)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .opacity(0.85)
                    }
                }
        }
    }

    /// Capsule naming the window's desktop; accent-filled for the desktop you're on.
    /// - Parameter strLabel: e.g. "Desktop 2".
    /// - Returns: The badge view.
    private func desktopBadge(_ strLabel: String) -> some View {
        let blnIsCurrent = !objWindow.blnIsOnOtherSpace
        return Text(strLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(blnIsCurrent ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if blnIsCurrent {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
    }

    /// Green "New" capsule for windows that appeared since you last looked.
    private var newBadge: some View {
        Text("New")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
    }

    /// Small round close button, red while hovered.
    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(blnIsCloseHovered ? Color.white : Color.primary)
            .frame(width: WindowPickerLayout.fltCloseSize, height: WindowPickerLayout.fltCloseSize)
            .background(Circle().fill(blnIsCloseHovered ? Color.red : Color(nsColor: .windowBackgroundColor).opacity(0.9)))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
    }
}

/// Row prompting the user to grant Accessibility access.
private struct PermissionRowView: View {
    let blnIsHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .frame(width: 16)
            Text("Allow Accessibility to see windows…")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(blnIsHovered ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(width: WindowPickerLayout.fltNoticeWidth - WindowPickerLayout.fltPadding * 2, height: WindowPickerLayout.fltNoticeRowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(blnIsHovered ? 0.9 : 0)))
        .animation(.easeOut(duration: 0.08), value: blnIsHovered)
    }
}
