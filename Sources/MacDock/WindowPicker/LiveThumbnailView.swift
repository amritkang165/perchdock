import AppKit
import SwiftUI

/// Layer-hosting view that shows streamed window frames.
///
/// Frames (IOSurfaces) go straight into a `CALayer`, so 60 fps updates never
/// re-render SwiftUI. Until the first frame arrives it's transparent, letting
/// the snapshot underneath show through.
@MainActor
final class LiveThumbnailView: NSView {
    private let objFrameLayer = CALayer()
    private var objContentSize: CGSize = .zero

    /// Builds the (empty) view.
    init() {
        super.init(frame: .zero)
        // Layer-hosting: we own the layer tree.
        layer = CALayer()
        wantsLayer = true
        objFrameLayer.contentsGravity = .resizeAspect
        objFrameLayer.cornerRadius = 6
        objFrameLayer.masksToBounds = true
        layer?.addSublayer(objFrameLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows one frame.
    /// - Parameters:
    ///   - objSurface: Frame pixels.
    ///   - objSize: Frame size in pixels (used for the aspect-fit rect).
    func display(_ objSurface: IOSurface, objSize: CGSize) {
        CATransaction.begin()
        // No implicit cross-fade between frames.
        CATransaction.setDisableActions(true)
        objFrameLayer.contents = objSurface
        if objSize != objContentSize {
            objContentSize = objSize
            objFrameLayer.frame = fittedRect()
        }
        CATransaction.commit()
    }

    /// Re-fits the frame layer when the view resizes.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        objFrameLayer.frame = fittedRect()
        CATransaction.commit()
    }

    /// Aspect-fit rect of the current frame inside the view, so rounded corners
    /// hug the window image rather than the letterbox.
    /// - Returns: Frame-layer rect in view coordinates.
    private func fittedRect() -> CGRect {
        guard objContentSize.width > 0, objContentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let fltScale = min(bounds.width / objContentSize.width, bounds.height / objContentSize.height)
        let objSize = CGSize(width: objContentSize.width * fltScale, height: objContentSize.height * fltScale)
        return CGRect(
            x: ((bounds.width - objSize.width) / 2).rounded(),
            y: ((bounds.height - objSize.height) / 2).rounded(),
            width: objSize.width.rounded(),
            height: objSize.height.rounded()
        )
    }
}

/// Embeds an existing `LiveThumbnailView` in SwiftUI.
struct LiveThumbnailHost: NSViewRepresentable {
    let objView: LiveThumbnailView

    /// Returns the shared live view.
    /// - Parameter context: Representable context.
    /// - Returns: The live view.
    func makeNSView(context: Context) -> LiveThumbnailView {
        objView
    }

    /// Nothing to update; frames are pushed directly.
    /// - Parameters:
    ///   - nsView: The live view.
    ///   - context: Representable context.
    func updateNSView(_ nsView: LiveThumbnailView, context: Context) {}
}
