import AppKit
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

/// Which display the dock lives on.
enum DockDisplayMode: String, CaseIterable, Identifiable {
    /// Always the display with the menu bar.
    case main
    /// Moves to whichever display the cursor pushes against the dock edge on.
    case followCursor

    var id: String { rawValue }

    /// Label for the settings picker.
    var strTitle: String {
        switch self {
        case .main: "Main display"
        case .followCursor: "Follow the cursor"
        }
    }
}

/// Look of the running-app indicator.
enum IndicatorStyle: String, CaseIterable, Identifiable {
    case dot
    case bar
    case none

    var id: String { rawValue }

    /// Label for the settings picker.
    var strTitle: String {
        switch self {
        case .dot: "Dot"
        case .bar: "Bar"
        case .none: "None"
        }
    }
}

/// Color wash over the dock's glass.
enum DockTint: String, CaseIterable, Identifiable {
    case none
    case accent
    case custom

    var id: String { rawValue }

    /// Label for the settings picker.
    var strTitle: String {
        switch self {
        case .none: "None"
        case .accent: "Accent color"
        case .custom: "Custom"
        }
    }
}

/// A named group of apps shown as one dock icon.
struct DockGroup: Codable, Equatable {
    var strName: String
    var arrStrMembers: [String]
    /// Tile color as `#RRGGBB`; `nil` for the default frosted gray.
    var strColorHex: String? = nil
}

/// Color choices offered for groups.
enum GroupColor {
    /// `(name, hex)`; `nil` hex means the default frosted look.
    static let arrObjPresets: [(strName: String, strHex: String?)] = [
        ("Default", nil),
        ("Red", "#EF4444"),
        ("Orange", "#F97316"),
        ("Yellow", "#EAB308"),
        ("Green", "#22C55E"),
        ("Teal", "#14B8A6"),
        ("Blue", "#3B82F6"),
        ("Purple", "#8B5CF6"),
        ("Pink", "#EC4899"),
        ("Graphite", "#52525B"),
    ]

    /// Parses `#RRGGBB` into an AppKit color.
    /// - Parameter strHex: Hex string.
    /// - Returns: Color, or `nil` if malformed.
    static func nsColor(_ strHex: String?) -> NSColor? {
        guard let strHex, let intValue = UInt32(strHex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((intValue >> 16) & 0xFF) / 255,
                       green: CGFloat((intValue >> 8) & 0xFF) / 255,
                       blue: CGFloat(intValue & 0xFF) / 255,
                       alpha: 1)
    }

    /// Round swatch image for menus and pickers.
    /// - Parameter strHex: Color, or `nil` for the default gray.
    /// - Returns: 14-pt swatch.
    static func swatch(_ strHex: String?) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { objRect in
            let objPath = NSBezierPath(ovalIn: objRect.insetBy(dx: 1, dy: 1))
            (nsColor(strHex) ?? NSColor(white: 0.6, alpha: 0.6)).setFill()
            objPath.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            objPath.lineWidth = 0.5
            objPath.stroke()
            return true
        }
    }
}

/// Entries in the pinned list. Stored as strings so older pin lists (plain
/// bundle IDs) keep working.
enum PinnedToken: Equatable {
    case app(String)
    case divider(String)
    case group(String)
    case folder(String)

    private static let strDividerPrefix = "divider:"
    private static let strGroupPrefix = "group:"
    private static let strFolderPrefix = "folder:"

    /// Parses a stored token.
    /// - Parameter strRaw: Stored string.
    init(_ strRaw: String) {
        if strRaw.hasPrefix(Self.strDividerPrefix) {
            self = .divider(String(strRaw.dropFirst(Self.strDividerPrefix.count)))
        } else if strRaw.hasPrefix(Self.strGroupPrefix) {
            self = .group(String(strRaw.dropFirst(Self.strGroupPrefix.count)))
        } else if strRaw.hasPrefix(Self.strFolderPrefix) {
            self = .folder(String(strRaw.dropFirst(Self.strFolderPrefix.count)))
        } else {
            self = .app(strRaw)
        }
    }

    /// The string stored in settings.
    var strRaw: String {
        switch self {
        case .app(let strId): strId
        case .divider(let strId): Self.strDividerPrefix + strId
        case .group(let strId): Self.strGroupPrefix + strId
        case .folder(let strPath): Self.strFolderPrefix + strPath
        }
    }

    /// A new divider token with a unique ID.
    static func newDivider() -> String { PinnedToken.divider(UUID().uuidString).strRaw }

    /// A new group token with a unique ID.
    /// - Returns: `(token, groupId)`.
    static func newGroup() -> (strToken: String, strGroupId: String) {
        let strId = UUID().uuidString
        return (PinnedToken.group(strId).strRaw, strId)
    }
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
        static let strShowLabels = "ShowLabels"
        static let strLivePreviews = "LivePreviews"
        static let strReducePreviewsOnBattery = "ReducePreviewsOnBattery"
        static let strDisplayMode = "DisplayMode"
        static let strGroups = "Groups"
        static let strShowTrash = "ShowTrash"
        static let strShowMinimized = "ShowMinimizedWindows"
        static let strTint = "Tint"
        static let strTintHex = "TintHex"
        static let strTintStrength = "TintStrength"
        static let strCompact = "Compact"
        static let strIndicatorStyle = "IndicatorStyle"
        static let strAddedDownloads = "DidAddDownloadsStack"
        static let strTrailingPinned = "TrailingPinned"
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

    /// Folder stacks pinned on the right, next to the Trash (like the native Dock).
    var arrStrTrailingPinned: [String] { didSet { objDefaults.set(arrStrTrailingPinned, forKey: Key.strTrailingPinned) } }

    /// Whether the app's name appears above a hovered icon.
    var blnShowLabels: Bool { didSet { objDefaults.set(blnShowLabels, forKey: Key.strShowLabels) } }

    /// Whether window previews keep updating while the picker is open.
    var blnLivePreviews: Bool { didSet { objDefaults.set(blnLivePreviews, forKey: Key.strLivePreviews) } }

    /// Whether live previews drop to 30 fps on battery or in Low Power Mode.
    var blnReducePreviewsOnBattery: Bool { didSet { objDefaults.set(blnReducePreviewsOnBattery, forKey: Key.strReducePreviewsOnBattery) } }

    /// Which display the dock lives on.
    var enmDisplayMode: DockDisplayMode { didSet { objDefaults.set(enmDisplayMode.rawValue, forKey: Key.strDisplayMode) } }

    /// App groups by ID (their tokens live in the pinned list).
    var dictObjGroups: [String: DockGroup] {
        didSet {
            if let objData = try? JSONEncoder().encode(dictObjGroups) {
                objDefaults.set(objData, forKey: Key.strGroups)
            }
        }
    }

    /// Whether the Trash appears at the end of the dock.
    var blnShowTrash: Bool { didSet { objDefaults.set(blnShowTrash, forKey: Key.strShowTrash) } }

    /// Whether minimized windows get their own tiles at the end of the dock.
    var blnShowMinimized: Bool { didSet { objDefaults.set(blnShowMinimized, forKey: Key.strShowMinimized) } }

    /// Color wash over the glass.
    var enmTint: DockTint { didSet { objDefaults.set(enmTint.rawValue, forKey: Key.strTint) } }

    /// Custom tint color as `#RRGGBB`.
    var strTintHex: String { didSet { objDefaults.set(strTintHex, forKey: Key.strTintHex) } }

    /// Tint strength (0 = clear glass, 1 = solid color).
    var fltTintStrength: Double { didSet { objDefaults.set(fltTintStrength, forKey: Key.strTintStrength) } }

    /// Tighter padding and spacing.
    var blnCompact: Bool { didSet { objDefaults.set(blnCompact, forKey: Key.strCompact) } }

    /// Running-app indicator look.
    var enmIndicatorStyle: IndicatorStyle { didSet { objDefaults.set(enmIndicatorStyle.rawValue, forKey: Key.strIndicatorStyle) } }

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
            Key.strShowLabels: true,
            Key.strLivePreviews: true,
            Key.strReducePreviewsOnBattery: true,
            Key.strDisplayMode: DockDisplayMode.main.rawValue,
            Key.strShowTrash: true,
            Key.strShowMinimized: true,
            Key.strTint: DockTint.none.rawValue,
            Key.strTintHex: "#3B82F6",
            Key.strTintStrength: 0.25,
            Key.strCompact: false,
            Key.strIndicatorStyle: IndicatorStyle.dot.rawValue,
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
        arrStrTrailingPinned = objDefaults.stringArray(forKey: Key.strTrailingPinned) ?? []
        blnShowLabels = objDefaults.bool(forKey: Key.strShowLabels)
        blnLivePreviews = objDefaults.bool(forKey: Key.strLivePreviews)
        blnReducePreviewsOnBattery = objDefaults.bool(forKey: Key.strReducePreviewsOnBattery)
        enmDisplayMode = DockDisplayMode(rawValue: objDefaults.string(forKey: Key.strDisplayMode) ?? "") ?? .main
        dictObjGroups = objDefaults.data(forKey: Key.strGroups)
            .flatMap { try? JSONDecoder().decode([String: DockGroup].self, from: $0) } ?? [:]
        blnShowTrash = objDefaults.bool(forKey: Key.strShowTrash)
        blnShowMinimized = objDefaults.bool(forKey: Key.strShowMinimized)
        enmTint = DockTint(rawValue: objDefaults.string(forKey: Key.strTint) ?? "") ?? .none
        strTintHex = objDefaults.string(forKey: Key.strTintHex) ?? "#3B82F6"
        fltTintStrength = objDefaults.double(forKey: Key.strTintStrength)
        blnCompact = objDefaults.bool(forKey: Key.strCompact)
        enmIndicatorStyle = IndicatorStyle(rawValue: objDefaults.string(forKey: Key.strIndicatorStyle) ?? "") ?? .dot
        blnLaunchAtLogin = SMAppService.mainApp.status == .enabled

        // One-time: give everyone a Downloads stack (removable like any pin).
        if !objDefaults.bool(forKey: Key.strAddedDownloads) {
            objDefaults.set(true, forKey: Key.strAddedDownloads)
            let strDownloads = PinnedToken.folder(NSHomeDirectory() + "/Downloads").strRaw
            if !arrStrPinnedBundleIds.contains(strDownloads) && !arrStrTrailingPinned.contains(strDownloads) {
                // On the right, next to the Trash. Observers don't run inside init; persist explicitly.
                arrStrTrailingPinned.append(strDownloads)
                objDefaults.set(arrStrTrailingPinned, forKey: Key.strTrailingPinned)
            }
        }
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
