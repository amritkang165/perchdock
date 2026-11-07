import AppKit
import SwiftUI

/// SwiftUI host that reports mouse activity and file drops in panel coordinates
/// (bottom-left origin).
///
/// SwiftUI's own hover and gesture handling is unreliable in windows of an
/// inactive app, which a dock always is; raw AppKit events with an
/// `.activeAlways` tracking area are not.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    /// Mouse position while inside, `nil` when it leaves.
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    /// Left button pressed, dragged (also outside the view), and released.
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    /// Right-click (or control-click), with the event for positioning a context menu.
    var onRightMouseDown: ((CGPoint, NSEvent) -> Void)?

    /// File drag hovering over the view: return the operation to show (or `[]`).
    var onFileDragUpdated: (([URL], CGPoint) -> NSDragOperation)?
    /// File drag ended without a drop.
    var onFileDragExited: (() -> Void)?
    /// Files dropped: return whether they were accepted.
    var onFileDrop: (([URL], CGPoint) -> Bool)?

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

    /// Opts in to receiving file drags.
    func enableFileDrops() {
        registerForDraggedTypes([.fileURL])
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

    // MARK: - Mouse

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
        onMouseExited?()
    }

    /// Reports a press; actions fire on release like native buttons.
    /// - Parameter event: Mouse event.
    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click on macOS.
        if event.modifierFlags.contains(.control) {
            onRightMouseDown?(localPoint(event), event)
            return
        }
        onMouseDown?(localPoint(event))
    }

    /// Reports drag movement (delivered even outside the view while the button is held).
    /// - Parameter event: Mouse event.
    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(localPoint(event))
    }

    /// Reports a release.
    /// - Parameter event: Mouse event.
    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        onMouseUp?(localPoint(event))
    }

    /// Reports a right-click.
    /// - Parameter event: Mouse event.
    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(localPoint(event), event)
    }

    // MARK: - File drops

    /// Starts tracking a file drag.
    /// - Parameter sender: Drag info.
    /// - Returns: Operation to show.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    /// Updates a file drag's target.
    /// - Parameter sender: Drag info.
    /// - Returns: Operation to show.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDragUpdated?(fileUrls(sender), localPoint(sender.draggingLocation)) ?? []
    }

    /// Ends a file drag that left the view.
    /// - Parameter sender: Drag info.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragExited?()
    }

    /// Handles dropped files.
    /// - Parameter sender: Drag info.
    /// - Returns: Whether the drop was accepted.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileDrop?(fileUrls(sender), localPoint(sender.draggingLocation)) ?? false
    }

    /// Reads file URLs from a drag.
    /// - Parameter objInfo: Drag info.
    /// - Returns: Dragged file URLs.
    private func fileUrls(_ objInfo: NSDraggingInfo) -> [URL] {
        objInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: - Coordinates

    /// Converts an event location to view coordinates with a bottom-left origin.
    /// - Parameter objEvent: Mouse event.
    /// - Returns: Local point.
    private func localPoint(_ objEvent: NSEvent) -> CGPoint {
        localPoint(objEvent.locationInWindow)
    }

    /// Converts a window location to view coordinates with a bottom-left origin.
    /// - Parameter objWindowPoint: Point in window coordinates.
    /// - Returns: Local point, independent of whether the view is flipped.
    private func localPoint(_ objWindowPoint: CGPoint) -> CGPoint {
        var objPoint = convert(objWindowPoint, from: nil)
        if isFlipped {
            objPoint.y = bounds.height - objPoint.y
        }
        return objPoint
    }
}
