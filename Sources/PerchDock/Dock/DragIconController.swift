import AppKit
import SwiftUI
import Observation

/// Observable contents of the floating drag icon.
@MainActor
@Observable
final class DragIconState {
    var objIcon: NSImage?
    var fltSize: CGFloat = 52
    var blnRemoving = false
}

/// The icon that follows the cursor while reordering, drawn in its own panel so
/// it isn't clipped by the dock's bounds when dragged off to be removed.
private struct DragIconView: View {
    let objState: DragIconState

    var body: some View {
        VStack(spacing: 4) {
            Text("Remove")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.regularMaterial))
                .opacity(objState.blnRemoving ? 1 : 0)

            if let objIcon = objState.objIcon {
                Image(nsImage: objIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: objState.fltSize, height: objState.fltSize)
                    .opacity(objState.blnRemoving ? 0.6 : 1)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: objState.blnRemoving)
        // Icon flush with the panel bottom so its center lands on the cursor.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// Shows and moves the floating drag icon, and animates it landing or vanishing.
@MainActor
final class DragIconController {
    private static let fltLabelSpace: CGFloat = 26

    private let objState = DragIconState()
    private let objPanel: DockPanel

    /// Builds the hidden panel. It ignores the mouse so it never blocks the drag.
    init() {
        objPanel = DockPanel(contentRect: .zero)
        objPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        objPanel.ignoresMouseEvents = true
        objPanel.contentView = NSHostingView(rootView: DragIconView(objState: objState))
    }

    /// Shows the icon under the cursor.
    /// - Parameters:
    ///   - objIcon: App icon.
    ///   - fltSize: Icon size.
    ///   - objScreenPoint: Cursor location.
    func begin(objIcon: NSImage, fltSize: CGFloat, objScreenPoint: CGPoint) {
        objState.objIcon = objIcon
        objState.fltSize = fltSize
        objState.blnRemoving = false
        objPanel.alphaValue = 1
        objPanel.setFrame(frame(centeredAt: objScreenPoint), display: true)
        objPanel.orderFrontRegardless()
    }

    /// Follows the cursor.
    /// - Parameters:
    ///   - objScreenPoint: Cursor location.
    ///   - blnRemoving: Whether releasing now would remove the item.
    func move(to objScreenPoint: CGPoint, blnRemoving: Bool) {
        objState.blnRemoving = blnRemoving
        objPanel.setFrame(frame(centeredAt: objScreenPoint), display: true)
    }

    /// Glides the icon into its slot, then hides it.
    /// - Parameter objScreenPoint: Center of the destination slot.
    func land(at objScreenPoint: CGPoint) {
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.16
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(frame(centeredAt: objScreenPoint), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.objPanel.orderOut(nil) }
        })
    }

    /// "Poof": grows slightly and fades out, for a removed item.
    func vanish() {
        let objFrame = objPanel.frame
        let objGrown = objFrame.insetBy(dx: -objFrame.width * 0.15, dy: -objFrame.height * 0.15)
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.18
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(objGrown, display: true)
            objPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.objPanel.orderOut(nil) }
        })
    }

    /// Panel frame with the icon centered on a point (label space sits above it).
    /// - Parameter objPoint: Screen point for the icon center.
    /// - Returns: Panel frame.
    private func frame(centeredAt objPoint: CGPoint) -> CGRect {
        let fltWidth = max(objState.fltSize, 80)
        let fltHeight = objState.fltSize + Self.fltLabelSpace
        return CGRect(
            x: objPoint.x - fltWidth / 2,
            y: objPoint.y - objState.fltSize / 2,
            width: fltWidth,
            height: fltHeight
        )
    }
}
