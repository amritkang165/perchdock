import SwiftUI

/// Live dock icons that PerchDock draws itself, for apps whose real Dock icon changes
/// (Calendar shows today's date, Clock shows the time). Apps draw their live icons
/// inside the native Dock's process, which another app can't read, so these redraw
/// the well-known ones in the macOS 26 style instead.
enum LiveIcons {
    /// Bundle IDs that have a live icon.
    private static let setStrSupported: Set<String> = ["com.apple.iCal", "com.apple.clock"]

    /// Whether the app has a live icon PerchDock can draw.
    /// - Parameter strBundleId: App bundle ID.
    /// - Returns: True for Calendar and Clock.
    static func supports(_ strBundleId: String) -> Bool {
        setStrSupported.contains(strBundleId)
    }

    /// Calendar's bundle ID, whose still icon (used in group tiles, grids and menus)
    /// also shows today's date.
    static let strCalendarBundleId = "com.apple.iCal"

    /// Still image of today's Calendar icon, for places that need an `NSImage`.
    /// - Returns: A 256 pt image showing today's weekday and date.
    @MainActor
    static func calendarImage() -> NSImage {
        let objRenderer = ImageRenderer(content: CalendarFace(objDate: Date(), fltSize: 256))
        objRenderer.scale = 2
        return objRenderer.nsImage ?? NSImage()
    }
}

/// Draws the live icon for a supported app at the given tile size.
struct LiveIconView: View {
    let strBundleId: String
    let fltSize: CGFloat

    var body: some View {
        switch strBundleId {
        case "com.apple.clock": LiveClockIcon(fltSize: fltSize)
        default: LiveCalendarIcon(fltSize: fltSize)
        }
    }
}

/// Apple's icon grid: the rounded square is 824/1024 of the tile, with 185/824 corners.
private struct IconShape {
    let fltTile: CGFloat
    /// Side of the rounded square inside the tile.
    var fltSide: CGFloat { fltTile * 824 / 1024 }
    /// Corner radius of the rounded square.
    var fltCorner: CGFloat { fltSide * 185 / 824 }
    /// The rounded square shape.
    var objShape: RoundedRectangle { RoundedRectangle(cornerRadius: fltCorner, style: .continuous) }
}

/// Calendar in the dock: redraws each minute so it flips over at midnight.
private struct LiveCalendarIcon: View {
    let fltSize: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { objContext in
            CalendarFace(objDate: objContext.date, fltSize: fltSize)
        }
    }
}

/// Calendar icon for a given day: red band with the weekday over a dark body with the date.
private struct CalendarFace: View {
    let objDate: Date
    let fltSize: CGFloat

    var body: some View {
        let objGrid = IconShape(fltTile: fltSize)
        let fltSide = objGrid.fltSide
        VStack(spacing: 0) {
            // Weekday band, e.g. "TUE".
            Text(objDate.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: fltSide * 0.15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: fltSide, height: fltSide * 0.25)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.38), Color(red: 0.9, green: 0.29, blue: 0.27)],
                                           startPoint: .top, endPoint: .bottom))
            // Day of the month.
            Text(objDate.formatted(.dateTime.day()))
                .font(.system(size: fltSide * 0.5, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: fltSide, height: fltSide * 0.75)
                .offset(y: -fltSide * 0.02)
                .background(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(objGrid.objShape)
        .overlay(objGrid.objShape.strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, fltSide * 0.006)))
        .shadow(color: .black.opacity(0.28), radius: fltSize * 0.02, y: fltSize * 0.01)
        .frame(width: fltSize, height: fltSize)
    }
}

/// Clock: dark face with tick marks, 12/3/6/9, white hands and an orange second hand.
/// Ticks once a second, and stops while the dock is hidden.
private struct LiveClockIcon: View {
    let fltSize: CGFloat
    @Environment(\.blnAnimationsPaused) private var blnPaused

    var body: some View {
        let objGrid = IconShape(fltTile: fltSize)
        TimelineView(.animation(minimumInterval: 1, paused: blnPaused)) { objContext in
            Canvas { objCanvas, objCanvasSize in
                drawFace(in: &objCanvas, fltSide: objCanvasSize.width, objDate: objContext.date)
            }
            .frame(width: objGrid.fltSide, height: objGrid.fltSide)
            .background(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            .clipShape(objGrid.objShape)
            .overlay(objGrid.objShape.strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, objGrid.fltSide * 0.006)))
            .shadow(color: .black.opacity(0.28), radius: fltSize * 0.02, y: fltSize * 0.01)
            .frame(width: fltSize, height: fltSize)
        }
    }

    /// Draws ticks, numerals and hands for the given time.
    /// - Parameters:
    ///   - objCanvas: Canvas to draw into.
    ///   - fltSide: Side of the (square) face.
    ///   - objDate: Time to show.
    private func drawFace(in objCanvas: inout GraphicsContext, fltSide: CGFloat, objDate: Date) {
        let objCenter = CGPoint(x: fltSide / 2, y: fltSide / 2)
        let fltHalf = fltSide * 0.455

        // 60 ticks that run out to the rounded-square edge, like Apple's icon.
        for intTick in 0..<60 {
            let dblAngle = Double(intTick) / 60 * 2 * .pi
            let fltDx = CGFloat(sin(dblAngle)), fltDy = CGFloat(-cos(dblAngle))
            // Distance to a square's edge along this direction, softened at the corners.
            let fltEdge = min(fltHalf / max(abs(fltDx), abs(fltDy)), fltHalf * 1.2)
            let blnMajor = intTick % 5 == 0
            let fltLength = fltSide * (blnMajor ? 0.085 : 0.06)
            var objPath = Path()
            objPath.move(to: CGPoint(x: objCenter.x + fltDx * (fltEdge - fltLength), y: objCenter.y + fltDy * (fltEdge - fltLength)))
            objPath.addLine(to: CGPoint(x: objCenter.x + fltDx * fltEdge, y: objCenter.y + fltDy * fltEdge))
            objCanvas.stroke(objPath, with: .color(blnMajor ? Color(white: 0.93) : Color(white: 0.42)),
                             style: StrokeStyle(lineWidth: fltSide * (blnMajor ? 0.022 : 0.013), lineCap: .round))
        }

        // 12, 3, 6 and 9.
        for (intHour, strLabel) in [(0, "12"), (3, "3"), (6, "6"), (9, "9")] {
            let dblAngle = Double(intHour) / 12 * 2 * .pi
            let objPoint = CGPoint(x: objCenter.x + CGFloat(sin(dblAngle)) * fltSide * 0.3,
                                   y: objCenter.y - CGFloat(cos(dblAngle)) * fltSide * 0.3)
            objCanvas.draw(Text(strLabel).font(.system(size: fltSide * 0.13, weight: .semibold)).foregroundStyle(Color(white: 0.93)),
                           at: objPoint)
        }

        // Hand angles from the current time (hour and minute move smoothly).
        let objParts = Calendar.current.dateComponents([.hour, .minute, .second], from: objDate)
        let dblSecond = Double(objParts.second ?? 0)
        let dblMinute = Double(objParts.minute ?? 0) + dblSecond / 60
        let dblHour = Double((objParts.hour ?? 0) % 12) + dblMinute / 60

        /// Strokes one hand from just behind the center out to the given length.
        func hand(_ dblTurns: Double, fltLength: CGFloat, fltTail: CGFloat, fltWidth: CGFloat, objColor: Color) {
            let dblAngle = dblTurns * 2 * .pi
            let fltDx = CGFloat(sin(dblAngle)), fltDy = CGFloat(-cos(dblAngle))
            var objPath = Path()
            objPath.move(to: CGPoint(x: objCenter.x - fltDx * fltTail, y: objCenter.y - fltDy * fltTail))
            objPath.addLine(to: CGPoint(x: objCenter.x + fltDx * fltLength, y: objCenter.y + fltDy * fltLength))
            objCanvas.stroke(objPath, with: .color(objColor), style: StrokeStyle(lineWidth: fltWidth, lineCap: .round))
        }
        let objWhite = Color(white: 0.96)
        let objOrange = Color(red: 1, green: 0.62, blue: 0.04)
        hand(dblHour / 12, fltLength: fltSide * 0.25, fltTail: 0, fltWidth: fltSide * 0.05, objColor: objWhite)
        hand(dblMinute / 60, fltLength: fltSide * 0.4, fltTail: 0, fltWidth: fltSide * 0.05, objColor: objWhite)
        hand(dblSecond / 60, fltLength: fltSide * 0.38, fltTail: fltSide * 0.07, fltWidth: fltSide * 0.016, objColor: objOrange)

        // Center cap: white ring, orange disc, dark pin.
        let fltCap = fltSide * 0.04
        objCanvas.fill(Path(ellipseIn: CGRect(x: objCenter.x - fltCap, y: objCenter.y - fltCap, width: fltCap * 2, height: fltCap * 2)), with: .color(objWhite))
        let fltInner = fltCap * 0.62
        objCanvas.fill(Path(ellipseIn: CGRect(x: objCenter.x - fltInner, y: objCenter.y - fltInner, width: fltInner * 2, height: fltInner * 2)), with: .color(objOrange))
        let fltPin = fltCap * 0.28
        objCanvas.fill(Path(ellipseIn: CGRect(x: objCenter.x - fltPin, y: objCenter.y - fltPin, width: fltPin * 2, height: fltPin * 2)), with: .color(.black))
    }
}
