import AppKit
import CoreMedia
import IOKit.ps
import os
@preconcurrency import ScreenCaptureKit

/// Streams windows at up to 60 fps into `LiveThumbnailView`s while the picker is open.
///
/// One `SCStream` per window. ScreenCaptureKit only delivers a frame when the
/// window's content changes, so idle windows cost almost nothing.
@MainActor
final class LivePreviewService {
    /// Full refresh rate, and the reduced rate used to save battery.
    private static let intFullFps: Int32 = 60
    private static let intReducedFps: Int32 = 30

    /// Whether to drop to the reduced rate on battery or in Low Power Mode.
    var blnReduceOnBattery = true

    /// Frame rate for streams started now.
    private var intFramesPerSecond: Int32 {
        guard blnReduceOnBattery else { return Self.intFullFps }
        return Self.blnIsSavingPower ? Self.intReducedFps : Self.intFullFps
    }

    /// Whether the Mac is running on battery or in Low Power Mode.
    private static var blnIsSavingPower: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        guard let objInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let strSource = IOPSGetProvidingPowerSourceType(objInfo)?.takeUnretainedValue() as String? else { return false }
        return strSource == kIOPMBatteryPowerKey
    }

    /// Longest edges of a streamed frame, in pixels (2x the card size).
    private static let fltMaxPixelWidth: CGFloat = 400
    private static let fltMaxPixelHeight: CGFloat = 240

    private var arrObjStreams: [(objStream: SCStream, objOutput: StreamOutput)] = []
    // Bumped on every start/stop so a slow start can't revive a closed picker.
    private var intGeneration = 0

    /// Starts streaming windows into their views, replacing any running streams.
    /// - Parameter dictObjViews: Destination view per window ID.
    func start(_ dictObjViews: [CGWindowID: LiveThumbnailView]) async {
        stop()
        guard CGPreflightScreenCaptureAccess(), !dictObjViews.isEmpty else { return }
        let intMyGeneration = intGeneration

        guard let objContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              intMyGeneration == intGeneration else { return }

        for objWindow in objContent.windows {
            guard let objView = dictObjViews[objWindow.windowID] else { continue }

            let objFilter = SCContentFilter(desktopIndependentWindow: objWindow)
            let objStream = SCStream(filter: objFilter, configuration: configuration(for: objWindow), delegate: nil)
            let objOutput = StreamOutput(objView: objView)
            do {
                // Frames arrive on main, where the view lives.
                try objStream.addStreamOutput(objOutput, type: .screen, sampleHandlerQueue: .main)
                try await objStream.startCapture()
            } catch {
                continue
            }

            // Closed (or switched apps) while starting: tear this one down too.
            guard intMyGeneration == intGeneration else {
                Task { try? await objStream.stopCapture() }
                return
            }
            arrObjStreams.append((objStream, objOutput))
        }
    }

    /// Stops all streams.
    func stop() {
        intGeneration += 1
        for objEntry in arrObjStreams {
            let objStream = objEntry.objStream
            Task { try? await objStream.stopCapture() }
        }
        arrObjStreams.removeAll()
    }

    /// Stream settings: small BGRA frames at 60 fps, scaled to fit the card.
    /// - Parameter objWindow: Window to stream.
    /// - Returns: Configuration.
    private func configuration(for objWindow: SCWindow) -> SCStreamConfiguration {
        let objConfig = SCStreamConfiguration()
        let objSize = objWindow.frame.size
        let fltScale = objSize.width > 0 && objSize.height > 0
            ? min(Self.fltMaxPixelWidth / objSize.width, Self.fltMaxPixelHeight / objSize.height)
            : 1
        objConfig.width = max(1, Int((objSize.width * fltScale).rounded()))
        objConfig.height = max(1, Int((objSize.height * fltScale).rounded()))
        objConfig.scalesToFit = true
        objConfig.preservesAspectRatio = true
        objConfig.minimumFrameInterval = CMTime(value: 1, timescale: intFramesPerSecond)
        objConfig.queueDepth = 3
        objConfig.pixelFormat = kCVPixelFormatType_32BGRA
        objConfig.showsCursor = false
        objConfig.ignoreShadowsSingleWindow = true
        return objConfig
    }
}

/// Receives frames from one stream and hands complete ones to its view.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Debug: log delivered frames per second (`--log-fps`).
    private static let blnLogFps = CommandLine.arguments.contains("--log-fps")
    private static let objLogger = Logger(subsystem: "com.slynck.perchdock", category: "fps")

    private let objView: LiveThumbnailView
    private var intFrameCount = 0
    private var objWindowStart = ContinuousClock.now

    /// - Parameter objView: Destination view.
    init(objView: LiveThumbnailView) {
        self.objView = objView
    }

    /// Called on the main queue for each captured sample.
    /// - Parameters:
    ///   - stream: Source stream.
    ///   - sampleBuffer: Captured frame.
    ///   - type: Output type (only `.screen` is registered).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              // Idle/blank status frames carry no new pixels.
              let arrDictAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let intStatus = arrDictAttachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: intStatus) == .complete,
              let objPixelBuffer = sampleBuffer.imageBuffer,
              let objSurface = CVPixelBufferGetIOSurface(objPixelBuffer)?.takeUnretainedValue() else { return }

        if Self.blnLogFps {
            intFrameCount += 1
            if ContinuousClock.now - objWindowStart >= .seconds(1) {
                Self.objLogger.notice("live preview fps: \(self.intFrameCount)")
                intFrameCount = 0
                objWindowStart = .now
            }
        }

        let objSize = CGSize(width: CVPixelBufferGetWidth(objPixelBuffer), height: CVPixelBufferGetHeight(objPixelBuffer))
        // Already on the main queue (sampleHandlerQueue), so nothing actually crosses threads.
        nonisolated(unsafe) let objMainSurface = objSurface
        MainActor.assumeIsolated {
            objView.display(objMainSurface, objSize: objSize)
        }
    }
}
