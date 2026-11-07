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
    let objNewWindowTracker: NewWindowTracker

    var body: some View {
        let arrObjItems = objTracker.arrObjItems
        let objGeometry = DockGeometry(objSettings: objSettings, arrObjItems: arrObjItems)
        let objLayout = objState.objDrag.map { objGeometry.layout(dragging: $0) }
            ?? objGeometry.layout(mouseMain: objState.fltMouseMain)
        // While dragging, slots no longer map to item indices; keep the separator fixed.
        let fltSeparatorMain = objState.objDrag == nil
            ? objGeometry.separatorMain(in: objLayout)
            : objGeometry.fltBaseSeparatorMain

        ZStack(alignment: .topLeading) {
            barBackground(objGeometry: objGeometry, objLayout: objLayout)

            if let fltSeparatorMain {
                separator(objGeometry: objGeometry, fltMain: fltSeparatorMain)
            }

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

                // Running dot; turns into a larger accent dot when the app has a window you haven't seen.
                let blnHasNew = objItem.objRunningApp.map { objNewWindowTracker.setIntPidsWithNew.contains($0.processIdentifier) } ?? false
                Circle()
                    .fill(blnHasNew
                          ? Color.accentColor
                          : Color.primary.opacity(objTracker.strActiveBundleId == objItem.strBundleId ? 0.9 : 0.55))
                    .frame(width: blnHasNew ? 6 : 4, height: blnHasNew ? 6 : 4)
                    .shadow(color: blnHasNew ? Color.accentColor.opacity(0.8) : .clear, radius: 3)
                    .opacity(objItem.blnIsRunning && !blnIsDragged ? 1 : 0)
                    .position(objGeometry.viewPoint(main: fltCenter, cross: objGeometry.fltIndicatorCross))
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: blnHasNew)
            }
        }
        .frame(width: objGeometry.objPanelSize.width, height: objGeometry.objPanelSize.height, alignment: .topLeading)
        // Short springs: tight enough to track the cursor, soft enough to feel fluid.
        .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.86), value: objState.fltMouseMain)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: objState.objDrag)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: arrObjItems.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: objSettings.fltIconSize)
    }

    /// Thin divider between pinned apps and other running apps.
    /// - Parameters:
    ///   - objGeometry: Current geometry.
    ///   - fltMain: Separator position along the bar.
    /// - Returns: The positioned line.
    private func separator(objGeometry: DockGeometry, fltMain: CGFloat) -> some View {
        let fltLength = objGeometry.fltIconSize * 0.7
        let objSize = objGeometry.enmPosition.blnIsVertical
            ? CGSize(width: fltLength, height: 1)
            : CGSize(width: 1, height: fltLength)

        return Capsule()
            .fill(Color.primary.opacity(0.25))
            .frame(width: objSize.width, height: objSize.height)
            .position(objGeometry.viewPoint(main: fltMain, cross: objGeometry.iconCross(forSize: objGeometry.fltIconSize)))
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
