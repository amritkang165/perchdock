import AppKit
@preconcurrency import ScreenCaptureKit

/// "Peek": while a preview card is hovered, dims the screen and shows that window
/// at full size where it really is, without touching the actual window order.
///
/// Windows on other desktops and minimized ones have no place on this screen, so
/// they're shown centered instead.
@MainActor
final class PeekController {
    /// Just below the dock and its popovers, above every normal window.
    private static let objLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    /// Largest capture edge, in pixels (keeps 6K displays from producing huge images).
    private static let fltMaxPixels: CGFloat = 3200

    private var arrObjDimPanels: [DockPanel] = []
    private let objWindowPanel: DockPanel
    private let objImageView = NSImageView()
    private var objCaptureTask: Task<Void, Never>?
    /// Window currently peeked.
    private var intShownId: CGWindowID?

    /// Builds the (hidden) window layer.
    init() {
        objWindowPanel = Self.makePanel()
        objWindowPanel.hasShadow = true

        // Rounded like a real window.
        let objContainer = NSView()
        objContainer.wantsLayer = true
        objContainer.layer?.cornerRadius = 10
        objContainer.layer?.masksToBounds = true
        objImageView.imageScaling = .scaleProportionallyUpOrDown
        objImageView.autoresizingMask = [.width, .height]
        objContainer.addSubview(objImageView)
        objWindowPanel.contentView = objContainer
    }

    /// Peeks at a window.
    /// - Parameters:
    ///   - objWindow: Window to show.
    ///   - objPlaceholder: Its thumbnail, shown until the full-size capture lands.
    ///   - objFallbackScreen: Where to center windows that aren't on this screen.
    func show(_ objWindow: WindowInfo, objPlaceholder: NSImage?, objFallbackScreen: NSScreen?) {
        guard let intWindowId = objWindow.intWindowId, intWindowId != intShownId else { return }
        intShownId = intWindowId
        objCaptureTask?.cancel()

        let objFrame = targetFrame(for: objWindow, intWindowId: intWindowId, objPlaceholder: objPlaceholder,
                                   objFallbackScreen: objFallbackScreen)
        objImageView.image = objPlaceholder
        objImageView.frame = CGRect(origin: .zero, size: objFrame.size)
        objWindowPanel.setFrame(objFrame, display: true)
        // Dim every display, then put the window on top of the dimming.
        let blnWasHidden = !objWindowPanel.isVisible
        syncDimPanels()
        for objPanel in arrObjDimPanels {
            if blnWasHidden { objPanel.alphaValue = 0 }
            objPanel.orderFrontRegardless()
        }
        if blnWasHidden { objWindowPanel.alphaValue = 0 }
        objWindowPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.15
            for objPanel in arrObjDimPanels { objPanel.animator().alphaValue = 1 }
            objWindowPanel.animator().alphaValue = 1
        }

        // Swap in a sharp, full-size capture.
        let fltScale = NSScreen.screens.first { $0.frame.intersects(objFrame) }?.backingScaleFactor ?? 2
        objCaptureTask = Task { [weak self] in
            guard let objImage = await Self.capture(intWindowId, objPointSize: objFrame.size, fltScale: fltScale),
                  !Task.isCancelled, let self, self.intShownId == intWindowId else { return }
            self.objImageView.image = objImage
        }
    }

    /// Ends the peek.
    func hide() {
        guard intShownId != nil else { return }
        intShownId = nil
        objCaptureTask?.cancel()
        let arrObjPanels = arrObjDimPanels + [objWindowPanel]
        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.12
            for objPanel in arrObjPanels { objPanel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new peek during the fade keeps its panels.
                guard let self, self.intShownId == nil else { return }
                for objPanel in arrObjPanels { objPanel.orderOut(nil) }
            }
        })
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

    // MARK: - Capture

    /// Full-size still of a window (any desktop).
    /// - Parameters:
    ///   - intWindowId: Window.
    ///   - objPointSize: Size it'll be drawn at.
    ///   - fltScale: Display scale.
    /// - Returns: Image, or `nil` without Screen Recording permission.
    private static func capture(_ intWindowId: CGWindowID, objPointSize: CGSize, fltScale: CGFloat) async -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let objContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let objWindow = objContent.windows.first(where: { $0.windowID == intWindowId }) else { return nil }

        let objConfig = SCStreamConfiguration()
        var objPixels = CGSize(width: objPointSize.width * fltScale, height: objPointSize.height * fltScale)
        let fltShrink = min(1, fltMaxPixels / max(objPixels.width, objPixels.height, 1))
        objPixels = CGSize(width: objPixels.width * fltShrink, height: objPixels.height * fltShrink)
        objConfig.width = max(1, Int(objPixels.width))
        objConfig.height = max(1, Int(objPixels.height))
        objConfig.showsCursor = false
        objConfig.ignoreShadowsSingleWindow = true

        guard let objCGImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: objWindow), configuration: objConfig) else { return nil }
        return NSImage(cgImage: objCGImage, size: objPointSize)
    }
}
