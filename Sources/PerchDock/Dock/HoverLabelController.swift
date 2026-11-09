import AppKit
import SwiftUI
import Observation

/// Observable text of the hover label.
@MainActor
@Observable
final class HoverLabelState {
    var strText = ""
}

/// Glass capsule with the hovered app's name.
private struct HoverLabelView: View {
    let objState: HoverLabelState

    var body: some View {
        Text(objState.strText)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .dockGlass(cornerRadius: 11)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the app name next to the hovered icon, like the native Dock.
@MainActor
final class HoverLabelController {
    private static let fltGap: CGFloat = 6

    private let objState = HoverLabelState()
    private let objPanel: DockPanel
    private let objHostingView: NSHostingView<HoverLabelView>
    private var blnIsVisible = false

    /// Builds the hidden label panel. It ignores the mouse so it never blocks hovering.
    init() {
        objPanel = DockPanel(contentRect: .zero)
        objPanel.ignoresMouseEvents = true
        objHostingView = NSHostingView(rootView: HoverLabelView(objState: objState))
        objPanel.contentView = objHostingView
    }

    /// Shows (or moves) the label beside an icon.
    /// - Parameters:
    ///   - strText: App name.
    ///   - objAnchorPoint: Screen point on the icon's outer edge.
    ///   - enmPosition: Dock edge, deciding whether the label sits above or beside.
    func show(strText: String, objAnchorPoint: CGPoint, enmPosition: DockPosition) {
        if objState.strText != strText {
            objState.strText = strText
            objHostingView.layoutSubtreeIfNeeded()
        }
        let objSize = objHostingView.fittingSize

        let objOrigin: CGPoint = switch enmPosition {
        case .bottom: CGPoint(x: objAnchorPoint.x - objSize.width / 2, y: objAnchorPoint.y + Self.fltGap)
        case .left: CGPoint(x: objAnchorPoint.x + Self.fltGap, y: objAnchorPoint.y - objSize.height / 2)
        case .right: CGPoint(x: objAnchorPoint.x - Self.fltGap - objSize.width, y: objAnchorPoint.y - objSize.height / 2)
        }
        objPanel.setFrame(CGRect(origin: CGPoint(x: objOrigin.x.rounded(), y: objOrigin.y.rounded()), size: objSize), display: true)

        guard !blnIsVisible else { return }
        blnIsVisible = true
        objPanel.alphaValue = 0
        objPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.08
            objPanel.animator().alphaValue = 1
        }
    }

    /// Hides the label.
    func hide() {
        guard blnIsVisible else { return }
        blnIsVisible = false
        objPanel.orderOut(nil)
    }
}
