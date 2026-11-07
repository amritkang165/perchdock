import SwiftUI

/// Now Playing tile: the track's artwork (or the playing app's icon). Playing art is
/// full color with a breathing glow and bouncing bars; paused art shrinks back, dims,
/// and shows a pause badge.
struct NowPlayingTileView: View {
    let objNowPlaying: NowPlayingService
    let fltSize: CGFloat
    /// Show a thin progress line along the bottom instead of the glyph (side-dock tile with a fly-out player).
    var blnShowsProgress = false

    var body: some View {
        let fltCorner = fltSize * 0.22
        let blnPlaying = objNowPlaying.blnIsPlaying
        ZStack {
            // Playing: a soft glow of the artwork itself breathes behind the tile.
            if blnPlaying {
                ArtworkGlow(fltSize: fltSize, fltCorner: fltCorner) { artwork }
                    .transition(.opacity)
            }

            ZStack {
                artwork
                    .frame(width: fltSize, height: fltSize)
                    .clipShape(RoundedRectangle(cornerRadius: fltCorner, style: .continuous))
                    // Paused tracks go dim and grey, so the state reads at a glance.
                    .saturation(blnPlaying ? 1 : 0.15)
                    .brightness(blnPlaying ? 0 : -0.22)

                if blnShowsProgress {
                    progressLine
                }

                if blnPlaying {
                    // Playing: bouncing bars in a corner (top-right when the progress line owns the bottom).
                    stateBadge(alignment: blnShowsProgress ? .topTrailing : .bottomLeading) {
                        EqualizerBars().padding(fltSize * 0.08)
                    }
                } else {
                    // Paused: a centered pause badge over the dimmed art.
                    Image(systemName: "pause.fill")
                        .font(.system(size: fltSize * 0.2, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: fltSize * 0.42, height: fltSize * 0.42)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: fltSize, height: fltSize)
            .overlay(
                RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            // Paused art settles back slightly; playing art sits forward.
            .scaleEffect(blnPlaying ? 1 : 0.9)
        }
        .frame(width: fltSize, height: fltSize)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: blnPlaying)
    }

    /// Small dark circular badge pinned to one corner of the tile.
    /// - Parameters:
    ///   - enmAlignment: Corner to pin to.
    ///   - fnContent: Badge content.
    /// - Returns: The badge, padded in from the edge.
    private func stateBadge(alignment enmAlignment: Alignment, @ViewBuilder _ fnContent: () -> some View) -> some View {
        fnContent()
            .frame(width: fltSize * 0.34, height: fltSize * 0.34)
            .background(Circle().fill(.black.opacity(0.55)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: enmAlignment)
            .padding(fltSize * 0.07)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    /// Cover art; without it, the playing app's icon on a soft blurred backdrop.
    @ViewBuilder
    private var artwork: some View {
        if let objArtwork = objNowPlaying.objTrack?.objArtwork {
            Image(nsImage: objArtwork)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            let objIcon = Self.appIcon(for: objNowPlaying.objTrack?.strBundleId)
            ZStack {
                Image(nsImage: objIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: fltSize * 0.18)
                    .overlay(Color.black.opacity(0.25))
                Image(nsImage: objIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fltSize * 0.62, height: fltSize * 0.62)
            }
        }
    }

    /// Thin track-progress line near the bottom edge, advancing while playing.
    private var progressLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { objContext in
            let dblDuration = objNowPlaying.dblDuration
            let dblFraction = dblDuration > 0 ? objNowPlaying.elapsed(at: objContext.date) / dblDuration : 0
            let fltWidth = fltSize * 0.72
            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule().fill(Color.white).frame(width: fltWidth * CGFloat(min(1, max(0, dblFraction))))
                }
                .frame(width: fltWidth, height: max(2.5, fltSize * 0.055))
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .padding(.bottom, fltSize * 0.1)
            }
        }
    }

    /// Icon of the app playing (falls back to a music note).
    /// - Parameter strBundleId: Bundle ID, if known.
    /// - Returns: Icon.
    static func appIcon(for strBundleId: String?) -> NSImage {
        if let strBundleId, let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strBundleId) {
            return NSWorkspace.shared.icon(forFile: objUrl.path)
        }
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing") ?? NSImage()
    }
}

/// Blurred copy of the artwork behind the tile whose glow slowly breathes in and out,
/// a calm "this is playing" cue. Only exists while playing, so it never ticks when paused.
private struct ArtworkGlow<Content: View>: View {
    let fltSize: CGFloat
    let fltCorner: CGFloat
    @ViewBuilder let fnArtwork: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { objContext in
            // A ~3 s breathing cycle between dim and bright.
            let dblPhase = (sin(objContext.date.timeIntervalSinceReferenceDate * 2 * .pi / 3) + 1) / 2
            fnArtwork()
                .frame(width: fltSize, height: fltSize)
                .clipShape(RoundedRectangle(cornerRadius: fltCorner, style: .continuous))
                .blur(radius: fltSize * 0.14)
                .saturation(1.6)
                .opacity(0.35 + 0.4 * dblPhase)
                .scaleEffect(1.0 + 0.06 * dblPhase)
        }
        .allowsHitTesting(false)
    }
}

/// Three bouncing bars (a tiny "playing" visualizer).
private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { objContext in
            let fltTime = objContext.date.timeIntervalSinceReferenceDate
            GeometryReader { objProxy in
                HStack(alignment: .bottom, spacing: objProxy.size.width * 0.14) {
                    ForEach(0..<3, id: \.self) { intBar in
                        // Out-of-phase sines so the bars don't move in lockstep.
                        let fltLevel = 0.35 + 0.65 * abs(sin(fltTime * (3.1 + Double(intBar) * 1.3) + Double(intBar)))
                        Capsule()
                            .fill(Color.white)
                            .frame(height: objProxy.size.height * fltLevel)
                    }
                }
                .frame(width: objProxy.size.width, height: objProxy.size.height, alignment: .bottom)
            }
        }
    }
}

/// Battery tile: a charge ring with the percentage, and a bolt while charging.
struct BatteryTileView: View {
    let objBattery: BatteryService
    let fltSize: CGFloat

    var body: some View {
        let fltCorner = fltSize * 0.22
        let fltFraction = Double(objBattery.intPercent) / 100
        ZStack {
            RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                .fill(Color(white: 0.12).opacity(0.92))

            // Track + charge arc, starting at 12 o'clock.
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: fltSize * 0.08)
                .padding(fltSize * 0.14)
            Circle()
                .trim(from: 0, to: fltFraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: fltSize * 0.08, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(fltSize * 0.14)
                .animation(.easeOut(duration: 0.4), value: fltFraction)

            VStack(spacing: 0) {
                if objBattery.blnIsCharging || objBattery.blnIsPluggedIn {
                    Image(systemName: objBattery.blnIsCharging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: fltSize * 0.15, weight: .bold))
                        .foregroundStyle(objBattery.blnIsCharging ? Color.yellow : Color.white.opacity(0.8))
                }
                Text("\(objBattery.intPercent)")
                    .font(.system(size: fltSize * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .frame(width: fltSize, height: fltSize)
        .overlay(
            RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    /// Green normally (or charging), orange when low, red when critical.
    private var ringColor: Color {
        if objBattery.blnIsCharging { return .green }
        switch objBattery.intPercent {
        case ..<11: return .red
        case ..<21: return .orange
        default: return .green
        }
    }
}
