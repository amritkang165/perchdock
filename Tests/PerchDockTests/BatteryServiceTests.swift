import Foundation
import Testing
@testable import PerchDock

/// Battery tooltip formatting with fixed locales and invented power-source readings.
@MainActor
@Suite("Battery summary")
struct BatteryServiceTests {
    /// Charging durations include localized units and the full-charge destination.
    @Test("Charging shows hours and minutes until full")
    func charging() {
        #expect(BatteryService.summary(intPercent: 82, blnIsCharging: true, blnIsPluggedIn: true,
                                       intMinutesRemaining: 65, objLocale: Locale(identifier: "en_US"))
                == "Battery 82% \u{2014} Charging (1 hr, 5 min until full)")
    }

    /// Estimates use duration units even below ten minutes or at an exact hour.
    /// - Parameters:
    ///   - intMinutes: Invented remaining duration.
    ///   - strTime: Expected English duration.
    @Test("Discharging shows a duration, not a clock time", arguments: [
        (5, "5 min"), (60, "1 hr"), (65, "1 hr, 5 min"), (120, "2 hr")
    ])
    func discharging(intMinutes: Int, strTime: String) {
        #expect(BatteryService.summary(intPercent: 42, blnIsCharging: false, blnIsPluggedIn: false,
                                       intMinutesRemaining: intMinutes, objLocale: Locale(identifier: "en_US"))
                == "Battery 42% (\(strTime) left)")
    }

    /// An explicit non-English locale changes the units rather than inheriting the test host's locale.
    @Test("Duration units follow the requested locale")
    func germanDuration() {
        #expect(BatteryService.summary(intPercent: 82, blnIsCharging: true, blnIsPluggedIn: true,
                                       intMinutesRemaining: 65, objLocale: Locale(identifier: "de_DE"))
                == "Battery 82% \u{2014} Charging (1 Std., 5 Min. until full)")
    }

    /// Missing estimates stay absent for each power state.
    /// - Parameters:
    ///   - blnCharging: Whether the battery is charging.
    ///   - blnPlugged: Whether external power is connected.
    ///   - strExpected: Expected status without a fabricated duration.
    @Test("Unknown time adds no duration", arguments: [
        (false, false, "Battery 82%"),
        (true, true, "Battery 82% \u{2014} Charging"),
        (false, true, "Battery 82% \u{2014} Plugged In")
    ])
    func unknownTime(blnCharging: Bool, blnPlugged: Bool, strExpected: String) {
        #expect(BatteryService.summary(intPercent: 82, blnIsCharging: blnCharging, blnIsPluggedIn: blnPlugged,
                                       intMinutesRemaining: nil, objLocale: Locale(identifier: "en_US")) == strExpected)
    }

    /// Connecting power without charging does not imply a time until full.
    @Test("Plugged-in state does not claim the battery is charging")
    func pluggedIn() {
        #expect(BatteryService.summary(intPercent: 82, blnIsCharging: false, blnIsPluggedIn: true,
                                       intMinutesRemaining: 65, objLocale: Locale(identifier: "en_US"))
                == "Battery 82% \u{2014} Plugged In (1 hr, 5 min left)")
    }
}
