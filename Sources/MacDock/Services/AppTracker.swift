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

    /// Called after the set or order of items changes so the panel can resize.
    @ObservationIgnored var onItemsChanged: (() -> Void)?

    @ObservationIgnored private let objSettings: SettingsStore
    @ObservationIgnored private var arrObjObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var dictObjIconCache: [String: NSImage] = [:]

    /// Creates a tracker that reads pinned apps from settings.
    /// - Parameter objSettings: User preferences (owns the pinned list).
    init(objSettings: SettingsStore) {
        self.objSettings = objSettings
    }

    // MARK: - Pinning

    /// Pins an app.
    /// - Parameters:
    ///   - strBundleId: App to pin.
    ///   - intIndex: Position among visible pinned items, or `nil` to append.
    func pin(_ strBundleId: String, at intIndex: Int? = nil) {
        var arrStrVisible = visiblePinnedIds().filter { $0 != strBundleId }
        let intTarget = min(max(intIndex ?? arrStrVisible.count, 0), arrStrVisible.count)
        arrStrVisible.insert(strBundleId, at: intTarget)
        savePinned(arrStrVisible)
    }

    /// Unpins an app (it stays in the dock while running).
    /// - Parameter strBundleId: App to unpin.
    func unpin(_ strBundleId: String) {
        savePinned(visiblePinnedIds().filter { $0 != strBundleId })
    }

    /// Applies a drag-reorder: pinned items move within the pinned group; a running
    /// item dropped among pinned ones becomes pinned there.
    /// - Parameters:
    ///   - strBundleId: Dragged item.
    ///   - intSlot: Slot it was dropped in (index into the full item list).
    func move(_ strBundleId: String, toSlot intSlot: Int) {
        let arrStrVisible = visiblePinnedIds()
        if arrStrVisible.contains(strBundleId) {
            pin(strBundleId, at: min(intSlot, arrStrVisible.count - 1))
        } else if intSlot <= arrStrVisible.count {
            pin(strBundleId, at: intSlot)
        }
    }

    /// Pinned IDs currently shown (installed apps), in dock order.
    /// - Returns: Bundle IDs.
    private func visiblePinnedIds() -> [String] {
        arrObjItems.filter(\.blnIsPinned).map(\.strBundleId)
    }

    /// Saves a new visible pinned order, keeping pins for apps that aren't installed
    /// right now (e.g. on an unmounted drive) so they come back later.
    /// - Parameter arrStrVisible: New order of visible pinned items.
    private func savePinned(_ arrStrVisible: [String]) {
        let setStrVisibleBefore = Set(visiblePinnedIds())
        let arrStrHidden = objSettings.arrStrPinnedBundleIds.filter {
            !setStrVisibleBefore.contains($0) && !arrStrVisible.contains($0)
        }
        objSettings.arrStrPinnedBundleIds = arrStrVisible + arrStrHidden
        rebuild()
    }

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
        let arrStrPinned = objSettings.arrStrPinnedBundleIds

        // Pinned apps keep their slot whether or not they're running.
        for strId in arrStrPinned {
            guard let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strId) else { continue }
            arrObjNewItems.append(makeItem(strBundleId: strId, objAppUrl: objUrl, objRunningApp: dictObjRunningById[strId], blnIsPinned: true))
        }

        // Then every running app that isn't pinned, in launch order.
        let setStrPinned = Set(arrStrPinned)
        for objApp in arrObjRunning {
            guard let strId = objApp.bundleIdentifier, !setStrPinned.contains(strId),
                  !arrObjNewItems.contains(where: { $0.strBundleId == strId }) else { continue }
            arrObjNewItems.append(makeItem(strBundleId: strId, objAppUrl: objApp.bundleURL, objRunningApp: objApp, blnIsPinned: false))
        }

        let blnItemsChanged = arrObjNewItems.map(\.id) != arrObjItems.map(\.id)
        arrObjItems = arrObjNewItems
        strActiveBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if blnItemsChanged {
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
