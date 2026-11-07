import AppKit
import Observation

/// One icon in the dock: a pinned app, a running app, or both.
struct DockItem: Identifiable {
    let strBundleId: String
    let strName: String
    let objIcon: NSImage
    let objAppUrl: URL?
    let objRunningApp: NSRunningApplication?
    let blnIsPinned: Bool

    var id: String { strBundleId }
    var blnIsRunning: Bool { objRunningApp.map { !$0.isTerminated } ?? false }
}

/// Keeps the ordered list of dock items in sync with pinned and running apps.
@MainActor
@Observable
final class AppTracker {
    /// Items in display order: pinned apps first, then other running apps.
    private(set) var arrObjItems: [DockItem] = []

    /// Bundle ID of the frontmost app, for the active indicator.
    private(set) var strActiveBundleId: String?

    /// Called after `arrObjItems` changes so the panel can resize.
    @ObservationIgnored var onItemsChanged: (() -> Void)?

    // Phase 0 default pins; Phase 2 makes these user-editable and persisted.
    @ObservationIgnored private let arrStrPinnedBundleIds = [
        "com.apple.finder",
        "com.google.Chrome",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.apple.systempreferences",
    ]

    @ObservationIgnored private var arrObjObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var dictObjIconCache: [String: NSImage] = [:]

    /// Subscribes to app launch/quit/activation events and builds the initial list.
    func start() {
        let objCenter = NSWorkspace.shared.notificationCenter
        let arrStrNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]

        // Workspace notifications arrive on the main queue; hop into the actor explicitly.
        for objName in arrStrNames {
            let objToken = objCenter.addObserver(forName: objName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
            arrObjObservers.append(objToken)
        }

        rebuild()
    }

    /// Recomputes the item list from the pinned list and the running applications.
    func rebuild() {
        let strOwnBundleId = Bundle.main.bundleIdentifier

        // Only "regular" apps belong in a dock (not agents or background helpers).
        let arrObjRunning = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != strOwnBundleId
        }

        // First running instance per bundle ID wins.
        var dictObjRunningById: [String: NSRunningApplication] = [:]
        for objApp in arrObjRunning {
            if let strId = objApp.bundleIdentifier, dictObjRunningById[strId] == nil {
                dictObjRunningById[strId] = objApp
            }
        }

        var arrObjNewItems: [DockItem] = []

        // Pinned apps keep their slot whether or not they're running.
        for strId in arrStrPinnedBundleIds {
            guard let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strId) else { continue }
            arrObjNewItems.append(makeItem(strBundleId: strId, objAppUrl: objUrl, objRunningApp: dictObjRunningById[strId], blnIsPinned: true))
        }

        // Then every running app that isn't pinned, in launch order.
        let setStrPinned = Set(arrStrPinnedBundleIds)
        for objApp in arrObjRunning {
            guard let strId = objApp.bundleIdentifier, !setStrPinned.contains(strId),
                  !arrObjNewItems.contains(where: { $0.strBundleId == strId }) else { continue }
            arrObjNewItems.append(makeItem(strBundleId: strId, objAppUrl: objApp.bundleURL, objRunningApp: objApp, blnIsPinned: false))
        }

        let blnCountChanged = arrObjNewItems.count != arrObjItems.count
        arrObjItems = arrObjNewItems
        strActiveBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if blnCountChanged {
            onItemsChanged?()
        }
    }

    /// Builds a `DockItem`, resolving its display name and (cached) icon.
    /// - Parameters:
    ///   - strBundleId: App bundle identifier.
    ///   - objAppUrl: Location of the `.app` bundle, if known.
    ///   - objRunningApp: Running instance, if any.
    ///   - blnIsPinned: Whether the app is pinned.
    /// - Returns: A ready-to-render dock item.
    private func makeItem(strBundleId: String, objAppUrl: URL?, objRunningApp: NSRunningApplication?, blnIsPinned: Bool) -> DockItem {
        let strName = objRunningApp?.localizedName
            ?? objAppUrl.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? strBundleId

        return DockItem(
            strBundleId: strBundleId,
            strName: strName,
            objIcon: icon(strBundleId: strBundleId, objAppUrl: objAppUrl, objRunningApp: objRunningApp),
            objAppUrl: objAppUrl,
            objRunningApp: objRunningApp,
            blnIsPinned: blnIsPinned
        )
    }

    /// Returns the app icon, loading it once and caching by bundle ID.
    /// - Parameters:
    ///   - strBundleId: Cache key.
    ///   - objAppUrl: Bundle location used to load the icon.
    ///   - objRunningApp: Running instance, used as a fallback icon source.
    /// - Returns: The app's icon image.
    private func icon(strBundleId: String, objAppUrl: URL?, objRunningApp: NSRunningApplication?) -> NSImage {
        if let objCached = dictObjIconCache[strBundleId] {
            return objCached
        }
        let objIcon = objAppUrl.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? objRunningApp?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        dictObjIconCache[strBundleId] = objIcon
        return objIcon
    }
}
