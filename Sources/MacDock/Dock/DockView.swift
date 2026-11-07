import SwiftUI
import Observation

/// UI state for the dock that isn't part of the app list.
@MainActor
@Observable
final class DockState {
    /// Cursor position along the bar while hovering, driving magnification.
    var fltMouseMain: CGFloat?
    /// Index of the icon under the cursor.
    var intHoveredIndex: Int?
    /// In-progress drag, if any.
    var objDrag: DockDrag?
}

/// The dock: a glass bar with icons placed at exact positions, so magnification,
/// drag-reorder and every screen edge share one layout model (`DockGeometry`).
struct DockView: View {
    let objTracker: AppTracker
    let objSettings: SettingsStore
    let objState: DockState

    var body: some View {
        let arrObjItems = objTracker.arrObjItems
        let objGeometry = DockGeometry(objSettings: objSettings, intCount: arrObjItems.count)
        let objLayout = objState.objDrag.map { objGeometry.layout(dragging: $0) }
            ?? objGeometry.layout(mouseMain: objState.fltMouseMain)

        ZStack(alignment: .topLeading) {
            barBackground(objGeometry: objGeometry, objLayout: objLayout)

            ForEach(Array(arrObjItems.enumerated()), id: \.element.id) { intIndex, objItem in
                let fltCenter = objLayout.arrFltCenters[safe: intIndex] ?? objGeometry.baseCenter(intIndex)
                let fltSize = objLayout.arrFltSizes[safe: intIndex] ?? objGeometry.fltIconSize
                let blnIsDragged = objState.objDrag?.intIndex == intIndex

                Image(nsImage: objItem.objIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fltSize, height: fltSize)
                    // The dragged icon is drawn by the floating drag panel instead.
                    .opacity(blnIsDragged ? 0 : 1)
                    .position(objGeometry.viewPoint(main: fltCenter, cross: objGeometry.iconCross(forSize: fltSize)))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))

                Circle()
                    .fill(Color.primary.opacity(objTracker.strActiveBundleId == objItem.strBundleId ? 0.9 : 0.55))
                    .frame(width: 4, height: 4)
                    .opacity(objItem.blnIsRunning && !blnIsDragged ? 1 : 0)
                    .position(objGeometry.viewPoint(main: fltCenter, cross: objGeometry.fltIndicatorCross))
            }
        }
        .frame(width: objGeometry.objPanelSize.width, height: objGeometry.objPanelSize.height, alignment: .topLeading)
        // Short springs: tight enough to track the cursor, soft enough to feel fluid.
        .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.86), value: objState.fltMouseMain)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: objState.objDrag)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: arrObjItems.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: objSettings.fltIconSize)
    }

    /// Glass bar spanning the (possibly magnified) icons.
    /// - Parameters:
    ///   - objGeometry: Current geometry.
    ///   - objLayout: Current layout.
    /// - Returns: The positioned background.
    private func barBackground(objGeometry: DockGeometry, objLayout: DockGeometry.Layout) -> some View {
        let fltLength = max(objLayout.fltBarEnd - objLayout.fltBarStart, 0)
        let fltThickness = objGeometry.fltBarThickness
        let objCenter = objGeometry.viewPoint(
            main: (objLayout.fltBarStart + objLayout.fltBarEnd) / 2,
            cross: fltThickness / 2
        )
        let objSize = objGeometry.enmPosition.blnIsVertical
            ? CGSize(width: fltThickness, height: fltLength)
            : CGSize(width: fltLength, height: fltThickness)

        return Color.clear
            .frame(width: objSize.width, height: objSize.height)
            .dockGlass(cornerRadius: objGeometry.fltCornerRadius)
            .position(objCenter)
    }
}

extension Array {
    /// Element at `intIndex`, or `nil` when out of range (layouts can lag a frame behind item changes).
    subscript(safe intIndex: Int) -> Element? {
        indices.contains(intIndex) ? self[intIndex] : nil
    }
}
