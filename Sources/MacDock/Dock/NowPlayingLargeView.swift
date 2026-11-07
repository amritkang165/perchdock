import AppKit
import SwiftUI

/// Where everything sits in the large Now Playing player, shared by drawing and
/// hit-testing so clicks always land on what's drawn.
///
/// Left to right: square artwork, title over artist, then large previous /
/// play-pause / next buttons with the seek bar beneath them. One icon tall, so it
/// fits a bottom dock as a tile and a side dock's fly-out alike.
///
/// Coordinates are local with a top-left origin; proportions scale with the
/// dock's icon size.
struct NowPlayingLargeLayout {
    /// A control under the cursor.
    enum Control: Equatable {
        case artwork
        case previous
        case playPause
        case next
        /// Seek bar, at a 0…1 position.
        case seek(Double)
    }

    let fltWidth: CGFloat
    let fltHeight: CGFloat
    let objArtwork: CGRect
    let objTitle: CGRect
    let objArtist: CGRect
    let objPrevious: CGRect
    let objPlayPause: CGRect
    let objNext: CGRect
    /// Seek bar's hit/draw strip (the line runs along its middle).
    let objSeekBar: CGRect
    /// Glyph sizes for the skip buttons and play/pause.
    let fltSkipGlyph: CGFloat
    let fltPlayGlyph: CGFloat

    /// Builds the layout for an icon size.
    /// - Parameter fltIconSize: Dock icon size (the player's height).
    init(fltIconSize: CGFloat) {
        let fltIcon = fltIconSize
        let fltPad = (fltIcon * 0.19).rounded()
        fltHeight = fltIcon
        objArtwork = CGRect(x: 0, y: 0, width: fltIcon, height: fltIcon)

        // Title over artist.
        let fltTextX = fltIcon + fltPad
        let fltTextWidth = (fltIcon * 1.77).rounded()
        objTitle = CGRect(x: fltTextX, y: fltIcon * 0.2, width: fltTextWidth, height: fltIcon * 0.3)
        objArtist = CGRect(x: fltTextX, y: fltIcon * 0.52, width: fltTextWidth, height: fltIcon * 0.26)

        // Transport row in equal thirds, seek strip beneath it.
        let fltControlsX = fltTextX + fltTextWidth + fltPad
        let fltControlsWidth = (fltIcon * 2.46).rounded()
        let fltThird = fltControlsWidth / 3
        let fltRowTop = fltIcon * 0.06
        let fltRowHeight = fltIcon * 0.52
        objPrevious = CGRect(x: fltControlsX, y: fltRowTop, width: fltThird, height: fltRowHeight)
        objPlayPause = objPrevious.offsetBy(dx: fltThird, dy: 0)
        objNext = objPlayPause.offsetBy(dx: fltThird, dy: 0)
        objSeekBar = CGRect(x: fltControlsX, y: fltIcon * 0.66, width: fltControlsWidth, height: fltIcon * 0.24)

        fltSkipGlyph = (fltIcon * 0.29).rounded()
        fltPlayGlyph = (fltIcon * 0.4).rounded()
        fltWidth = fltControlsX + fltControlsWidth + (fltIcon * 0.23).rounded()
    }

    /// Control at a local point (the seek strip is generous so the thin line is easy to grab).
    /// - Parameter objPoint: Point (top-left origin).
    /// - Returns: The control, or `nil` over empty space.
    func control(at objPoint: CGPoint) -> Control? {
        if objArtwork.contains(objPoint) { return .artwork }
        for (objFrame, enmControl) in [(objPrevious, Control.previous), (objPlayPause, .playPause), (objNext, .next)]
            where objFrame.contains(objPoint) {
            return enmControl
        }
        if objPoint.x >= objSeekBar.minX - 6, objPoint.x <= objSeekBar.maxX + 6, objPoint.y >= objPrevious.maxY {
            return .seek(seekFraction(at: objPoint))
        }
        return nil
    }

    /// Track position under a point, along the seek bar.
    /// - Parameter objPoint: Local point.
    /// - Returns: 0…1.
    func seekFraction(at objPoint: CGPoint) -> Double {
        Double(min(1, max(0, (objPoint.x - objSeekBar.minX) / max(objSeekBar.width, 1))))
    }
}

/// Hover, press and seek-scrub state for the large player, shared by the dock
/// tile and the side-dock fly-out (both feed it raw mouse events).
@MainActor
@Observable
final class NowPlayingInteraction {
    /// Control under the cursor (seek positions collapsed to one value).
    private(set) var enmHover: NowPlayingLargeLayout.Control?
    /// Seek position being dragged, shown instead of the real one until release.
    private(set) var dblScrub: Double?

    @ObservationIgnored private var enmPressed: NowPlayingLargeLayout.Control?
    @ObservationIgnored private let objNowPlaying: NowPlayingService

    /// Whether a press on one of the player's controls is in progress.
    var blnIsPressing: Bool { enmPressed != nil }

    /// Creates the handler.
    /// - Parameter objNowPlaying: Playback to control.
    init(objNowPlaying: NowPlayingService) {
        self.objNowPlaying = objNowPlaying
    }

    /// Updates the hover highlight.
    /// - Parameter enmControl: Control under the cursor, or `nil`.
    func hover(_ enmControl: NowPlayingLargeLayout.Control?) {
        // The highlight only cares that it's the seek bar, not where on it.
        var enmNormalized = enmControl
        if case .seek = enmControl { enmNormalized = .seek(0) }
        if enmHover != enmNormalized { enmHover = enmNormalized }
    }

    /// Starts a press.
    /// - Parameter enmControl: Control under the cursor.
    /// - Returns: `true` if the press landed on a control (and is now owned by the player).
    @discardableResult
    func press(_ enmControl: NowPlayingLargeLayout.Control?) -> Bool {
        guard let enmControl else { return false }
        // Nothing to seek in a live stream.
        if case .seek = enmControl, objNowPlaying.dblDuration <= 0 { return false }
        enmPressed = enmControl
        if case .seek(let dblFraction) = enmControl { dblScrub = dblFraction }
        return true
    }

    /// Follows a drag (only seeking responds).
    /// - Parameter dblFraction: Seek position under the cursor.
    func drag(toSeekFraction dblFraction: Double) {
        guard case .seek = enmPressed else { return }
        dblScrub = dblFraction
    }

    /// Finishes a press, running its control.
    func release() {
        let enmControl = enmPressed
        let dblFinalScrub = dblScrub
        enmPressed = nil
        dblScrub = nil
        switch enmControl {
        case .artwork:
            // Bring the player forward (Spotify, Music, the browser…).
            if let strBundleId = objNowPlaying.objTrack?.strBundleId,
               let objApp = NSRunningApplication.runningApplications(withBundleIdentifier: strBundleId).first {
                objApp.activate()
            }
        case .previous:
            objNowPlaying.send(.previousTrack)
        case .playPause:
            objNowPlaying.send(.togglePlayPause)
        case .next:
            objNowPlaying.send(.nextTrack)
        case .seek(let dblPressFraction):
            objNowPlaying.seek(to: (dblFinalScrub ?? dblPressFraction) * objNowPlaying.dblDuration)
        case nil:
            break
        }
    }

    /// Drops any press, scrub and hover (e.g. the player disappeared).
    func cancel() {
        enmPressed = nil
        dblScrub = nil
        enmHover = nil
    }
}

/// The large player: artwork, scrolling title and artist, large transport buttons
/// and a squiggly or straight seek bar.
struct NowPlayingLargeView: View {
    let objNowPlaying: NowPlayingService
    let objInteraction: NowPlayingInteraction
    let fltIconSize: CGFloat
    let enmSeekStyle: SeekBarStyle

    var body: some View {
        let objLayout = NowPlayingLargeLayout(fltIconSize: fltIconSize)
        let fltCorner = fltIconSize * 0.21
        let objTrack = objNowPlaying.objTrack
        let blnPlaying = objNowPlaying.blnIsPlaying

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                .fill(Color(white: 0.08).opacity(0.97))

            NowPlayingTileView(objNowPlaying: objNowPlaying, fltSize: objLayout.objArtwork.width)
                .frame(width: objLayout.objArtwork.width, height: objLayout.objArtwork.height)

            MarqueeText(strText: objTrack?.strTitle ?? "Not Playing",
                        objFont: .system(size: fltIconSize * 0.25, weight: .semibold),
                        objColor: .white, blnRunning: blnPlaying)
                .frame(width: objLayout.objTitle.width, height: objLayout.objTitle.height)
                .offset(x: objLayout.objTitle.minX, y: objLayout.objTitle.minY)

            artistLine(objLayout, blnPlaying: blnPlaying)

            glyph("backward.fill", objFrame: objLayout.objPrevious, fltSize: objLayout.fltSkipGlyph, enmControl: .previous)
            glyph(blnPlaying ? "pause.fill" : "play.fill", objFrame: objLayout.objPlayPause,
                  fltSize: objLayout.fltPlayGlyph, enmControl: .playPause)
            glyph("forward.fill", objFrame: objLayout.objNext, fltSize: objLayout.fltSkipGlyph, enmControl: .next)

            SeekBarView(objNowPlaying: objNowPlaying, dblScrub: objInteraction.dblScrub, enmStyle: enmSeekStyle,
                        blnActive: objInteraction.dblScrub != nil || objInteraction.enmHover == .seek(0),
                        fltIconSize: fltIconSize)
                .frame(width: objLayout.objSeekBar.width, height: objLayout.objSeekBar.height)
                .offset(x: objLayout.objSeekBar.minX, y: objLayout.objSeekBar.minY)
        }
        .frame(width: objLayout.fltWidth, height: objLayout.fltHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: fltCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    /// Artist, or the scrub position while dragging the seek bar.
    /// - Parameters:
    ///   - objLayout: Layout.
    ///   - blnPlaying: Whether it's playing (scrolls only then).
    /// - Returns: The line.
    @ViewBuilder
    private func artistLine(_ objLayout: NowPlayingLargeLayout, blnPlaying: Bool) -> some View {
        let objFont = Font.system(size: fltIconSize * 0.22)
        Group {
            if let dblScrub = objInteraction.dblScrub {
                let dblDuration = objNowPlaying.dblDuration
                Text("\(Self.time(dblScrub * dblDuration)) / \(Self.time(dblDuration))")
                    .font(objFont.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarqueeText(strText: objNowPlaying.objTrack?.strArtist ?? "",
                            objFont: objFont, objColor: .white.opacity(0.6), blnRunning: blnPlaying)
            }
        }
        .frame(width: objLayout.objArtist.width, height: objLayout.objArtist.height)
        .offset(x: objLayout.objArtist.minX, y: objLayout.objArtist.minY)
    }

    /// A transport symbol with a soft highlight while hovered.
    /// - Parameters:
    ///   - strSymbol: SF Symbol.
    ///   - objFrame: Button frame.
    ///   - fltSize: Glyph size.
    ///   - enmControl: Control it represents (for hover).
    /// - Returns: The glyph.
    private func glyph(_ strSymbol: String, objFrame: CGRect, fltSize: CGFloat,
                       enmControl: NowPlayingLargeLayout.Control) -> some View {
        let blnHovered = objInteraction.enmHover == enmControl
        let fltHighlight = min(objFrame.width, objFrame.height) * 0.95
        return Image(systemName: strSymbol)
            .font(.system(size: fltSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: fltHighlight, height: fltHighlight)
            .background(Circle().fill(Color.white.opacity(blnHovered ? 0.14 : 0)))
            .frame(width: objFrame.width, height: objFrame.height)
            .offset(x: objFrame.minX, y: objFrame.minY)
            .animation(.easeOut(duration: 0.12), value: blnHovered)
    }

    /// "m:ss" (or "h:mm:ss").
    /// - Parameter dblSeconds: Seconds.
    /// - Returns: Formatted time.
    static func time(_ dblSeconds: Double) -> String {
        let intTotal = Int(max(0, dblSeconds).rounded(.down))
        let intHours = intTotal / 3600
        let intMinutes = (intTotal % 3600) / 60
        let intSecs = intTotal % 60
        return intHours > 0
            ? String(format: "%d:%02d:%02d", intHours, intMinutes, intSecs)
            : String(format: "%d:%02d", intMinutes, intSecs)
    }
}

/// Seek bar: the played part as a gently moving wave (or a solid line), the rest
/// a faint straight line, with a playhead.
private struct SeekBarView: View {
    let objNowPlaying: NowPlayingService
    /// Position being dragged, if any.
    let dblScrub: Double?
    let enmStyle: SeekBarStyle
    /// Hovered or dragged (the playhead grows).
    let blnActive: Bool
    let fltIconSize: CGFloat

    var body: some View {
        let blnPlaying = objNowPlaying.blnIsPlaying
        let blnSquiggly = enmStyle == .squiggly
        // The wave animates smoothly; a straight bar only needs to creep forward.
        TimelineView(.animation(minimumInterval: blnSquiggly ? 1.0 / 30 : 0.5, paused: !blnPlaying)) { objContext in
            let dblDuration = objNowPlaying.dblDuration
            let dblFraction = dblScrub ?? (dblDuration > 0 ? objNowPlaying.elapsed(at: objContext.date) / dblDuration : 0)
            let dblPhase = objContext.date.timeIntervalSinceReferenceDate
            Canvas { objCanvas, objSize in
                draw(in: &objCanvas, objSize: objSize, fltFraction: CGFloat(min(1, max(0, dblFraction))),
                     blnWave: blnSquiggly && blnPlaying, dblPhase: dblPhase)
            }
        }
    }

    /// Draws the track, the played part and the playhead.
    /// - Parameters:
    ///   - objCanvas: Canvas.
    ///   - objSize: Canvas size.
    ///   - fltFraction: Played portion 0…1.
    ///   - blnWave: Draw the played part as a wave (squiggly style while playing).
    ///   - dblPhase: Animation time, for the wave's drift.
    private func draw(in objCanvas: inout GraphicsContext, objSize: CGSize, fltFraction: CGFloat, blnWave: Bool, dblPhase: Double) {
        let fltThickness = max(2.5, fltIconSize * 0.055)
        let fltMid = objSize.height / 2
        let fltPlayed = objSize.width * fltFraction
        let fltGap = fltThickness * 1.2

        // Unplayed: faint, straight.
        if fltPlayed + fltGap < objSize.width {
            var objRest = Path()
            objRest.move(to: CGPoint(x: fltPlayed + fltGap, y: fltMid))
            objRest.addLine(to: CGPoint(x: objSize.width, y: fltMid))
            objCanvas.stroke(objRest, with: .color(.white.opacity(0.22)),
                             style: StrokeStyle(lineWidth: fltThickness, lineCap: .round))
        }

        // Played: wave (drifting right) or a solid line.
        if fltPlayed > 0.5 {
            var objPlayedPath = Path()
            if blnWave {
                let fltAmplitude = fltThickness * 0.9
                let fltWavelength = fltThickness * 4.4
                let fltShift = CGFloat(dblPhase.truncatingRemainder(dividingBy: 1.6) / 1.6) * fltWavelength
                objPlayedPath.move(to: CGPoint(x: 0, y: fltMid))
                var fltX: CGFloat = 0
                while fltX <= fltPlayed {
                    // Taper the wave into the playhead so it meets it on the centerline.
                    let fltTaper = min(1, (fltPlayed - fltX) / fltWavelength, fltX / fltWavelength)
                    let fltY = fltMid + sin((fltX - fltShift) / fltWavelength * 2 * .pi) * fltAmplitude * fltTaper
                    objPlayedPath.addLine(to: CGPoint(x: fltX, y: fltY))
                    fltX += 0.75
                }
            } else {
                objPlayedPath.move(to: CGPoint(x: 0, y: fltMid))
                objPlayedPath.addLine(to: CGPoint(x: fltPlayed, y: fltMid))
            }
            objCanvas.stroke(objPlayedPath, with: .color(.white),
                             style: StrokeStyle(lineWidth: fltThickness * (blnWave ? 0.85 : 1), lineCap: .round, lineJoin: .round))
        }

        // Playhead: a short upright capsule, taller while hovered or dragged.
        let fltHeadHeight = fltThickness * (blnActive ? 4.4 : 3.4)
        let fltHeadWidth = fltThickness * (blnActive ? 1.4 : 1.1)
        let objHead = CGRect(x: fltPlayed - fltHeadWidth / 2, y: fltMid - fltHeadHeight / 2, width: fltHeadWidth, height: fltHeadHeight)
        objCanvas.fill(Path(roundedRect: objHead, cornerRadius: fltHeadWidth / 2), with: .color(.white))
    }
}

/// One line of text that scrolls sideways when it doesn't fit: it waits, glides
/// to the end, pauses, and starts over. Short text sits still.
struct MarqueeText: View {
    let strText: String
    let objFont: Font
    let objColor: Color
    /// Scroll only while true (e.g. while playing); otherwise show the start.
    let blnRunning: Bool

    @State private var fltTextWidth: CGFloat = 0
    @State private var objCycleStart = Date()

    /// Pause before scrolling and at the end, and scroll speed (points per second).
    private static let dblStartHold = 2.0
    private static let dblEndHold = 1.5
    private static let fltSpeed: CGFloat = 24

    var body: some View {
        GeometryReader { objProxy in
            let fltOverflow = max(0, fltTextWidth - objProxy.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !blnRunning || fltOverflow <= 0)) { objContext in
                let fltOffset = blnRunning ? offset(fltOverflow: fltOverflow, objNow: objContext.date) : 0
                Text(strText)
                    .font(objFont)
                    .foregroundStyle(objColor)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fltTextWidth = $0 }
                    .offset(x: -fltOffset)
                    .frame(width: objProxy.size.width, height: objProxy.size.height, alignment: .leading)
                    .clipped()
                    // Soft edges where text continues out of view.
                    .mask(edgeFade(blnLeading: fltOffset > 0.5, blnTrailing: fltOffset < fltOverflow - 0.5))
            }
        }
        .onChange(of: strText) { objCycleStart = Date() }
        .onChange(of: blnRunning) { objCycleStart = Date() }
    }

    /// Scroll offset at a moment in the wait → glide → pause cycle.
    /// - Parameters:
    ///   - fltOverflow: How far the text extends past the frame.
    ///   - objNow: Current time.
    /// - Returns: Points to shift left.
    private func offset(fltOverflow: CGFloat, objNow: Date) -> CGFloat {
        guard fltOverflow > 0 else { return 0 }
        let dblScroll = Double(fltOverflow / Self.fltSpeed)
        let dblCycle = Self.dblStartHold + dblScroll + Self.dblEndHold
        let dblT = objNow.timeIntervalSince(objCycleStart).truncatingRemainder(dividingBy: dblCycle)
        if dblT < Self.dblStartHold { return 0 }
        if dblT < Self.dblStartHold + dblScroll {
            // Ease in and out so the glide doesn't start or stop abruptly.
            let dblProgress = (dblT - Self.dblStartHold) / dblScroll
            return fltOverflow * CGFloat((1 - cos(dblProgress * .pi)) / 2)
        }
        return fltOverflow
    }

    /// Mask that fades the edges where text is cut off.
    /// - Parameters:
    ///   - blnLeading: Text continues to the left.
    ///   - blnTrailing: Text continues to the right.
    /// - Returns: Mask view.
    private func edgeFade(blnLeading: Bool, blnTrailing: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: blnLeading ? .clear : .black, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.88),
            .init(color: blnTrailing ? .clear : .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}
