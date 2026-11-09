import AppKit
import SwiftUI

/// The large Now Playing player in a small panel that slides out beside a side
/// dock when its Now Playing tile is hovered.
///
/// It uses the same view and layout as the bottom-dock tile, and the same
/// interaction handler, so it looks and behaves identically.
@MainActor
final class NowPlayingFlyoutController {
    /// Space around the player inside the panel, for its shadow.
    private static let fltMargin: CGFloat = 10

    private let objNowPlaying: NowPlayingService
    private let objInteraction: NowPlayingInteraction
    private let objSettings: SettingsStore
    private var objPanel: NSPanel?
    private var objHostingView: TrackingHostingView<FlyoutView>?

    /// Whether the fly-out is on screen.
    private(set) var blnIsVisible = false
    /// Whether the cursor is over the fly-out.
    private(set) var blnMouseInside = false
    /// Called when the cursor enters or leaves the fly-out.
    var onMouseInsideChanged: ((Bool) -> Void)?

    /// Screen frame of the panel (zero when hidden).
    var objFrame: CGRect { blnIsVisible ? objPanel?.frame ?? .zero : .zero }

    /// Creates the controller (the panel is built on first show).
    /// - Parameters:
    ///   - objNowPlaying: Playback state.
    ///   - objInteraction: Shared hover/press/scrub handler.
    ///   - objSettings: Preferences (icon size, seek bar style).
    init(objNowPlaying: NowPlayingService, objInteraction: NowPlayingInteraction, objSettings: SettingsStore) {
        self.objNowPlaying = objNowPlaying
        self.objInteraction = objInteraction
        self.objSettings = objSettings
    }

    /// Shows the player beside the dock.
    /// - Parameters:
    ///   - objAnchor: Screen point on the dock's outer edge, level with the tile.
    ///   - enmPosition: Dock edge (the fly-out opens away from it).
    func show(objAnchor: CGPoint, enmPosition: DockPosition) {
        let objPanel = self.objPanel ?? makePanel()
        // Content exists only while shown: hidden SwiftUI timelines would keep animating.
        if objHostingView == nil {
            installContent(in: objPanel)
        }
        let objLayout = NowPlayingLargeLayout(fltIconSize: CGFloat(objSettings.fltIconSize))
        let objSize = CGSize(width: objLayout.fltWidth + Self.fltMargin * 2, height: objLayout.fltHeight + Self.fltMargin * 2)

        // Open away from the dock edge, vertically centered on the tile.
        let fltX: CGFloat = switch enmPosition {
        case .right: objAnchor.x - objSize.width
        case .left, .bottom: objAnchor.x
        }
        let objTarget = CGRect(x: fltX, y: objAnchor.y - objSize.height / 2, width: objSize.width, height: objSize.height)

        if blnIsVisible {
            objPanel.setFrame(objTarget, display: true)
            return
        }

        // Slide a few points out from the dock while fading in.
        let fltNudge: CGFloat = enmPosition == .right ? 8 : -8
        objPanel.setFrame(objTarget.offsetBy(dx: fltNudge, dy: 0), display: false)
        objPanel.alphaValue = 0
        objPanel.orderFrontRegardless()
        blnIsVisible = true
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.16
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(objTarget, display: true)
            objPanel.animator().alphaValue = 1
        }
    }

    /// Hides the player.
    func hide() {
        guard blnIsVisible, let objPanel else { return }
        blnIsVisible = false
        setMouseInside(false)
        objInteraction.cancel()
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.12
            objPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A quick re-show during the fade keeps the panel up.
                guard let self, !self.blnIsVisible else { return }
                objPanel.orderOut(nil)
                objPanel.contentView = nil
                self.objHostingView = nil
            }
        })
    }

    // MARK: - Panel

    /// Builds the borderless, non-activating panel.
    /// - Returns: The panel.
    private func makePanel() -> NSPanel {
        let objPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        objPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        objPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        objPanel.isOpaque = false
        objPanel.backgroundColor = .clear
        objPanel.hasShadow = false
        objPanel.hidesOnDeactivate = false
        objPanel.isReleasedWhenClosed = false
        objPanel.acceptsMouseMovedEvents = true
        self.objPanel = objPanel
        return objPanel
    }

    /// Puts the player view in the panel and wires its mouse events.
    /// - Parameter objPanel: The fly-out panel.
    private func installContent(in objPanel: NSPanel) {
        let objHost = TrackingHostingView(rootView: FlyoutView(
            objNowPlaying: objNowPlaying, objInteraction: objInteraction, objSettings: objSettings, fltMargin: Self.fltMargin
        ))
        objHost.onMouseMoved = { [weak self] objPoint in
            guard let self else { return }
            self.setMouseInside(true)
            if !self.objInteraction.blnIsPressing {
                self.objInteraction.hover(self.control(at: objPoint))
            }
        }
        objHost.onMouseExited = { [weak self] in
            guard let self else { return }
            self.objInteraction.hover(nil)
            self.setMouseInside(false)
        }
        objHost.onMouseDown = { [weak self] objPoint in
            guard let self else { return }
            self.objInteraction.press(self.control(at: objPoint))
        }
        objHost.onMouseDragged = { [weak self] objPoint in
            guard let self, let objLocal = self.playerPoint(objPoint) else { return }
            self.objInteraction.drag(toSeekFraction: self.layout.seekFraction(at: objLocal))
        }
        objHost.onMouseUp = { [weak self] objPoint in
            guard let self else { return }
            self.objInteraction.release()
            self.objInteraction.hover(self.control(at: objPoint))
        }
        objPanel.contentView = objHost
        objHostingView = objHost
    }

    /// Player layout at the current icon size.
    private var layout: NowPlayingLargeLayout {
        NowPlayingLargeLayout(fltIconSize: CGFloat(objSettings.fltIconSize))
    }

    /// Converts a panel point (bottom-left origin) to player-local (top-left origin, inside the margin).
    /// - Parameter objPoint: Panel-local point.
    /// - Returns: Player-local point.
    private func playerPoint(_ objPoint: CGPoint) -> CGPoint? {
        guard let objHostingView else { return nil }
        return CGPoint(x: objPoint.x - Self.fltMargin, y: objHostingView.bounds.height - objPoint.y - Self.fltMargin)
    }

    /// Control under a panel point.
    /// - Parameter objPoint: Panel-local point.
    /// - Returns: The control, or `nil`.
    private func control(at objPoint: CGPoint) -> NowPlayingLargeLayout.Control? {
        guard let objLocal = playerPoint(objPoint) else { return nil }
        let objLayout = layout
        guard objLocal.x >= 0, objLocal.y >= 0, objLocal.x <= objLayout.fltWidth, objLocal.y <= objLayout.fltHeight else { return nil }
        return objLayout.control(at: objLocal)
    }

    /// Records whether the cursor is over the fly-out and tells the owner on change.
    /// - Parameter blnInside: New state.
    private func setMouseInside(_ blnInside: Bool) {
        guard blnInside != blnMouseInside else { return }
        blnMouseInside = blnInside
        onMouseInsideChanged?(blnInside)
    }
}

/// The fly-out's content: the large player with room for its shadow.
struct FlyoutView: View {
    let objNowPlaying: NowPlayingService
    let objInteraction: NowPlayingInteraction
    let objSettings: SettingsStore
    let fltMargin: CGFloat

    var body: some View {
        NowPlayingLargeView(
            objNowPlaying: objNowPlaying,
            objInteraction: objInteraction,
            fltIconSize: CGFloat(objSettings.fltIconSize),
            enmSeekStyle: objSettings.enmSeekBarStyle
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .padding(fltMargin)
    }
}
