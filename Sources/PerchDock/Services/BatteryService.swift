import Foundation
import IOKit.ps
import Observation

/// Internal battery level and charging state, from IOKit's power-source API.
///
/// Updates on power-source notifications (plug/unplug, level steps) with a slow
/// poll as backup. Desktops without a battery report `blnHasBattery == false`.
@MainActor
@Observable
final class BatteryService {
    /// Charge, 0…100.
    private(set) var intPercent = 0
    /// Plugged in and charging.
    private(set) var blnIsCharging = false
    /// Plugged in (charging or held at a limit).
    private(set) var blnIsPluggedIn = false
    /// Whether this Mac has an internal battery.
    private(set) var blnHasBattery = false
    /// Minutes to empty (on battery) or full (charging), when macOS has an estimate.
    private(set) var intMinutesRemaining: Int?

    /// Called when anything above changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var objRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var objPollTask: Task<Void, Never>?

    /// Reads the battery now and starts listening for changes.
    func start() {
        guard objPollTask == nil else { return }
        refresh()

        // Power-source change callback (C function pointer, so no captures: route via a notification).
        if let objSource = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: BatteryService.objChangedNotification, object: nil)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), objSource, .defaultMode)
            objRunLoopSource = objSource
        }
        NotificationCenter.default.addObserver(forName: Self.objChangedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        objPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refresh()
            }
        }
    }

    /// Posted (on the main run loop) when IOKit reports a power-source change.
    nonisolated private static let objChangedNotification = Notification.Name("PerchDock.BatteryChanged")

    /// Re-reads the internal battery.
    func refresh() {
        guard let objInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let arrObjSources = IOPSCopyPowerSourcesList(objInfo)?.takeRetainedValue() as? [CFTypeRef] else { return }

        // The internal battery, if any.
        let dictBattery = arrObjSources.lazy
            .compactMap { IOPSGetPowerSourceDescription(objInfo, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }

        let blnHas = dictBattery != nil
        let intCurrent = dictBattery?[kIOPSCurrentCapacityKey] as? Int ?? 0
        let intMax = max(dictBattery?[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let intPct = min(100, max(0, Int((Double(intCurrent) / Double(intMax) * 100).rounded())))
        let blnCharging = dictBattery?[kIOPSIsChargingKey] as? Bool ?? false
        let blnPlugged = (dictBattery?[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // -1 means "still calculating".
        let intMinutes = (blnCharging ? dictBattery?[kIOPSTimeToFullChargeKey] : dictBattery?[kIOPSTimeToEmptyKey]) as? Int
        let intRemaining = (intMinutes ?? -1) > 0 ? intMinutes : nil

        guard blnHas != blnHasBattery || intPct != intPercent || blnCharging != blnIsCharging
                || blnPlugged != blnIsPluggedIn || intRemaining != intMinutesRemaining else { return }
        blnHasBattery = blnHas
        intPercent = intPct
        blnIsCharging = blnCharging
        blnIsPluggedIn = blnPlugged
        intMinutesRemaining = intRemaining
        onChange?()
    }

    /// Short battery status using the user's locale for its duration.
    var strSummary: String {
        Self.summary(intPercent: intPercent, blnIsCharging: blnIsCharging,
                     blnIsPluggedIn: blnIsPluggedIn, intMinutesRemaining: intMinutesRemaining)
    }

    /// Formats a battery status without reading the power source.
    /// - Parameters:
    ///   - intPercent: Charge, 0...100.
    ///   - blnIsCharging: Whether the battery is charging.
    ///   - blnIsPluggedIn: Whether external power is connected.
    ///   - intMinutesRemaining: Minutes until full or empty, or nil when unknown.
    ///   - objLocale: Locale for the duration, defaulting to the user's current locale.
    /// - Returns: The battery tooltip text.
    static func summary(intPercent: Int, blnIsCharging: Bool, blnIsPluggedIn: Bool,
                        intMinutesRemaining: Int?, objLocale: Locale = .current) -> String {
        var strText = "Battery \(intPercent)%"
        if blnIsCharging {
            strText += " — Charging"
        } else if blnIsPluggedIn {
            strText += " — Plugged In"
        }
        if let intMinutesRemaining {
            let strTime = Duration.seconds(intMinutesRemaining * 60).formatted(
                .units(allowed: [.hours, .minutes], width: .abbreviated).locale(objLocale)
            )
            strText += blnIsCharging ? " (\(strTime) until full)" : " (\(strTime) left)"
        }
        return strText
    }
}
