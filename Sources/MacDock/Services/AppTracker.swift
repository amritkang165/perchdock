import AppKit
import Observation

/// One tile in the dock.
struct DockItem: Identifiable {
    /// What the tile is.
    enum Kind {
        /// An app (pinned, running, or both).
        case app
        /// A divider line. Automatic ones separate sections and can't be moved.
        case divider(blnIsAuto: Bool)
        /// Several apps shown as one icon; clicking opens them in a grid.
        case group(strGroupId: String, arrObjMembers: [DockItem])
        /// A folder stack (e.g. Downloads).
        case folder(objUrl: URL)
        /// The Trash.
        case trash(blnIsFull: Bool)
        /// A minimized window.
        case minimized(objWindow: WindowInfo, objApp: NSRunningApplication)
    }

    /// Stable ID: the pinned token (bundle ID for apps) or a synthetic ID.
    let strBundleId: String
    let enmKind: Kind
    let strName: String
    let objIcon: NSImage
    let objAppUrl: URL?
    let objRunningApp: NSRunningApplication?
    let blnIsPinned: Bool

    var id: String { strBundleId }
    var blnIsRunning: Bool { objRunningApp.map { !$0.isTerminated } ?? false }

    /// Whether this is an app tile.
    var blnIsApp: Bool {
        if case .app = enmKind { return true }
        return false
    }

    /// Whether this is a divider (drawn as a thin line, not magnified).
    var blnIsDivider: Bool {
        if case .divider = enmKind { return true }
        return false
    }

    /// Whether the user can drag this tile (pinned things only; not automatic dividers).
    var blnIsMovable: Bool {
        switch enmKind {
        case .app: true
        case .divider(let blnIsAuto): !blnIsAuto
        case .group, .folder: true
        case .trash, .minimized: false
        }
    }
}

/// Keeps the ordered list of dock items in sync with pinned entries, running
/// apps, minimized windows and the Trash.
///
/// Order: pinned entries (apps, dividers, groups, folders) | running apps |
/// minimized windows, Trash — sections separated by automatic dividers.
@MainActor
@Observable
final class AppTracker {
    private static let strTrashId = "trash"
    private static let strRunningDividerId = "auto-divider:running"
    private static let strTrailingDividerId = "auto-divider:trailing"

    /// Items in display order.
    private(set) var arrObjItems: [DockItem] = []

    /// Bundle ID of the frontmost app, for the active indicator.
    private(set) var strActiveBundleId: String?

    /// Called after the set or order of items changes so the panel can resize.
    @ObservationIgnored var onItemsChanged: (() -> Void)?

    @ObservationIgnored private let objSettings: SettingsStore
    @ObservationIgnored private let objMinimized = MinimizedWindowService()
    @ObservationIgnored private var arrObjObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var dictObjIconCache: [String: NSImage] = [:]
    @ObservationIgnored private var blnTrashWasFull: Bool?
    @ObservationIgnored private var objTrashTask: Task<Void, Never>?

    /// Thumbnails for minimized tiles (last captured preview), if available.
    @ObservationIgnored var fnThumbnail: ((CGWindowID) -> NSImage?)?

    /// Creates a tracker that reads pinned entries from settings.
    /// - Parameter objSettings: User preferences (owns the pinned list and groups).
    init(objSettings: SettingsStore) {
        self.objSettings = objSettings
    }

    // MARK: - Pinning

    /// Pins an entry (app bundle ID or other token).
    /// - Parameters:
    ///   - strToken: Entry to pin.
    ///   - intIndex: Position among visible pinned items, or `nil` to append.
    func pin(_ strToken: String, at intIndex: Int? = nil) {
        var arrStrVisible = visiblePinnedIds().filter { $0 != strToken }
        let intTarget = min(max(intIndex ?? arrStrVisible.count, 0), arrStrVisible.count)
        arrStrVisible.insert(strToken, at: intTarget)
        savePinned(arrStrVisible)
    }

    /// Unpins an entry (an app stays in the dock while running). Removing a group
    /// also deletes its definition.
    /// - Parameter strToken: Entry to unpin.
    func unpin(_ strToken: String) {
        if case .group(let strGroupId) = PinnedToken(strToken) {
            objSettings.dictObjGroups.removeValue(forKey: strGroupId)
        }
        savePinned(visiblePinnedIds().filter { $0 != strToken })
    }

    /// Applies a drag-reorder: pinned items move within the pinned section; a
    /// running item dropped among pinned ones becomes pinned there.
    /// - Parameters:
    ///   - strToken: Dragged item.
    ///   - intSlot: Slot it was dropped in (index into the full item list).
    func move(_ strToken: String, toSlot intSlot: Int) {
        let arrStrVisible = visiblePinnedIds()
        if arrStrVisible.contains(strToken) {
            pin(strToken, at: min(intSlot, arrStrVisible.count - 1))
        } else if intSlot <= arrStrVisible.count {
            pin(strToken, at: intSlot)
        }
    }

    /// Inserts a divider into the pinned section.
    /// - Parameter intIndex: Position among pinned items (`nil` = end).
    func addDivider(at intIndex: Int?) {
        pin(PinnedToken.newDivider(), at: intIndex)
    }

    /// Pins a folder as a stack.
    /// - Parameters:
    ///   - objUrl: Folder.
    ///   - intIndex: Position among pinned items (`nil` = end).
    func addFolder(_ objUrl: URL, at intIndex: Int?) {
        pin(PinnedToken.folder(objUrl.path).strRaw, at: intIndex)
    }

    // MARK: - Groups

    /// Makes a new group from an app, in that app's place.
    /// - Parameter strBundleId: App to start the group with.
    /// - Returns: The new group's ID.
    @discardableResult
    func createGroup(with strBundleId: String) -> String {
        let (strToken, strGroupId) = PinnedToken.newGroup()
        let strName = arrObjItems.first { $0.strBundleId == strBundleId }?.strName ?? "Group"
        objSettings.dictObjGroups[strGroupId] = DockGroup(strName: "\(strName) Group", arrStrMembers: [strBundleId])

        var arrStrVisible = visiblePinnedIds()
        if let intIndex = arrStrVisible.firstIndex(of: strBundleId) {
            arrStrVisible[intIndex] = strToken
        } else {
            arrStrVisible.append(strToken)
        }
        savePinned(arrStrVisible)
        return strGroupId
    }

    /// Moves an app into a group (unpinning it from the bar).
    /// - Parameters:
    ///   - strBundleId: App to add.
    ///   - strGroupId: Destination group.
    func add(_ strBundleId: String, toGroup strGroupId: String) {
        guard var objGroup = objSettings.dictObjGroups[strGroupId] else { return }
        // An app lives in at most one group.
        for (strOtherId, var objOther) in objSettings.dictObjGroups where strOtherId != strGroupId {
            objOther.arrStrMembers.removeAll { $0 == strBundleId }
            objSettings.dictObjGroups[strOtherId] = objOther
        }
        if !objGroup.arrStrMembers.contains(strBundleId) {
            objGroup.arrStrMembers.append(strBundleId)
        }
        objSettings.dictObjGroups[strGroupId] = objGroup
        savePinned(visiblePinnedIds().filter { $0 != strBundleId })
    }

    /// Takes an app out of its group and pins it right after the group.
    /// - Parameters:
    ///   - strBundleId: App to remove.
    ///   - strGroupId: Its group.
    func remove(_ strBundleId: String, fromGroup strGroupId: String) {
        guard var objGroup = objSettings.dictObjGroups[strGroupId] else { return }
        objGroup.arrStrMembers.removeAll { $0 == strBundleId }
        objSettings.dictObjGroups[strGroupId] = objGroup

        var arrStrVisible = visiblePinnedIds()
        let intGroupIndex = arrStrVisible.firstIndex(of: PinnedToken.group(strGroupId).strRaw) ?? arrStrVisible.count - 1
        arrStrVisible.insert(strBundleId, at: min(intGroupIndex + 1, arrStrVisible.count))
        savePinned(arrStrVisible)
    }

    /// Renames a group.
    /// - Parameters:
    ///   - strGroupId: Group.
    ///   - strName: New name.
    func renameGroup(_ strGroupId: String, to strName: String) {
        objSettings.dictObjGroups[strGroupId]?.strName = strName
        rebuild()
    }

    /// Dissolves a group, putting its apps back on the bar where it was.
    /// - Parameter strGroupId: Group.
    func ungroup(_ strGroupId: String) {
        let arrStrMembers = objSettings.dictObjGroups[strGroupId]?.arrStrMembers ?? []
        objSettings.dictObjGroups.removeValue(forKey: strGroupId)

        var arrStrVisible = visiblePinnedIds()
        let strToken = PinnedToken.group(strGroupId).strRaw
        if let intIndex = arrStrVisible.firstIndex(of: strToken) {
            arrStrVisible.replaceSubrange(intIndex...intIndex, with: arrStrMembers.filter { !arrStrVisible.contains($0) })
        }
        savePinned(arrStrVisible)
    }

    /// Groups that exist, for "Add to Group" menus.
    /// - Returns: `(id, name)` pairs in dock order.
    func groups() -> [(strId: String, strName: String)] {
        arrObjItems.compactMap { objItem in
            guard case .group(let strGroupId, _) = objItem.enmKind else { return nil }
            return (strGroupId, objItem.strName)
        }
    }

    /// Pinned tokens currently shown, in dock order.
    /// - Returns: Tokens.
    private func visiblePinnedIds() -> [String] {
        arrObjItems.filter(\.blnIsPinned).map(\.strBundleId)
    }

    /// Saves a new visible pinned order, keeping entries that aren't shown right
    /// now (apps on an unmounted drive, missing folders) so they come back later.
    /// - Parameter arrStrVisible: New order of visible pinned items.
    private func savePinned(_ arrStrVisible: [String]) {
        let setStrVisibleBefore = Set(visiblePinnedIds())
        let setStrGrouped = Set(objSettings.dictObjGroups.values.flatMap(\.arrStrMembers))
        let arrStrHidden = objSettings.arrStrPinnedBundleIds.filter {
            !setStrVisibleBefore.contains($0) && !arrStrVisible.contains($0) && !setStrGrouped.contains($0)
        }
        objSettings.arrStrPinnedBundleIds = arrStrVisible + arrStrHidden
        rebuild()
    }

    // MARK: - Building

    /// Subscribes to app and window events and builds the initial list.
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

        objMinimized.onChange = { [weak self] in
            self?.rebuild()
        }
        objMinimized.start()
        watchTrash()
        rebuild()
    }

    /// Recomputes the item list.
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
        var setStrPinnedApps = Set<String>()
        let dictObjGroups = objSettings.dictObjGroups

        // 1. Pinned entries keep their slot whether or not they're running.
        for strToken in objSettings.arrStrPinnedBundleIds {
            switch PinnedToken(strToken) {
            case .app(let strId):
                guard let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strId) else { continue }
                arrObjNewItems.append(makeApp(strBundleId: strId, objAppUrl: objUrl, objRunningApp: dictObjRunningById[strId], blnIsPinned: true))
                setStrPinnedApps.insert(strId)

            case .divider:
                arrObjNewItems.append(makeDivider(strId: strToken, blnIsAuto: false))

            case .group(let strGroupId):
                guard let objGroup = dictObjGroups[strGroupId] else { continue }
                let arrObjMembers = objGroup.arrStrMembers.compactMap { strId -> DockItem? in
                    guard let objUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: strId) else { return nil }
                    return makeApp(strBundleId: strId, objAppUrl: objUrl, objRunningApp: dictObjRunningById[strId], blnIsPinned: true)
                }
                setStrPinnedApps.formUnion(objGroup.arrStrMembers)
                arrObjNewItems.append(DockItem(
                    strBundleId: strToken,
                    enmKind: .group(strGroupId: strGroupId, arrObjMembers: arrObjMembers),
                    strName: objGroup.strName,
                    objIcon: GroupIconRenderer.icon(for: arrObjMembers.map(\.objIcon)),
                    objAppUrl: nil,
                    // Shows a running dot when any member runs.
                    objRunningApp: arrObjMembers.lazy.compactMap(\.objRunningApp).first,
                    blnIsPinned: true
                ))

            case .folder(let strPath):
                let objUrl = URL(fileURLWithPath: strPath)
                var blnIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: strPath, isDirectory: &blnIsDirectory), blnIsDirectory.boolValue else { continue }
                arrObjNewItems.append(DockItem(
                    strBundleId: strToken,
                    enmKind: .folder(objUrl: objUrl),
                    strName: FileManager.default.displayName(atPath: strPath),
                    objIcon: NSWorkspace.shared.icon(forFile: strPath),
                    objAppUrl: nil,
                    objRunningApp: nil,
                    blnIsPinned: true
                ))
            }
        }

        // 2. Running apps that aren't pinned (or grouped), in launch order.
        var arrObjRunningItems: [DockItem] = []
        for objApp in arrObjRunning {
            guard let strId = objApp.bundleIdentifier, !setStrPinnedApps.contains(strId),
                  !arrObjRunningItems.contains(where: { $0.strBundleId == strId }) else { continue }
            arrObjRunningItems.append(makeApp(strBundleId: strId, objAppUrl: objApp.bundleURL, objRunningApp: objApp, blnIsPinned: false))
        }
        if !arrObjRunningItems.isEmpty {
            if !arrObjNewItems.isEmpty {
                arrObjNewItems.append(makeDivider(strId: Self.strRunningDividerId, blnIsAuto: true))
            }
            arrObjNewItems += arrObjRunningItems
        }

        // 3. Minimized windows and the Trash.
        var arrObjTrailing: [DockItem] = []
        if objSettings.blnShowMinimized {
            for objMinimized in objMinimized.arrObjWindows {
                arrObjTrailing.append(makeMinimized(objMinimized))
            }
        }
        if objSettings.blnShowTrash {
            let blnFull = blnTrashWasFull ?? false
            arrObjTrailing.append(DockItem(
                strBundleId: Self.strTrashId,
                enmKind: .trash(blnIsFull: blnFull),
                strName: "Trash",
                objIcon: Self.trashIcon(blnIsFull: blnFull),
                objAppUrl: nil,
                objRunningApp: nil,
                blnIsPinned: false
            ))
        }
        if !arrObjTrailing.isEmpty {
            if !arrObjNewItems.isEmpty {
                arrObjNewItems.append(makeDivider(strId: Self.strTrailingDividerId, blnIsAuto: true))
            }
            arrObjNewItems += arrObjTrailing
        }

        // Pinned flags and group contents matter too: they change sections and icons.
        let blnItemsChanged = signature(of: arrObjNewItems) != signature(of: arrObjItems)
        arrObjItems = arrObjNewItems
        strActiveBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if blnItemsChanged {
            onItemsChanged?()
        }
    }

    /// Summary used to detect layout-relevant changes.
    /// - Parameter arrObjItems: Items.
    /// - Returns: Comparable signature.
    private func signature(of arrObjItems: [DockItem]) -> [String] {
        arrObjItems.map { objItem in
            var strSignature = objItem.strBundleId + (objItem.blnIsPinned ? "|p" : "")
            if case .group(_, let arrObjMembers) = objItem.enmKind {
                strSignature += "|" + arrObjMembers.map(\.strBundleId).joined(separator: ",") + "|" + objItem.strName
            }
            if case .trash(let blnIsFull) = objItem.enmKind {
                strSignature += blnIsFull ? "|full" : "|empty"
            }
            return strSignature
        }
    }

    // MARK: - Item factories

    /// Builds an app item, resolving its display name and (cached) icon.
    /// - Parameters:
    ///   - strBundleId: App bundle identifier.
    ///   - objAppUrl: Location of the `.app` bundle, if known.
    ///   - objRunningApp: Running instance, if any.
    ///   - blnIsPinned: Whether the app is pinned.
    /// - Returns: A ready-to-render dock item.
    private func makeApp(strBundleId: String, objAppUrl: URL?, objRunningApp: NSRunningApplication?, blnIsPinned: Bool) -> DockItem {
        let strName = objRunningApp?.localizedName
            ?? objAppUrl.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? strBundleId

        return DockItem(
            strBundleId: strBundleId,
            enmKind: .app,
            strName: strName,
            objIcon: icon(strBundleId: strBundleId, objAppUrl: objAppUrl, objRunningApp: objRunningApp),
            objAppUrl: objAppUrl,
            objRunningApp: objRunningApp,
            blnIsPinned: blnIsPinned
        )
    }

    /// Builds a divider item.
    /// - Parameters:
    ///   - strId: Token (user dividers) or synthetic ID (automatic ones).
    ///   - blnIsAuto: Whether it's an automatic section divider.
    /// - Returns: Item.
    private func makeDivider(strId: String, blnIsAuto: Bool) -> DockItem {
        DockItem(strBundleId: strId, enmKind: .divider(blnIsAuto: blnIsAuto), strName: "", objIcon: NSImage(),
                 objAppUrl: nil, objRunningApp: nil, blnIsPinned: !blnIsAuto)
    }

    /// Builds a minimized-window tile: the window's last preview, or its app icon.
    /// - Parameter objMinimized: Window and app.
    /// - Returns: Item.
    private func makeMinimized(_ objMinimized: MinimizedWindow) -> DockItem {
        let strAppId = objMinimized.objApp.bundleIdentifier ?? ""
        let objAppIcon = icon(strBundleId: strAppId, objAppUrl: objMinimized.objApp.bundleURL, objRunningApp: objMinimized.objApp)
        let objThumbnail = objMinimized.objWindow.intWindowId.flatMap { fnThumbnail?($0) }
        return DockItem(
            strBundleId: "min:\(objMinimized.objWindow.id)",
            enmKind: .minimized(objWindow: objMinimized.objWindow, objApp: objMinimized.objApp),
            strName: objMinimized.objWindow.strTitle,
            objIcon: MinimizedIconRenderer.icon(objThumbnail: objThumbnail, objAppIcon: objAppIcon),
            objAppUrl: objMinimized.objApp.bundleURL,
            objRunningApp: nil,
            blnIsPinned: false
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

    // MARK: - Trash

    /// The system's empty or full Trash icon.
    /// - Parameter blnIsFull: Which variant.
    /// - Returns: Icon.
    private static func trashIcon(blnIsFull: Bool) -> NSImage {
        let strName = blnIsFull ? "FullTrashIcon.icns" : "TrashIcon.icns"
        return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(strName)")
            ?? NSImage(systemSymbolName: blnIsFull ? "trash.fill" : "trash", accessibilityDescription: "Trash")
            ?? NSImage()
    }

    /// Checks every few seconds whether the Trash has anything in it.
    private func watchTrash() {
        objTrashTask = Task { [weak self] in
            while !Task.isCancelled {
                let objTrashUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                // Unreadable (no Full Disk Access) counts as empty.
                let arrStrContents = (try? FileManager.default.contentsOfDirectory(atPath: objTrashUrl.path)) ?? []
                let blnFull = arrStrContents.contains { $0 != ".DS_Store" && $0 != ".localized" }
                if let self, blnFull != self.blnTrashWasFull {
                    self.blnTrashWasFull = blnFull
                    self.rebuild()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
