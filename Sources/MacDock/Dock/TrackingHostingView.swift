import AppKit
import SwiftUI

/// SwiftUI host that reports mouse movement and clicks in panel coordinates.
///
/// SwiftUI's `onHover` doesn't fire reliably in windows of an inactive app,
/// which a dock always is. An `.activeAlways` tracking area does.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    /// Mouse position (bottom-left origin) while inside, `nil` when it leaves.
    var onMouseMoved: ((CGPoint?) -> Void)?

    /// Left-click location (bottom-left origin) on mouse-up.
    var onMouseUp: ((CGPoint) -> Void)?

    private var objTrackingArea: NSTrackingArea?

    /// Creates the host and stops it from resizing the panel to fit its content.
    /// - Parameter rootView: SwiftUI content.
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replaces the tracking area whenever the view's geometry changes.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let objTrackingArea {
            removeTrackingArea(objTrackingArea)
        }
        let objArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(objArea)
        objTrackingArea = objArea
    }

    /// Accept the first click even though the panel is never key.
    /// - Parameter event: The click event.
    /// - Returns: Always `true`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Reports entry as a move so hover starts immediately.
    /// - Parameter event: Mouse event.
    override func mouseEntered(with event: NSEvent) {
        onMouseMoved?(localPoint(event))
    }

    /// Reports the current mouse position.
    /// - Parameter event: Mouse event.
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(localPoint(event))
    }

    /// Reports that the mouse left the view.
    /// - Parameter event: Mouse event.
    override func mouseExited(with event: NSEvent) {
        onMouseMoved?(nil)
    }

    /// Swallowed; the action fires on mouse-up like a native button.
    /// - Parameter event: Mouse event.
    override func mouseDown(with event: NSEvent) {}

    /// Reports a click.
    /// - Parameter event: Mouse event.
    override func mouseUp(with event: NSEvent) {
        onMouseUp?(localPoint(event))
    }

    /// Converts an event location to view coordinates with a bottom-left origin.
    /// - Parameter objEvent: Mouse event.
    /// - Returns: Local point, independent of whether the view is flipped.
    private func localPoint(_ objEvent: NSEvent) -> CGPoint {
        var objPoint = convert(objEvent.locationInWindow, from: nil)
        if isFlipped {
            objPoint.y = bounds.height - objPoint.y
        }
        return objPoint
    }
}
