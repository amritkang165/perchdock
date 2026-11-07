import AppKit
@preconcurrency import ScreenCaptureKit

/// Captures and caches small window thumbnails with ScreenCaptureKit.
///
/// Needs Screen Recording permission. Without it every capture returns `nil`
/// and the picker shows the app icon instead.
@MainActor
final class ThumbnailService {
    private static let strAskedKey = "AskedForScreenRecording"

    /// Longest edge of a captured thumbnail, in pixels (about 2x the on-screen size).
    private static let fltMaxPixelWidth: CGFloat = 400
    private static let fltMaxPixelHeight: CGFloat = 240

    /// Last captured image per window, shown instantly while a fresh one is taken.
    private var dictObjCache: [CGWindowID: NSImage] = [:]

    /// Whether Screen Recording is granted.
    var blnHasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording prompt once; afterwards the user can
    /// enable it from the menu bar item. macOS applies the grant after a relaunch.
    func requestPermissionIfNeeded() {
        guard !blnHasPermission, !UserDefaults.standard.bool(forKey: Self.strAskedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.strAskedKey)
        _ = CGRequestScreenCaptureAccess()
    }

    /// Returns the most recent thumbnail for a window, if one was captured before.
    /// - Parameter intWindowId: Window ID.
    /// - Returns: Cached image or `nil`.
    func cachedThumbnail(for intWindowId: CGWindowID) -> NSImage? {
        dictObjCache[intWindowId]
    }

    /// Captures fresh thumbnails, reporting each one as soon as it's ready.
    /// - Parameters:
    ///   - arrIntWindowIds: Windows to capture, in display order.
    ///   - onImage: Called on the main actor with each captured image.
    func captureThumbnails(for arrIntWindowIds: [CGWindowID], onImage: (CGWindowID, NSImage) -> Void) async {
        guard blnHasPermission, !arrIntWindowIds.isEmpty else { return }

        // One shareable-content query per picker open; it covers windows on all Spaces.
        guard let objContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        let dictObjWindows = Dictionary(objContent.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { objFirst, _ in objFirst })

        for intWindowId in arrIntWindowIds {
            guard !Task.isCancelled else { return }
            guard let objWindow = dictObjWindows[intWindowId] else { continue }

            let objFilter = SCContentFilter(desktopIndependentWindow: objWindow)
            let objConfig = SCStreamConfiguration()
            let objPixelSize = fittedPixelSize(for: objWindow.frame.size)
            objConfig.width = Int(objPixelSize.width)
            objConfig.height = Int(objPixelSize.height)
            objConfig.showsCursor = false
            objConfig.ignoreShadowsSingleWindow = true

            guard let objCGImage = try? await SCScreenshotManager.captureImage(contentFilter: objFilter, configuration: objConfig) else { continue }
            guard !Task.isCancelled else { return }

            let objImage = NSImage(cgImage: objCGImage, size: NSSize(width: objCGImage.width, height: objCGImage.height))
            dictObjCache[intWindowId] = objImage
            onImage(intWindowId, objImage)
        }
    }

    /// Scales a window size down to fit the thumbnail pixel box, keeping its aspect ratio.
    /// - Parameter objWindowSize: Window size in points.
    /// - Returns: Capture size in pixels.
    private func fittedPixelSize(for objWindowSize: CGSize) -> CGSize {
        guard objWindowSize.width > 0, objWindowSize.height > 0 else {
            return CGSize(width: Self.fltMaxPixelWidth, height: Self.fltMaxPixelHeight)
        }
        let fltScale = min(Self.fltMaxPixelWidth / objWindowSize.width, Self.fltMaxPixelHeight / objWindowSize.height)
        return CGSize(width: max(1, (objWindowSize.width * fltScale).rounded()), height: max(1, (objWindowSize.height * fltScale).rounded()))
    }
}
