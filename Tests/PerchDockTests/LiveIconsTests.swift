import Foundation
import Testing
@testable import PerchDock

/// Which apps get live icons, and where the clock's hands point.
@Suite("Live icons")
struct LiveIconsTests {
    /// Gregorian calendar in UTC, so results don't depend on the machine's time zone.
    private let objCalendar: Calendar = {
        var objCalendar = Calendar(identifier: .gregorian)
        objCalendar.timeZone = TimeZone(identifier: "UTC")!
        return objCalendar
    }()

    /// A UTC time on an arbitrary day.
    /// - Parameters:
    ///   - intHour: Hour (0–23).
    ///   - intMinute: Minute.
    ///   - intSecond: Second.
    /// - Returns: The date.
    private func time(_ intHour: Int, _ intMinute: Int, _ intSecond: Int) -> Date {
        objCalendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: intHour, minute: intMinute, second: intSecond))!
    }

    @Test("Calendar and Clock have live icons; other apps don't")
    func supportedApps() {
        #expect(LiveIcons.supports("com.apple.iCal"))
        #expect(LiveIcons.supports("com.apple.clock"))
        #expect(!LiveIcons.supports("com.apple.finder"))
        #expect(!LiveIcons.supports("com.apple.ActivityMonitor"))
    }

    @Test("At 12:00:00 every hand points straight up")
    func noon() {
        let objTurns = LiveIcons.clockHandTurns(for: time(12, 0, 0), objCalendar: objCalendar)
        #expect(objTurns.dblHour == 0)
        #expect(objTurns.dblMinute == 0)
        #expect(objTurns.dblSecond == 0)
    }

    @Test("At 3:00 the hour hand points right; at 15:00 too (12-hour dial)")
    func threeOClock() {
        #expect(LiveIcons.clockHandTurns(for: time(3, 0, 0), objCalendar: objCalendar).dblHour == 0.25)
        #expect(LiveIcons.clockHandTurns(for: time(15, 0, 0), objCalendar: objCalendar).dblHour == 0.25)
    }

    @Test("At 6:30 the hour hand sits halfway between 6 and 7, the minute hand points down")
    func halfPastSix() {
        let objTurns = LiveIcons.clockHandTurns(for: time(6, 30, 0), objCalendar: objCalendar)
        #expect(abs(objTurns.dblHour - 6.5 / 12) < 1e-9)
        #expect(objTurns.dblMinute == 0.5)
    }

    @Test("Seconds nudge the minute hand forward smoothly")
    func secondsMoveMinuteHand() {
        let objTurns = LiveIcons.clockHandTurns(for: time(9, 15, 30), objCalendar: objCalendar)
        #expect(objTurns.dblSecond == 0.5)
        #expect(abs(objTurns.dblMinute - 15.5 / 60) < 1e-9)
    }
}
