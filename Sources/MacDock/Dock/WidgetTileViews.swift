import SwiftUI

/// Now Playing tile: the track's artwork (or the playing app's icon), with animated
/// bars while playing and a play glyph while paused.
struct NowPlayingTileView: View {
    let objNowPlaying: NowPlayingService
    let fltSize: CGFloat
    /// Show the playing/paused glyph (the large player has its own play button).
    var blnShowsState = true
    /// Show a thin progress line along the bottom instead of the glyph (side-dock tile with a fly-out player).
    var blnShowsProgress = false

    var body: some View {
        let fltCorner = fltSize * 0.22
        ZStack {
            artwork
                .frame(width: fltSize, height: fltSize)
                .clipShape(RoundedRectangle(cornerRadius: fltCorner, style: .continuous))
                // Paused tracks look a little "off".
                .saturation(objNowPlaying.blnIsPlaying ? 1 : 0.55)

            if blnShowsProgress {
                progressLine
            } else if blnShowsState {
                // State glyph in the bottom-left corner.
                VStack {
                    Spacer()
                    HStack {
                        stateGlyph
                            .frame(width: fltSize * 0.34, height: fltSize * 0.34)
                            .background(Circle().fill(.black.opacity(0.55)))
                        Spacer()
                    }
                }
                .padding(fltSize * 0.07)
            }
        }
        .frame(width: fltSize, height: fltSize)
        .overlay(
            RoundedRectangle(cornerRadius: fltCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
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

    /// Equalizer bars while playing, a play triangle while paused.
    @ViewBuilder
    private var stateGlyph: some View {
        if objNowPlaying.blnIsPlaying {
            EqualizerBars()
                .padding(fltSize * 0.08)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: fltSize * 0.15, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: fltSize * 0.01)
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
