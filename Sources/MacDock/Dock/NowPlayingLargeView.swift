import SwiftUI

/// Where everything sits in the large Now Playing tile, shared by drawing and
/// hit-testing so clicks always land on what's drawn.
///
/// Coordinates are tile-local with a top-left origin. Proportions scale with the
/// dock's icon size (the tile is one icon tall).
struct NowPlayingLargeLayout {
    /// Tile width as a multiple of the icon size.
    static let fltWidthRatio: CGFloat = 5.4

    /// A control under the cursor.
    enum Control: Equatable {
        case artwork
        case previous
        case playPause
        case next
        /// Seek bar, at a 0…1 position.
        case seek(Double)
        case mute
        /// Volume bar, at a 0…1 level.
        case volume(Float)
    }

    let fltWidth: CGFloat
    let fltHeight: CGFloat

    /// Builds the layout for a tile size.
    /// - Parameter fltIconSize: Dock icon size (the tile's height).
    init(fltIconSize: CGFloat) {
        fltHeight = fltIconSize
        fltWidth = (fltIconSize * Self.fltWidthRatio).rounded()
    }

    // MARK: - Regions

    private var fltPad: CGFloat { (fltHeight * 0.1).rounded() }
    /// Square artwork on the leading edge.
    var objArtwork: CGRect { CGRect(x: 0, y: 0, width: fltHeight, height: fltHeight) }
    /// Text and controls column.
    private var fltContentX: CGFloat { fltHeight + fltPad }
    private var fltContentEnd: CGFloat { fltWidth - fltPad }

    /// Title — artist line.
    var objTitle: CGRect {
        CGRect(x: fltContentX, y: fltHeight * 0.06, width: fltContentEnd - fltContentX, height: fltHeight * 0.26)
    }

    /// Size of each transport button.
    var fltButton: CGFloat { (fltHeight * 0.34).rounded() }
    /// Vertical center of the transport row.
    private var fltControlsMidY: CGFloat { fltHeight * 0.49 }

    /// Transport buttons, left to right: previous, play/pause, next.
    var objPrevious: CGRect { button(at: 0) }
    var objPlayPause: CGRect { button(at: 1) }
    var objNext: CGRect { button(at: 2) }

    /// Volume bar (right side of the transport row).
    var objVolumeBar: CGRect {
        let fltBarWidth = (fltContentEnd - fltContentX) * 0.3
        return CGRect(x: fltContentEnd - fltBarWidth, y: fltControlsMidY - 2, width: fltBarWidth, height: 4)
    }

    /// Mute button, just before the volume bar.
    var objMute: CGRect {
        CGRect(x: objVolumeBar.minX - fltButton - 2, y: fltControlsMidY - fltButton / 2, width: fltButton, height: fltButton)
    }

    /// Time labels' width (elapsed on the left, remaining on the right).
    var fltTimeWidth: CGFloat { (fltHeight * 0.62).rounded() }
    /// Vertical center of the seek row.
    var fltSeekMidY: CGFloat { fltHeight * 0.82 }

    /// Seek bar between the two time labels.
    var objSeekBar: CGRect {
        let fltStart = fltContentX + fltTimeWidth
        return CGRect(x: fltStart, y: fltSeekMidY - 2, width: fltContentEnd - fltTimeWidth - fltStart, height: 4)
    }

    /// A transport button by position.
    /// - Parameter intSlot: 0 previous, 1 play/pause, 2 next.
    /// - Returns: Its frame.
    private func button(at intSlot: Int) -> CGRect {
        let fltGap = fltButton * 0.25
        return CGRect(x: fltContentX - fltGap / 2 + CGFloat(intSlot) * (fltButton + fltGap),
                      y: fltControlsMidY - fltButton / 2, width: fltButton, height: fltButton)
    }

    // MARK: - Hit-testing

    /// Control at a tile-local point (with generous targets for the thin bars).
    /// - Parameter objPoint: Point (top-left origin).
    /// - Returns: The control, or `nil` over empty space.
    func control(at objPoint: CGPoint) -> Control? {
        if objArtwork.contains(objPoint) { return .artwork }
        for (objFrame, enmControl) in [(objPrevious, Control.previous), (objPlayPause, .playPause), (objNext, .next), (objMute, .mute)]
            where objFrame.insetBy(dx: -2, dy: -3).contains(objPoint) {
            return enmControl
        }
        if objVolumeBar.insetBy(dx: -4, dy: -fltButton / 2).contains(objPoint) {
            return .volume(Float(fraction(of: objPoint.x, in: objVolumeBar)))
        }
        // The seek row is the whole bottom strip of the content column.
        if objPoint.x >= objSeekBar.minX - 6, objPoint.x <= objSeekBar.maxX + 6, objPoint.y >= fltHeight * 0.66 {
            return .seek(fraction(of: objPoint.x, in: objSeekBar))
        }
        return nil
    }

    /// Position of an x coordinate along a bar.
    /// - Parameters:
    ///   - fltX: X coordinate.
    ///   - objBar: Bar frame.
    /// - Returns: 0…1.
    func fraction(of fltX: CGFloat, in objBar: CGRect) -> Double {
        Double(min(1, max(0, (fltX - objBar.minX) / max(objBar.width, 1))))
    }
}

/// Live value being dragged on a bar, shown instead of the real one until release.
enum WidgetScrub: Equatable {
    case seek(Double)
    case volume(Float)
}

/// Large Now Playing tile: artwork, title and artist, previous / play-pause / next,
/// mute and volume, and a seek bar with elapsed and remaining time.
struct NowPlayingLargeView: View {
    let objNowPlaying: NowPlayingService
    let objVolume: SystemVolumeService
    let fltIconSize: CGFloat
    /// Bar being dragged, if any.
    let enmScrub: WidgetScrub?
    /// Control under the cursor, for hover highlights.
    let enmHovered: NowPlayingLargeLayout.Control?

    var body: some View {
        let objLayout = NowPlayingLargeLayout(fltIconSize: fltIconSize)
        let fltCorner = fltIconSize * 0.22
        // Redraw a few times a second so the seek bar and times advance.
        TimelineView(.periodic(from: .now, by: 0.5)) { objContext in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                    .fill(Color(white: 0.1).opacity(0.9))

                NowPlayingTileView(objNowPlaying: objNowPlaying, fltSize: objLayout.fltHeight, blnShowsState: false)
                    .frame(width: objLayout.objArtwork.width, height: objLayout.objArtwork.height)

                titleLine(objLayout)
                transport(objLayout)
                volume(objLayout)
                seek(objLayout, objNow: objContext.date)
            }
            .frame(width: objLayout.fltWidth, height: objLayout.fltHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: fltCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }

    // MARK: - Parts

    /// "Title — Artist", the artist dimmer.
    /// - Parameter objLayout: Layout.
    /// - Returns: The line.
    private func titleLine(_ objLayout: NowPlayingLargeLayout) -> some View {
        let objTrack = objNowPlaying.objTrack
        let fltFont = fltIconSize * 0.2
        var objText = Text(objTrack?.strTitle ?? "Not Playing").font(.system(size: fltFont, weight: .semibold))
        if let strArtist = objTrack?.strArtist, !strArtist.isEmpty {
            objText = objText + Text("  \(strArtist)").font(.system(size: fltFont * 0.92)).foregroundColor(.white.opacity(0.6))
        }
        return objText
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: objLayout.objTitle.width, height: objLayout.objTitle.height, alignment: .leading)
            .offset(x: objLayout.objTitle.minX, y: objLayout.objTitle.minY)
    }

    /// Previous, play/pause and next.
    /// - Parameter objLayout: Layout.
    /// - Returns: The buttons.
    private func transport(_ objLayout: NowPlayingLargeLayout) -> some View {
        ZStack(alignment: .topLeading) {
            glyph("backward.fill", objFrame: objLayout.objPrevious, enmControl: .previous, fltScale: 0.5)
            glyph(objNowPlaying.blnIsPlaying ? "pause.fill" : "play.fill", objFrame: objLayout.objPlayPause,
                  enmControl: .playPause, fltScale: 0.62)
            glyph("forward.fill", objFrame: objLayout.objNext, enmControl: .next, fltScale: 0.5)
        }
    }

    /// Mute button and volume bar.
    /// - Parameter objLayout: Layout.
    /// - Returns: The controls.
    @ViewBuilder
    private func volume(_ objLayout: NowPlayingLargeLayout) -> some View {
        if objVolume.blnHasVolume {
            let fltLevel: Float = {
                if case .volume(let fltScrub) = enmScrub { return fltScrub }
                return objVolume.blnIsMuted ? 0 : objVolume.fltVolume
            }()
            ZStack(alignment: .topLeading) {
                glyph(Self.speakerSymbol(fltLevel: fltLevel, blnMuted: objVolume.blnIsMuted),
                      objFrame: objLayout.objMute, enmControl: .mute, fltScale: 0.5)
                bar(objFrame: objLayout.objVolumeBar, dblFraction: Double(fltLevel),
                    blnActive: isScrubbing(volume: true) || isHoveringVolume)
            }
        }
    }

    /// Seek bar with elapsed and remaining time (hidden for live streams without a length).
    /// - Parameters:
    ///   - objLayout: Layout.
    ///   - objNow: Current time, for extrapolating the position.
    /// - Returns: The row.
    @ViewBuilder
    private func seek(_ objLayout: NowPlayingLargeLayout, objNow: Date) -> some View {
        let dblDuration = objNowPlaying.dblDuration
        if dblDuration > 0 {
            let dblFraction: Double = {
                if case .seek(let dblScrub) = enmScrub { return dblScrub }
                return objNowPlaying.elapsed(at: objNow) / dblDuration
            }()
            let dblElapsed = dblFraction * dblDuration
            let fltFont = fltIconSize * 0.155
            ZStack(alignment: .topLeading) {
                Text(Self.time(dblElapsed))
                    .frame(width: objLayout.fltTimeWidth - 4, alignment: .leading)
                    .offset(x: objLayout.objSeekBar.minX - objLayout.fltTimeWidth, y: objLayout.fltSeekMidY - fltFont * 0.68)
                bar(objFrame: objLayout.objSeekBar, dblFraction: dblFraction,
                    blnActive: isScrubbing(volume: false) || isHoveringSeek)
                Text("-" + Self.time(max(0, dblDuration - dblElapsed)))
                    .frame(width: objLayout.fltTimeWidth - 4, alignment: .trailing)
                    .offset(x: objLayout.objSeekBar.maxX + 4, y: objLayout.fltSeekMidY - fltFont * 0.68)
            }
            .font(.system(size: fltFont, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.65))
        }
    }

    // MARK: - Building blocks

    /// A transport/mute symbol, brightened while hovered.
    /// - Parameters:
    ///   - strSymbol: SF Symbol.
    ///   - objFrame: Button frame.
    ///   - enmControl: Control it represents (for hover).
    ///   - fltScale: Symbol size relative to the button.
    /// - Returns: The glyph.
    private func glyph(_ strSymbol: String, objFrame: CGRect, enmControl: NowPlayingLargeLayout.Control, fltScale: CGFloat) -> some View {
        let blnHovered = enmHovered == enmControl
        return Image(systemName: strSymbol)
            .font(.system(size: objFrame.height * fltScale, weight: .semibold))
            .foregroundColor(.white.opacity(blnHovered ? 1 : 0.85))
            .frame(width: objFrame.width, height: objFrame.height)
            .background(Circle().fill(Color.white.opacity(blnHovered ? 0.16 : 0)))
            .offset(x: objFrame.minX, y: objFrame.minY)
            .animation(.easeOut(duration: 0.12), value: blnHovered)
    }

    /// A thin progress bar with a knob that grows while hovered or dragged.
    /// - Parameters:
    ///   - objFrame: Bar frame.
    ///   - dblFraction: Filled portion 0…1.
    ///   - blnActive: Hovered or dragged.
    /// - Returns: The bar.
    private func bar(objFrame: CGRect, dblFraction: Double, blnActive: Bool) -> some View {
        let fltFilled = objFrame.width * CGFloat(min(1, max(0, dblFraction)))
        let fltKnob: CGFloat = blnActive ? 10 : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.2))
            Capsule().fill(Color.white.opacity(0.9)).frame(width: fltFilled)
            Circle()
                .fill(Color.white)
                .frame(width: fltKnob, height: fltKnob)
                .offset(x: fltFilled - fltKnob / 2)
        }
        .frame(width: objFrame.width, height: objFrame.height)
        .offset(x: objFrame.minX, y: objFrame.minY)
        .animation(.easeOut(duration: 0.12), value: blnActive)
    }

    /// Whether the given bar is being dragged.
    /// - Parameter blnVolume: Volume bar (`true`) or seek bar.
    /// - Returns: Whether it's scrubbing.
    private func isScrubbing(volume blnVolume: Bool) -> Bool {
        switch enmScrub {
        case .volume: blnVolume
        case .seek: !blnVolume
        case nil: false
        }
    }

    private var isHoveringVolume: Bool {
        if case .volume = enmHovered { return true }
        return false
    }

    private var isHoveringSeek: Bool {
        if case .seek = enmHovered { return true }
        return false
    }

    /// Speaker symbol for a volume level.
    /// - Parameters:
    ///   - fltLevel: Volume 0…1.
    ///   - blnMuted: Muted.
    /// - Returns: SF Symbol name.
    private static func speakerSymbol(fltLevel: Float, blnMuted: Bool) -> String {
        if blnMuted || fltLevel <= 0.001 { return "speaker.slash.fill" }
        if fltLevel < 0.34 { return "speaker.wave.1.fill" }
        if fltLevel < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// "m:ss" (or "h:mm:ss").
    /// - Parameter dblSeconds: Seconds.
    /// - Returns: Formatted time.
    private static func time(_ dblSeconds: Double) -> String {
        let intTotal = Int(dblSeconds.rounded(.down))
        let intHours = intTotal / 3600
        let intMinutes = (intTotal % 3600) / 60
        let intSecs = intTotal % 60
        return intHours > 0
            ? String(format: "%d:%02d:%02d", intHours, intMinutes, intSecs)
            : String(format: "%d:%02d", intMinutes, intSecs)
    }
}
