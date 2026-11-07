import Foundation
import Observation
import ServiceManagement

/// Screen edge the dock is attached to.
enum DockPosition: String, CaseIterable, Identifiable {
    case left
    case bottom
    case right

    var id: String { rawValue }

    /// Label for the settings picker.
    var strTitle: String {
        switch self {
        case .left: "Left"
        case .bottom: "Bottom"
        case .right: "Right"
        }
    }

    /// Whether icons run top-to-bottom.
    var blnIsVertical: Bool { self != .bottom }
}

/// All user preferences, persisted to UserDefaults on every change.
/// Views bind to it directly; controllers observe it to re-layout.
@MainActor
@Observable
final class SettingsStore {
    /// UserDefaults keys.
    private enum Key {
        static let strIconSize = "IconSize"
        static let strMagnificationOn = "MagnificationEnabled"
        static let strMagnification = "Magnification"
        static let strPosition = "Position"
        static let strAutoHide = "AutoHide"
        static let strShowDelay = "AutoHideShowDelay"
        static let strHideDelay = "AutoHideHideDelay"
        static let strPreviewDelay = "PreviewDelay"
        static let strHideNativeDock = "HideNativeDock"
        static let strPinned = "PinnedBundleIds"
    }

    /// Pins used on first launch.
    static let arrStrDefaultPinned = [
        "com.apple.finder",
        "com.google.Chrome",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.apple.systempreferences",
    ]

    @ObservationIgnored private let objDefaults = UserDefaults.standard

    /// Icon edge length in points (32–96).
    var fltIconSize: Double { didSet { objDefaults.set(fltIconSize, forKey: Key.strIconSize) } }

    /// Whether icons near the cursor grow.
    var blnMagnificationOn: Bool { didSet { objDefaults.set(blnMagnificationOn, forKey: Key.strMagnificationOn) } }

    /// Peak magnification factor (1.1–2.0).
    var fltMagnification: Double { didSet { objDefaults.set(fltMagnification, forKey: Key.strMagnification) } }

    /// Screen edge the dock sits on.
    var enmPosition: DockPosition { didSet { objDefaults.set(enmPosition.rawValue, forKey: Key.strPosition) } }

    /// Whether the dock slides away until the cursor reaches the screen edge.
    var blnAutoHide: Bool { didSet { objDefaults.set(blnAutoHide, forKey: Key.strAutoHide) } }

    /// Seconds the cursor must rest at the edge before the dock appears.
    var fltShowDelay: Double { didSet { objDefaults.set(fltShowDelay, forKey: Key.strShowDelay) } }

    /// Seconds after the cursor leaves before the dock hides.
    var fltHideDelay: Double { didSet { objDefaults.set(fltHideDelay, forKey: Key.strHideDelay) } }

    /// Seconds of hovering an icon before window previews open.
    var fltPreviewDelay: Double { didSet { objDefaults.set(fltPreviewDelay, forKey: Key.strPreviewDelay) } }

    /// Whether the native macOS Dock is hidden while MacDock runs.
    var blnHideNativeDock: Bool {
        didSet {
            objDefaults.set(blnHideNativeDock, forKey: Key.strHideNativeDock)
            onHideNativeDockChange?(blnHideNativeDock)
        }
    }

    /// Pinned apps in dock order.
    var arrStrPinnedBundleIds: [String] { didSet { objDefaults.set(arrStrPinnedBundleIds, forKey: Key.strPinned) } }

    /// Whether MacDock starts at login (mirrors the system's login item state).
    private(set) var blnLaunchAtLogin: Bool

    /// Called when the native Dock preference changes, so it can be applied.
    @ObservationIgnored var onHideNativeDockChange: ((Bool) -> Void)?

    /// Peak magnification actually applied (1 when magnification is off).
    var fltEffectiveMagnification: Double {
        blnMagnificationOn ? fltMagnification : 1
    }

    /// Loads saved preferences, falling back to defaults.
    init() {
        objDefaults.register(defaults: [
            Key.strIconSize: 52.0,
            Key.strMagnificationOn: true,
            Key.strMagnification: 1.5,
            Key.strPosition: DockPosition.bottom.rawValue,
            Key.strAutoHide: false,
            Key.strShowDelay: 0.1,
            Key.strHideDelay: 0.4,
            Key.strPreviewDelay: 0.32,
            Key.strHideNativeDock: false,
            Key.strPinned: Self.arrStrDefaultPinned,
        ])

        fltIconSize = objDefaults.double(forKey: Key.strIconSize)
        blnMagnificationOn = objDefaults.bool(forKey: Key.strMagnificationOn)
        fltMagnification = objDefaults.double(forKey: Key.strMagnification)
        enmPosition = DockPosition(rawValue: objDefaults.string(forKey: Key.strPosition) ?? "") ?? .bottom
        blnAutoHide = objDefaults.bool(forKey: Key.strAutoHide)
        fltShowDelay = objDefaults.double(forKey: Key.strShowDelay)
        fltHideDelay = objDefaults.double(forKey: Key.strHideDelay)
        fltPreviewDelay = objDefaults.double(forKey: Key.strPreviewDelay)
        blnHideNativeDock = objDefaults.bool(forKey: Key.strHideNativeDock)
        arrStrPinnedBundleIds = objDefaults.stringArray(forKey: Key.strPinned) ?? Self.arrStrDefaultPinned
        blnLaunchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Registers or removes MacDock as a login item.
    /// - Parameter blnEnabled: Desired state.
    func setLaunchAtLogin(_ blnEnabled: Bool) {
        do {
            if blnEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacDock: launch at login change failed: \(error)")
        }
        // Reflect what the system actually did, not what was requested.
        blnLaunchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
