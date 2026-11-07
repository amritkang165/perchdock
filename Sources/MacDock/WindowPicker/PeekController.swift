import AppKit
@preconcurrency import ScreenCaptureKit

/// "Peek": while a preview card is hovered, dims the screen and shows that window
/// at full size where it really is, without touching the actual window order.
///
/// The window is streamed live (video plays, text updates) with ScreenCaptureKit.
/// The peek only appears once the first sharp frame arrives, so it never flashes a
/// blurry upscaled thumbnail. Windows that can't stream (e.g. on another desktop)
/// fall back to a still, then to the card's thumbnail.
///
/// Windows on other desktops and minimized ones have no place on this screen, so
/// they're shown centered instead.
@MainActor
final class PeekController {
    /// Just below the dock and its popovers, above every normal window.
    private static let objLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    /// Largest capture edge, in pixels: native for full-screen windows up to 5K,
    /// while keeping 6K+ displays from producing huge frames.
    private static let fltMaxPixels: CGFloat = 5120
    /// How long to wait for a live frame before falling back to a still.
    private static let objLiveTimeout: Duration = .milliseconds(450)

    private var arrObjDimPanels: [DockPanel] = []
    private let objWindowPanel: DockPanel
    /// Layer the frames are drawn into (rounded like a real window).
    private let objContentLayer = CALayer()

    /// Window currently peeked.
    private var intShownId: CGWindowID?
    /// Bumped on every show/hide so late frames from an old stream are dropped.
    private var intGeneration = 0
    /// Whether the current peek has been put on screen.
    private var blnRevealed = false
    /// Whether the current peek has received a live frame.
    private var blnHasLiveFrame = false

    private var objStream: SCStream?
    private var objStreamOutput: PeekStreamOutput?
    private var objStartTask: Task<Void, Never>?
    private var objFallbackTask: Task<Void, Never>?
    private let objSampleQueue = DispatchQueue(label: "MacDock.peek.frames", qos: .userInteractive)

    /// Builds the (hidden) window layer.
    init() {
        objWindowPanel = Self.makePanel()
        objWindowPanel.hasShadow = true

        let objContainer = NSView()
        objContainer.wantsLayer = true
        objContentLayer.cornerRadius = 10
        objContentLayer.masksToBounds = true
        objContentLayer.contentsGravity = .resize
        // Frames arrive many times a second; don't cross-fade between them.
        objContentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        objContainer.layer?.addSublayer(objContentLayer)
        objWindowPanel.contentView = objContainer
    }

    /// Peeks at a window.
    /// - Parameters:
    ///   - objWindow: Window to show.
    ///   - objPlaceholder: Its thumbnail, used only if no sharp image can be captured.
    ///   - objFallbackScreen: Where to center windows that aren't on this screen.
    func show(_ objWindow: WindowInfo, objPlaceholder: NSImage?, objFallbackScreen: NSScreen?) {
        guard let intWindowId = objWindow.intWindowId, intWindowId != intShownId else { return }
        stopStream()
        intShownId = intWindowId
        intGeneration += 1
        let intToken = intGeneration
        blnHasLiveFrame = false

        let objFrame = targetFrame(for: objWindow, intWindowId: intWindowId, objPlaceholder: objPlaceholder,
                                   objFallbackScreen: objFallbackScreen)

        // Switching cards mid-peek: keep the dimming, but hide the old window until
        // the new one's first frame is ready.
        if blnRevealed { objWindowPanel.alphaValue = 0 }
        objContentLayer.contents = nil
        objWindowPanel.setFrame(objFrame, display: false)
        objContentLayer.frame = CGRect(origin: .zero, size: objFrame.size)

        // Start the live stream; the first frame reveals the peek.
        let fltScale = NSScreen.screens.first { $0.frame.intersects(objFrame) }?.backingScaleFactor ?? 2
        objStartTask = Task { [weak self] in
            await self?.startStream(intWindowId, objPointSize: objFrame.size, fltScale: fltScale, intToken: intToken)
        }

        // No live frame in time: show a still instead (or the thumbnail as a last resort).
        objFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.objLiveTimeout)
            guard !Task.isCancelled, let self, self.intGeneration == intToken, !self.blnHasLiveFrame else { return }
            let objStill = await Self.captureStill(intWindowId, objPointSize: objFrame.size, fltScale: fltScale)
            guard self.intGeneration == intToken, !self.blnHasLiveFrame else { return }
            let objImage = objStill ?? objPlaceholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            guard let objImage else { return }
            self.objContentLayer.contents = objImage
            self.reveal()
        }
    }

    /// Ends the peek.
    func hide() {
        guard intShownId != nil else { return }
        intShownId = nil
        intGeneration += 1
        stopStream()
        guard blnRevealed else { return }
        blnRevealed = false
        let arrObjPanels = arrObjDimPanels + [objWindowPanel]
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.12
            for objPanel in arrObjPanels { objPanel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new peek during the fade keeps its panels.
                guard let self, !self.blnRevealed else { return }
                for objPanel in arrObjPanels { objPanel.orderOut(nil) }
                self.objContentLayer.contents = nil
            }
        })
    }

    // MARK: - Showing

    /// Fades the dimming and the window in (or just the window, when switching cards).
    private func reveal() {
        if !blnRevealed {
            blnRevealed = true
            syncDimPanels()
            for objPanel in arrObjDimPanels {
                objPanel.alphaValue = 0
                objPanel.orderFrontRegardless()
            }
            objWindowPanel.alphaValue = 0
        }
        objWindowPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.15
            for objPanel in arrObjDimPanels { objPanel.animator().alphaValue = 1 }
            objWindowPanel.animator().alphaValue = 1
        }
    }

    /// Draws a live frame, revealing the peek on the first one.
    /// - Parameters:
    ///   - objFrame: Frame surface.
    ///   - intToken: Generation the stream belongs to.
    private func applyFrame(_ objFrame: PeekFrame, intToken: Int) {
        guard intToken == intGeneration else { return }
        objContentLayer.contents = objFrame.objSurface
        if !blnHasLiveFrame {
            blnHasLiveFrame = true
            objFallbackTask?.cancel()
            reveal()
        }
    }

    // MARK: - Live stream

    /// Starts streaming a window's content.
    /// - Parameters:
    ///   - intWindowId: Window.
    ///   - objPointSize: Size it'll be drawn at.
    ///   - fltScale: Display scale.
    ///   - intToken: Generation, to abandon the start if the peek moved on.
    private func startStream(_ intWindowId: CGWindowID, objPointSize: CGSize, fltScale: CGFloat, intToken: Int) async {
        guard CGPreflightScreenCaptureAccess(),
              let objContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              intToken == intGeneration,
              let objScWindow = objContent.windows.first(where: { $0.windowID == intWindowId }) else { return }

        let objConfig = Self.configuration(objPointSize: objPointSize, fltScale: fltScale)
        objConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        objConfig.queueDepth = 5
        objConfig.pixelFormat = kCVPixelFormatType_32BGRA

        let objOutput = PeekStreamOutput { [weak self] objFrame in
            Task { @MainActor [weak self] in
                self?.applyFrame(objFrame, intToken: intToken)
            }
        }
        let objNewStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: objScWindow),
                                    configuration: objConfig, delegate: nil)
        do {
            try objNewStream.addStreamOutput(objOutput, type: .screen, sampleHandlerQueue: objSampleQueue)
            try await objNewStream.startCapture()
        } catch {
            return
        }
        // The peek moved on while starting: shut this one down again.
        guard intToken == intGeneration else {
            try? await objNewStream.stopCapture()
            return
        }
        objStream = objNewStream
        objStreamOutput = objOutput
    }

    /// Stops the live stream and any pending start or fallback.
    private func stopStream() {
        objStartTask?.cancel()
        objFallbackTask?.cancel()
        if let objOldStream = objStream {
            Task { try? await objOldStream.stopCapture() }
        }
        objStream = nil
        objStreamOutput = nil
    }

    // MARK: - Layout

    /// Where to draw the window: its real frame on this desktop, otherwise centered.
    /// - Parameters:
    ///   - objWindow: Window.
    ///   - intWindowId: Its ID.
    ///   - objPlaceholder: Thumbnail (gives the aspect ratio when the frame is unknown).
    ///   - objFallbackScreen: Screen for centered peeks.
    /// - Returns: Frame in AppKit screen coordinates.
    private func targetFrame(for objWindow: WindowInfo, intWindowId: CGWindowID, objPlaceholder: NSImage?,
                             objFallbackScreen: NSScreen?) -> CGRect {
        let fltPrimaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let objBounds = (CGWindowListCopyWindowInfo([.optionIncludingWindow], intWindowId) as? [[String: Any]])?
            .first?[kCGWindowBounds as String] as? [String: CGFloat]
        // Window-server bounds have a top-left origin; flip to AppKit's.
        let objReal = objBounds.map {
            CGRect(x: $0["X"] ?? 0, y: fltPrimaryHeight - ($0["Y"] ?? 0) - ($0["Height"] ?? 0),
                   width: $0["Width"] ?? 0, height: $0["Height"] ?? 0)
        }
        if let objReal, !objWindow.blnIsOnOtherSpace, !objWindow.blnIsMinimized, objReal.width > 0, objReal.height > 0 {
            return objReal
        }

        // Not on this screen: centered, up to 80% of the visible area.
        let objVisible = (objFallbackScreen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let objSize = objReal?.size ?? objPlaceholder?.size ?? CGSize(width: 1200, height: 800)
        let fltFit = min(1, objVisible.width * 0.8 / max(objSize.width, 1), objVisible.height * 0.8 / max(objSize.height, 1))
        let objFitted = CGSize(width: (objSize.width * fltFit).rounded(), height: (objSize.height * fltFit).rounded())
        return CGRect(x: objVisible.midX - objFitted.width / 2, y: objVisible.midY - objFitted.height / 2,
                      width: objFitted.width, height: objFitted.height)
    }

    /// One dimming panel per display, sized to it.
    private func syncDimPanels() {
        let arrObjScreens = NSScreen.screens
        while arrObjDimPanels.count < arrObjScreens.count {
            let objPanel = Self.makePanel()
            objPanel.backgroundColor = NSColor.black.withAlphaComponent(0.4)
            arrObjDimPanels.append(objPanel)
        }
        while arrObjDimPanels.count > arrObjScreens.count {
            arrObjDimPanels.removeLast().orderOut(nil)
        }
        for (objPanel, objScreen) in zip(arrObjDimPanels, arrObjScreens) {
            objPanel.setFrame(objScreen.frame, display: false)
        }
    }

    /// A click-through, all-desktops panel at peek level.
    /// - Returns: Panel.
    private static func makePanel() -> DockPanel {
        let objPanel = DockPanel(contentRect: .zero)
        objPanel.level = objLevel
        objPanel.ignoresMouseEvents = true
        return objPanel
    }

    // MARK: - Still capture

    /// Capture settings sized to the drawn size at the display's scale.
    /// - Parameters:
    ///   - objPointSize: Size it'll be drawn at.
    ///   - fltScale: Display scale.
    /// - Returns: Configuration.
    private static func configuration(objPointSize: CGSize, fltScale: CGFloat) -> SCStreamConfiguration {
        let objConfig = SCStreamConfiguration()
        var objPixels = CGSize(width: objPointSize.width * fltScale, height: objPointSize.height * fltScale)
        let fltShrink = min(1, fltMaxPixels / max(objPixels.width, objPixels.height, 1))
        objPixels = CGSize(width: objPixels.width * fltShrink, height: objPixels.height * fltShrink)
        objConfig.width = max(1, Int(objPixels.width))
        objConfig.height = max(1, Int(objPixels.height))
        objConfig.showsCursor = false
        objConfig.ignoreShadowsSingleWindow = true
        return objConfig
    }

    /// Full-size still of a window (any desktop), for windows that can't stream.
    /// - Parameters:
    ///   - intWindowId: Window.
    ///   - objPointSize: Size it'll be drawn at.
    ///   - fltScale: Display scale.
    /// - Returns: Image, or `nil` without Screen Recording permission.
    private static func captureStill(_ intWindowId: CGWindowID, objPointSize: CGSize, fltScale: CGFloat) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(),
              let objContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let objScWindow = objContent.windows.first(where: { $0.windowID == intWindowId }) else { return nil }
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: objScWindow),
            configuration: configuration(objPointSize: objPointSize, fltScale: fltScale))
    }
}

/// A captured frame's backing surface, handed from the capture queue to the main actor.
private struct PeekFrame: @unchecked Sendable {
    let objSurface: IOSurfaceRef
}

/// Receives stream frames on the capture queue and forwards the complete ones.
private final class PeekStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let fnFrame: @Sendable (PeekFrame) -> Void

    /// - Parameter fnFrame: Called (on the capture queue) with each new frame.
    init(fnFrame: @escaping @Sendable (PeekFrame) -> Void) {
        self.fnFrame = fnFrame
    }

    /// Forwards a frame, skipping idle/blank ones (sent when the window hasn't changed).
    /// - Parameters:
    ///   - stream: Source stream.
    ///   - sampleBuffer: Frame.
    ///   - type: Output kind.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let arrDictAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let intStatus = arrDictAttachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: intStatus) == .complete,
              let objPixelBuffer = sampleBuffer.imageBuffer,
              let objSurface = CVPixelBufferGetIOSurface(objPixelBuffer)?.takeUnretainedValue() else { return }
        fnFrame(PeekFrame(objSurface: objSurface))
    }
}
