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
    /// App being held over during a drag, before it's ready to form a group.
    var intGroupPending: Int?
    /// Apps launched from the dock that haven't finished launching (they bounce).
    var setStrLaunching: Set<String> = []
    /// Control under the cursor on the large Now Playing tile.
    var enmWidgetHover: NowPlayingLargeLayout.Control?
    /// Seek/volume bar being dragged on the large Now Playing tile.
    var enmWidgetScrub: WidgetScrub?
}

/// One dock icon with its notification badge, progress bar and bounces.
private struct DockIconView: View {
    let objIcon: NSImage
    let fltSize: CGFloat
    let strBadge: String?
    let fltProgress: Double?
    let blnLaunching: Bool
    let intAttention: Int
    let fltBounceHeight: CGFloat
    /// Unit vector pointing away from the screen edge, in view coordinates.
    let objBounceDirection: CGVector

    var body: some View {
        Image(nsImage: objIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: fltSize, height: fltSize)
            .overlay(alignment: .topTrailing) {
                if let strBadge {
                    badge(strBadge)
                }
            }
            .overlay(alignment: .bottom) {
                if let fltProgress {
                    progressBar(fltProgress)
                }
            }
            // Two quick hops when the app asks for attention.
            .keyframeAnimator(initialValue: 0.0, trigger: intAttention) { objContent, fltLift in
                objContent.offset(x: objBounceDirection.dx * fltLift, y: objBounceDirection.dy * fltLift)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(fltBounceHeight, duration: 0.17)
                    CubicKeyframe(0, duration: 0.17)
                    CubicKeyframe(fltBounceHeight * 0.55, duration: 0.14)
                    CubicKeyframe(0, duration: 0.14)
                }
            }
            .modifier(LaunchBounce(blnActive: blnLaunching, fltHeight: fltBounceHeight, objDirection: objBounceDirection))
    }

    /// Red capsule with the badge text, scaled to the icon.
    /// - Parameter strText: Badge text.
    /// - Returns: The badge view.
    private func badge(_ strText: String) -> some View {
        let fltHeight = max(14, fltSize * 0.36)
        return Text(strText)
            .font(.system(size: fltHeight * 0.68, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, fltHeight * 0.28)
            .frame(minWidth: fltHeight, minHeight: fltHeight, maxHeight: fltHeight)
            .background(Capsule().fill(Color.red))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .offset(x: fltHeight * 0.25, y: -fltHeight * 0.2)
    }

    /// Thin progress bar along the bottom of the icon.
    /// - Parameter fltValue: Progress 0…1.
    /// - Returns: The bar view.
    private func progressBar(_ fltValue: Double) -> some View {
        let fltWidth = fltSize * 0.8
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.45))
            Capsule().fill(Color.accentColor).frame(width: fltWidth * fltValue)
        }
        .frame(width: fltWidth, height: max(3, fltSize * 0.08))
        .padding(.bottom, fltSize * 0.06)
    }
}

/// Repeating bounce while an app launches.
private struct LaunchBounce: ViewModifier {
    let blnActive: Bool
    let fltHeight: CGFloat
    let objDirection: CGVector

    /// Applies the looping hop only while launching.
    /// - Parameter content: The icon.
    /// - Returns: The icon, bouncing if active.
    @ViewBuilder
    func body(content: Content) -> some View {
        if blnActive {
            content.phaseAnimator([0.0, 1.0]) { objContent, fltPhase in
                objContent.offset(x: objDirection.dx * fltHeight * fltPhase, y: objDirection.dy * fltHeight * fltPhase)
            } animation: { fltPhase in
                fltPhase == 1 ? .easeOut(duration: 0.3) : .easeIn(duration: 0.3)
            }
        } else {
            content
        }
    }
}

/// The dock: a glass bar with icons placed at exact positions, so magnification,
/// drag-reorder and every screen edge share one layout model (`DockGeometry`).
struct DockView: View {
    let objTracker: AppTracker
    let objSettings: SettingsStore
    let objState: DockState
    let objNewWindowTracker: NewWindowTracker
    let objBadges: DockBadgeService
    let objNowPlaying: NowPlayingService
    let objBattery: BatteryService
    let objVolume: SystemVolumeService

    /// Live view for a widget tile.
    /// - Parameters:
    ///   - enmWidget: Widget.
    ///   - fltSize: Current (magnified) tile size.
    /// - Returns: The tile.
    @ViewBuilder
    private func widgetTile(_ enmWidget: DockItem.Widget, fltSize: CGFloat) -> some View {
        switch enmWidget {
        case .nowPlaying: NowPlayingTileView(objNowPlaying: objNowPlaying, fltSize: fltSize)
        case .battery: BatteryTileView(objBattery: objBattery, fltSize: fltSize)
        }
    }

    /// Direction icons hop: away from the screen edge.
    private var bounceDirection: CGVector {
        switch objSettings.enmPosition {
        case .bottom: CGVector(dx: 0, dy: -1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
    }

    var body: some View {
        let arrObjItems = objTracker.arrObjItems
        let objGeometry = DockGeometry(objSettings: objSettings, arrObjItems: arrObjItems)
        let objLayout = objState.objDrag.map { objGeometry.layout(dragging: $0) }
            ?? objGeometry.layout(mouseMain: objState.fltMouseMain)

        ZStack(alignment: .topLeading) {
            barBackground(objGeometry: objGeometry, objLayout: objLayout)

            ForEach(Array(arrObjItems.enumerated()), id: \.element.id) { intIndex, objItem in
                let fltCenter = objLayout.arrFltCenters[safe: intIndex] ?? objGeometry.baseCenter(intIndex)
                let fltSize = objLayout.arrFltSizes[safe: intIndex] ?? objGeometry.fltIconSize
                let blnIsDragged = objState.objDrag?.intIndex == intIndex
                let blnIsDropTarget = objState.objDrag?.intDropTarget == intIndex
                // App-onto-app: pending while the hold timer runs, armed once dropping would group them.
                let blnGroupArmed = blnIsDropTarget && objItem.blnIsApp
                let blnGroupPending = !blnGroupArmed && objState.intGroupPending == intIndex
                let objIconPoint = objGeometry.viewPoint(main: fltCenter, cross: objGeometry.iconCross(forSize: fltSize))

                if objItem.blnIsApp {
                    groupPreviewTile(fltSize: fltSize, blnPending: blnGroupPending, blnArmed: blnGroupArmed)
                        .position(objIconPoint)
                }

                if objItem.blnIsDivider {
                    divider(objGeometry: objGeometry, fltMain: fltCenter)
                        .opacity(blnIsDragged ? 0 : 1)
                        .transition(.opacity)
                } else if objGeometry.arrBlnWide[safe: intIndex] == true {
                    NowPlayingLargeView(
                        objNowPlaying: objNowPlaying,
                        objVolume: objVolume,
                        fltIconSize: objGeometry.fltIconSize,
                        blnVertical: objGeometry.enmPosition.blnIsVertical,
                        enmScrub: objState.enmWidgetScrub,
                        enmHovered: objState.enmWidgetHover
                    )
                    .position(objGeometry.viewPoint(main: fltCenter, cross: objGeometry.iconCross(forSize: objGeometry.fltIconSize)))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else if let enmWidget = objItem.enmWidget {
                    widgetTile(enmWidget, fltSize: fltSize)
                        .position(objIconPoint)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    DockIconView(
                        objIcon: objItem.objIcon,
                        fltSize: fltSize,
                        strBadge: objBadges.dictStrBadges[objItem.strBundleId],
                        fltProgress: objBadges.dictFltProgress[objItem.strBundleId],
                        blnLaunching: objState.setStrLaunching.contains(objItem.strBundleId),
                        intAttention: objBadges.dictIntAttention[objItem.strBundleId] ?? 0,
                        fltBounceHeight: objGeometry.fltBounceHeight,
                        objBounceDirection: bounceDirection
                    )
                        // A group or the Trash swells when something is dragged onto it; an app
                        // about to be grouped shrinks into the first slot of the group tile.
                        .scaleEffect(blnGroupArmed ? 0.42 : blnGroupPending ? 0.88 : blnIsDropTarget ? 1.18 : 1)
                        .offset(
                            x: blnGroupArmed ? -fltSize * 0.22 : 0,
                            y: blnGroupArmed ? -fltSize * 0.22 : 0
                        )
                        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: blnGroupArmed)
                        .animation(.easeOut(duration: 0.3), value: blnGroupPending)
                        // The dragged icon is drawn by the floating drag panel instead.
                        .opacity(blnIsDragged ? 0 : 1)
                        .position(objIconPoint)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))

                    indicator(for: objItem, objGeometry: objGeometry, fltMain: fltCenter, fltIconSize: fltSize)
                        .opacity(objItem.blnIsRunning && !blnIsDragged ? 1 : 0)
                }
            }
        }
        .frame(width: objGeometry.objPanelSize.width, height: objGeometry.objPanelSize.height, alignment: .topLeading)
        // Short springs: tight enough to track the cursor, soft enough to feel fluid.
        .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.86), value: objState.fltMouseMain)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: objState.objDrag)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: arrObjItems.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: objSettings.fltIconSize)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: objSettings.blnCompact)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: objSettings.enmNowPlayingSize)
    }

    /// Running indicator in the chosen style. Turns accent-colored (and larger)
    /// when the app has a window you haven't looked at yet.
    /// - Parameters:
    ///   - objItem: Dock item.
    ///   - objGeometry: Current geometry.
    ///   - fltMain: Item center along the bar.
    ///   - fltIconSize: Current (magnified) icon size.
    /// - Returns: The positioned indicator.
    @ViewBuilder
    private func indicator(for objItem: DockItem, objGeometry: DockGeometry, fltMain: CGFloat, fltIconSize: CGFloat) -> some View {
        let blnHasNew = objItem.objRunningApp.map { objNewWindowTracker.setIntPidsWithNew.contains($0.processIdentifier) } ?? false
        let blnIsActive = objTracker.strActiveBundleId == objItem.objRunningApp?.bundleIdentifier
        let objColor = blnHasNew ? Color.accentColor : Color.primary.opacity(blnIsActive ? 0.9 : 0.55)
        let objPoint = objGeometry.viewPoint(main: fltMain, cross: objGeometry.fltIndicatorCross)

        switch objSettings.enmIndicatorStyle {
        case .dot:
            Circle()
                .fill(objColor)
                .frame(width: blnHasNew ? 6 : 4, height: blnHasNew ? 6 : 4)
                .shadow(color: blnHasNew ? Color.accentColor.opacity(0.8) : .clear, radius: 3)
                .position(objPoint)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: blnHasNew)
        case .bar:
            // Wider for the active app, like a tab underline.
            let fltLength = fltIconSize * (blnIsActive || blnHasNew ? 0.5 : 0.28)
            let objSize = objGeometry.enmPosition.blnIsVertical
                ? CGSize(width: 3, height: fltLength)
                : CGSize(width: fltLength, height: 3)
            Capsule()
                .fill(objColor)
                .frame(width: objSize.width, height: objSize.height)
                .shadow(color: blnHasNew ? Color.accentColor.opacity(0.8) : .clear, radius: 3)
                .position(objPoint)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: blnIsActive)
        case .none:
            // Still flag new windows, even with indicators off.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .shadow(color: Color.accentColor.opacity(0.8), radius: 3)
                .opacity(blnHasNew ? 1 : 0)
                .position(objPoint)
        }
    }

    /// Frosted rounded tile that grows behind an app when another app is held over
    /// it, previewing the group about to be made: it starts growing during the
    /// hold, then springs to full size with a gentle pulse once a drop would group.
    /// - Parameters:
    ///   - fltSize: Current icon size.
    ///   - blnPending: Hold in progress.
    ///   - blnArmed: Dropping now creates a group.
    /// - Returns: The tile (invisible when neither).
    private func groupPreviewTile(fltSize: CGFloat, blnPending: Bool, blnArmed: Bool) -> some View {
        let fltCorner = fltSize * 0.26
        return RoundedRectangle(cornerRadius: fltCorner)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: fltCorner).fill(Color.primary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: fltCorner).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                // An empty slot where the dragged app will go.
                RoundedRectangle(cornerRadius: fltSize * 0.1)
                    .strokeBorder(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: fltSize * 0.36, height: fltSize * 0.36)
                    .padding(fltSize * 0.1)
                    .opacity(blnArmed ? 1 : 0)
            }
            .frame(width: fltSize * 0.98, height: fltSize * 0.98)
            .shadow(color: .black.opacity(blnArmed ? 0.25 : 0), radius: 6, y: 2)
            .phaseAnimator([1.0, 1.04], trigger: blnArmed) { objContent, fltPulse in
                objContent.scaleEffect(blnArmed ? fltPulse : 1)
            } animation: { _ in
                .easeInOut(duration: 0.18)
            }
            .scaleEffect(blnArmed ? 1.12 : blnPending ? 0.9 : 0.5)
            .opacity(blnArmed ? 1 : blnPending ? 0.55 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: blnArmed)
            .animation(.easeOut(duration: 0.3), value: blnPending)
            .allowsHitTesting(false)
    }

    /// Divider line, centered in its (thin) slot.
    /// - Parameters:
    ///   - objGeometry: Current geometry.
    ///   - fltMain: Divider position along the bar.
    /// - Returns: The positioned line.
    private func divider(objGeometry: DockGeometry, fltMain: CGFloat) -> some View {
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
            .dockGlass(cornerRadius: objGeometry.fltCornerRadius, tint: objSettings.objDockTint)
            .position(objCenter)
    }
}

extension Array {
    /// Element at `intIndex`, or `nil` when out of range (layouts can lag a frame behind item changes).
    subscript(safe intIndex: Int) -> Element? {
        indices.contains(intIndex) ? self[intIndex] : nil
    }
}
