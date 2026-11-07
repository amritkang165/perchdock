import SwiftUI
import Observation

/// UI state for the dock that isn't part of the app list.
@MainActor
@Observable
final class DockState {
    /// Index of the icon under the mouse, if any.
    var intHoveredIndex: Int?
}

/// The dock bar: a glass strip of app icons with running indicators.
struct DockView: View {
    let objTracker: AppTracker
    let objState: DockState

    var body: some View {
        // Bottom-aligned so the headroom above the bar stays transparent.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: DockLayout.fltIconSpacing) {
                ForEach(Array(objTracker.arrObjItems.enumerated()), id: \.element.id) { intIndex, objItem in
                    DockIconView(
                        objItem: objItem,
                        blnIsHovered: objState.intHoveredIndex == intIndex,
                        blnIsActive: objTracker.strActiveBundleId == objItem.strBundleId
                    )
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .padding(DockLayout.fltBarPadding)
            .frame(height: DockLayout.fltBarHeight)
            .dockGlass(cornerRadius: DockLayout.fltCornerRadius)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: objTracker.arrObjItems.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// One app icon with a hover zoom and a running dot.
private struct DockIconView: View {
    let objItem: DockItem
    let blnIsHovered: Bool
    let blnIsActive: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: objItem.objIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: DockLayout.fltIconSize, height: DockLayout.fltIconSize)
                // Zoom from the bottom edge so the icon grows up into the headroom.
                .scaleEffect(blnIsHovered ? DockLayout.fltHoverScale : 1, anchor: .bottom)
                .animation(.spring(response: 0.2, dampingFraction: 0.72), value: blnIsHovered)

            Circle()
                .fill(Color.primary.opacity(blnIsActive ? 0.9 : 0.55))
                .frame(width: 4, height: 4)
                .opacity(objItem.blnIsRunning ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: objItem.blnIsRunning)
        }
        .frame(height: DockLayout.fltIconSize + DockLayout.fltIndicatorHeight)
        .help(objItem.strName)
    }
}
