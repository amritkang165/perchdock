import SwiftUI

/// Where everything sits in the large Now Playing tile, shared by drawing and
/// hit-testing so clicks always land on what's drawn.
///
/// Two shapes, both one icon thick across the bar:
/// - **wide** (bottom dock): artwork on the left; title, transport + volume, and
///   seek rows to its right;
/// - **tall** (side docks): artwork on top; transport buttons stacked beside a
///   vertical volume bar with mute below it; seek bar and times at the bottom.
///   The title shows in the hover label instead.
///
/// Coordinates are tile-local with a top-left origin, in screen orientation.
/// Proportions scale with the dock's icon size.
struct NowPlayingLargeLayout {
    /// Wide tile length as a multiple of the icon size.
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

    /// Tall shape (side docks) rather than wide (bottom dock).
    let blnVertical: Bool
    /// Tile size in screen orientation.
    let fltWidth: CGFloat
    let fltHeight: CGFloat

    /// Square artwork (left edge when wide, top when tall).
    let objArtwork: CGRect
    /// Title — artist line (empty when tall).
    let objTitle: CGRect
    /// Transport buttons.
    let objPrevious: CGRect
    let objPlayPause: CGRect
    let objNext: CGRect
    /// Mute button and volume bar (horizontal when wide, vertical when tall).
    let objMute: CGRect
    let objVolumeBar: CGRect
    /// Seek bar and its elapsed / remaining labels.
    let objSeekBar: CGRect
    let objElapsedLabel: CGRect
    let objRemainingLabel: CGRect
    /// Size of each transport button.
    let fltButton: CGFloat
    /// Point size for the time labels.
    let fltTimeFont: CGFloat

    /// Length along the dock's bar (what the dock reserves for the tile).
    var fltMainLength: CGFloat { blnVertical ? fltHeight : fltWidth }

    /// Builds the layout for an icon size and dock orientation.
    /// - Parameters:
    ///   - fltIconSize: Dock icon size (the tile's thickness across the bar).
    ///   - blnVertical: Tall shape for a side dock.
    init(fltIconSize: CGFloat, blnVertical: Bool = false) {
        self.blnVertical = blnVertical
        let fltIcon = fltIconSize
        objArtwork = CGRect(x: 0, y: 0, width: fltIcon, height: fltIcon)

        if blnVertical {
            // Tall: art on top, then [buttons | volume] side by side, then seek + times.
            let fltPad = (fltIcon * 0.08).rounded()
            let fltSide = (fltIcon * 0.3).rounded()
            let fltGap = (fltSide * 0.22).rounded()
            let fltTop = fltIcon + fltPad
            fltButton = fltSide
            fltTimeFont = (fltIcon * 0.145).rounded()

            objPrevious = CGRect(x: fltPad, y: fltTop, width: fltSide, height: fltSide)
            objPlayPause = objPrevious.offsetBy(dx: 0, dy: fltSide + fltGap)
            objNext = objPlayPause.offsetBy(dx: 0, dy: fltSide + fltGap)
            objMute = CGRect(x: fltIcon - fltPad - fltSide, y: objNext.minY, width: fltSide, height: fltSide)
            objVolumeBar = CGRect(x: objMute.midX - 2, y: fltTop + 2, width: 4, height: objMute.minY - 3 - (fltTop + 2))

            objSeekBar = CGRect(x: fltPad, y: objNext.maxY + fltPad + 2, width: fltIcon - fltPad * 2, height: 4)
            let fltLabelHeight = fltTimeFont * 1.3
            let fltLabelWidth = objSeekBar.width / 2
            objElapsedLabel = CGRect(x: fltPad, y: objSeekBar.maxY + 2, width: fltLabelWidth, height: fltLabelHeight)
            objRemainingLabel = objElapsedLabel.offsetBy(dx: fltLabelWidth, dy: 0)
            objTitle = .zero

            fltWidth = fltIcon
            fltHeight = (objElapsedLabel.maxY + fltPad).rounded()
        } else {
            // Wide: art on the left; title, then transport + volume, then seek, to its right.
            let fltPad = (fltIcon * 0.1).rounded()
            let fltContentX = fltIcon + fltPad
            let fltWide = (fltIcon * Self.fltWidthRatio).rounded()
            let fltContentEnd = fltWide - fltPad
            let fltSide = (fltIcon * 0.34).rounded()
            let fltGap = fltSide * 0.25
            let fltControlsMidY = fltIcon * 0.49
            fltButton = fltSide
            fltTimeFont = fltIcon * 0.155

            objTitle = CGRect(x: fltContentX, y: fltIcon * 0.06, width: fltContentEnd - fltContentX, height: fltIcon * 0.26)
            objPrevious = CGRect(x: fltContentX - fltGap / 2, y: fltControlsMidY - fltSide / 2, width: fltSide, height: fltSide)
            objPlayPause = objPrevious.offsetBy(dx: fltSide + fltGap, dy: 0)
            objNext = objPlayPause.offsetBy(dx: fltSide + fltGap, dy: 0)

            let fltVolumeWidth = (fltContentEnd - fltContentX) * 0.3
            objVolumeBar = CGRect(x: fltContentEnd - fltVolumeWidth, y: fltControlsMidY - 2, width: fltVolumeWidth, height: 4)
            objMute = CGRect(x: objVolumeBar.minX - fltSide - 2, y: fltControlsMidY - fltSide / 2, width: fltSide, height: fltSide)

            let fltTimeWidth = (fltIcon * 0.62).rounded()
            let fltSeekMidY = fltIcon * 0.82
            let fltSeekStart = fltContentX + fltTimeWidth
            objSeekBar = CGRect(x: fltSeekStart, y: fltSeekMidY - 2, width: fltContentEnd - fltTimeWidth - fltSeekStart, height: 4)
            let fltLabelHeight = fltTimeFont * 1.3
            objElapsedLabel = CGRect(x: fltContentX, y: fltSeekMidY - fltLabelHeight / 2, width: fltTimeWidth - 4, height: fltLabelHeight)
            objRemainingLabel = CGRect(x: objSeekBar.maxX + 4, y: objElapsedLabel.minY, width: fltTimeWidth - 4, height: fltLabelHeight)

            fltWidth = fltWide
            fltHeight = fltIcon
        }
    }

    // MARK: - Hit-testing

    /// Control at a tile-local point (with generous targets for the thin bars).
    /// - Parameter objPoint: Point (top-left origin).
    /// - Returns: The control, or `nil` over empty space.
    func control(at objPoint: CGPoint) -> Control? {
        if objArtwork.contains(objPoint) { return .artwork }
        for (objFrame, enmControl) in [(objPrevious, Control.previous), (objPlayPause, .playPause), (objNext, .next), (objMute, .mute)]
            where objFrame.insetBy(dx: -2, dy: -2).contains(objPoint) {
            return enmControl
        }
        let objVolumeTarget = blnVertical
            ? objVolumeBar.insetBy(dx: -fltButton / 2, dy: -4)
            : objVolumeBar.insetBy(dx: -4, dy: -fltButton / 2)
        if objVolumeTarget.contains(objPoint) {
            return .volume(volumeLevel(at: objPoint))
        }
        // The seek row is the whole strip around the bar and its times.
        let blnInSeekRow = blnVertical
            ? objPoint.y >= objSeekBar.minY - 6
            : objPoint.x >= objSeekBar.minX - 6 && objPoint.x <= objSeekBar.maxX + 6 && objPoint.y >= fltHeight * 0.66
        if blnInSeekRow {
            return .seek(seekFraction(at: objPoint))
        }
        return nil
    }

    /// Track position under a point, along the seek bar.
    /// - Parameter objPoint: Tile-local point.
    /// - Returns: 0…1.
    func seekFraction(at objPoint: CGPoint) -> Double {
        Self.clamp((objPoint.x - objSeekBar.minX) / max(objSeekBar.width, 1))
    }

    /// Volume under a point, along the volume bar (bottom = 0 when tall).
    /// - Parameter objPoint: Tile-local point.
    /// - Returns: 0…1.
    func volumeLevel(at objPoint: CGPoint) -> Float {
        let fltRaw = blnVertical
            ? (objVolumeBar.maxY - objPoint.y) / max(objVolumeBar.height, 1)
            : (objPoint.x - objVolumeBar.minX) / max(objVolumeBar.width, 1)
        return Float(Self.clamp(fltRaw))
    }

    /// Clamps to 0…1.
    /// - Parameter fltValue: Raw value.
    /// - Returns: Clamped value.
    private static func clamp(_ fltValue: CGFloat) -> Double {
        Double(min(1, max(0, fltValue)))
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
    /// Tall shape for a side dock.
    let blnVertical: Bool
    /// Bar being dragged, if any.
    let enmScrub: WidgetScrub?
    /// Control under the cursor, for hover highlights.
    let enmHovered: NowPlayingLargeLayout.Control?

    var body: some View {
        let objLayout = NowPlayingLargeLayout(fltIconSize: fltIconSize, blnVertical: blnVertical)
        let fltCorner = fltIconSize * 0.22
        // Redraw a few times a second so the seek bar and times advance.
        TimelineView(.periodic(from: .now, by: 0.5)) { objContext in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                    .fill(Color(white: 0.1).opacity(0.9))

                NowPlayingTileView(objNowPlaying: objNowPlaying, fltSize: objLayout.objArtwork.width, blnShowsState: false)
                    .frame(width: objLayout.objArtwork.width, height: objLayout.objArtwork.height)

                if !blnVertical {
                    titleLine(objLayout)
                }
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
            ZStack(alignment: .topLeading) {
                timeLabel(Self.time(dblElapsed), objFrame: objLayout.objElapsedLabel, enmAlignment: .leading)
                bar(objFrame: objLayout.objSeekBar, dblFraction: dblFraction,
                    blnActive: isScrubbing(volume: false) || isHoveringSeek)
                timeLabel("-" + Self.time(max(0, dblDuration - dblElapsed)), objFrame: objLayout.objRemainingLabel,
                          enmAlignment: .trailing)
            }
            .font(.system(size: objLayout.fltTimeFont, weight: .medium).monospacedDigit())
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
    /// Taller-than-wide frames make a vertical bar that fills from the bottom.
    /// - Parameters:
    ///   - objFrame: Bar frame.
    ///   - dblFraction: Filled portion 0…1.
    ///   - blnActive: Hovered or dragged.
    /// - Returns: The bar.
    private func bar(objFrame: CGRect, dblFraction: Double, blnActive: Bool) -> some View {
        let blnUpright = objFrame.height > objFrame.width
        let fltLength = blnUpright ? objFrame.height : objFrame.width
        let fltFilled = fltLength * CGFloat(min(1, max(0, dblFraction)))
        let fltKnob: CGFloat = blnActive ? 10 : 0
        return ZStack(alignment: blnUpright ? .bottom : .leading) {
            Capsule().fill(Color.white.opacity(0.2))
            Capsule().fill(Color.white.opacity(0.9))
                .frame(width: blnUpright ? nil : fltFilled, height: blnUpright ? fltFilled : nil)
            Circle()
                .fill(Color.white)
                .frame(width: fltKnob, height: fltKnob)
                .offset(x: blnUpright ? 0 : fltFilled - fltKnob / 2, y: blnUpright ? -(fltFilled - fltKnob / 2) : 0)
        }
        .frame(width: objFrame.width, height: objFrame.height)
        .offset(x: objFrame.minX, y: objFrame.minY)
        .animation(.easeOut(duration: 0.12), value: blnActive)
    }

    /// Elapsed or remaining time in its slot.
    /// - Parameters:
    ///   - strText: Time text.
    ///   - objFrame: Label frame.
    ///   - enmAlignment: Leading (elapsed) or trailing (remaining).
    /// - Returns: The label.
    private func timeLabel(_ strText: String, objFrame: CGRect, enmAlignment: Alignment) -> some View {
        Text(strText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: objFrame.width, height: objFrame.height, alignment: enmAlignment)
            .offset(x: objFrame.minX, y: objFrame.minY)
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
