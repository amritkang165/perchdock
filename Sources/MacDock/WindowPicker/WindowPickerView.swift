import SwiftUI
import Observation

/// Geometry shared by the picker view and its controller's hit-testing.
enum WindowPickerLayout {
    static let fltWidth: CGFloat = 320
    static let fltPadding: CGFloat = 6
    static let fltHeaderHeight: CGFloat = 24
    static let fltRowHeight: CGFloat = 30
    static let fltCornerRadius: CGFloat = 16

    /// Panel height for a number of window rows.
    /// - Parameter intRows: Number of windows listed.
    /// - Returns: Height in points.
    static func height(forRowCount intRows: Int) -> CGFloat {
        fltPadding * 2 + fltHeaderHeight + CGFloat(intRows) * fltRowHeight
    }

    /// Finds the row under a point.
    /// - Parameters:
    ///   - objPoint: Panel-local point (bottom-left origin).
    ///   - intRows: Number of rows.
    /// - Returns: Row index, or `nil` if over the header or padding.
    static func rowIndex(at objPoint: CGPoint, rowCount intRows: Int) -> Int? {
        let fltFromTop = height(forRowCount: intRows) - objPoint.y - fltPadding - fltHeaderHeight
        guard fltFromTop >= 0 else { return nil }
        let intIndex = Int(fltFromTop / fltRowHeight)
        return intIndex < intRows ? intIndex : nil
    }
}

/// Observable contents of the picker.
@MainActor
@Observable
final class WindowPickerState {
    var strAppName = ""
    var arrObjWindows: [WindowInfo] = []
    var intHoveredRow: Int?
}

/// Glass popover listing an app's windows; clicking a row raises that window.
struct WindowPickerView: View {
    let objState: WindowPickerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(objState.strAppName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: WindowPickerLayout.fltHeaderHeight, alignment: .leading)

            ForEach(Array(objState.arrObjWindows.enumerated()), id: \.element.id) { intIndex, objWindow in
                WindowRowView(objWindow: objWindow, blnIsHovered: objState.intHoveredRow == intIndex)
            }
        }
        .padding(WindowPickerLayout.fltPadding)
        .frame(width: WindowPickerLayout.fltWidth, alignment: .leading)
        .dockGlass(cornerRadius: WindowPickerLayout.fltCornerRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// A single window entry: icon, title, and a highlight while hovered.
private struct WindowRowView: View {
    let objWindow: WindowInfo
    let blnIsHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: objWindow.blnIsMinimized ? "minus.rectangle" : "macwindow")
                .frame(width: 16)
            Text(objWindow.strTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(textColor)
        .padding(.horizontal, 8)
        .frame(height: WindowPickerLayout.fltRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(blnIsHovered ? 0.9 : 0))
        )
        .animation(.easeOut(duration: 0.08), value: blnIsHovered)
    }

    /// White on the highlight, dimmed for minimized windows, primary otherwise.
    private var textColor: Color {
        if blnIsHovered { return .white }
        return objWindow.blnIsMinimized ? .secondary : .primary
    }
}
