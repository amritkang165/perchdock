import AppKit
import ApplicationServices

/// Borrows apps' own Dock menu actions (e.g. Chrome's "New Incognito Window") from
/// the hidden native Dock.
///
/// Apps hand their custom Dock menu only to the system Dock, so this asks the Dock
/// (via Accessibility) to open the app's menu, reads the items, and cancels it. The
/// hidden Dock opens its menus off-screen, so nothing flashes. Choosing an action
/// reopens the menu and presses the matching item.
///
/// Some apps take a quarter second to build their menu, so results are cached per
/// app and refreshed in the background after each use; only the first right-click
/// on an app waits for a live read.
enum NativeDockMenuService {
    /// Last entries read per app (keyed by bundle path), shown instantly next time.
    @MainActor private static var dictArrCache: [String: [Entry]] = [:]
    /// Wait after a menu closes before refreshing (lets a chosen action finish first).
    private static let objRefreshDelay: Duration = .seconds(1)

    /// Items every app gets, which MacDock's own menu already covers.
    private static let setStrStandard: Set<String> = [
        "Options", "Show All Windows", "Hide", "Hide Others", "Show", "Quit", "Force Quit", "Open",
        "Keep in Dock", "Remove from Dock", "Open at Login", "Show in Finder", "Show Recents",
    ]
    /// How long to wait for the Dock to open a menu.
    private static let objOpenTimeout: Duration = .milliseconds(600)

    /// One mirrored line of an app's Dock menu.
    enum Entry: Equatable, Sendable {
        /// Pressable action: title and position in the native menu (a fallback when
        /// the title changed since it was read, e.g. "Pause" became "Play").
        case action(String, intIndex: Int)
        /// Disabled line the app uses as a heading (e.g. "Recently Played").
        case header(String)
        case separator
    }

    /// The app's own entries, from the cache when available (else read live).
    /// - Parameters:
    ///   - objAppUrl: The app's bundle URL (identifies its Dock item).
    ///   - intPid: The running app's process, to skip the Dock's list of its windows.
    ///   - setStrSkip: Titles to leave out (e.g. recent documents already shown).
    /// - Returns: Entries; empty when there's nothing app-specific.
    @MainActor
    static func entries(forAppAt objAppUrl: URL, intPid: pid_t?, setStrSkip: Set<String>) -> [Entry] {
        let strKey = objAppUrl.path
        let arrObjEntries = dictArrCache[strKey] ?? readEntries(forAppAt: objAppUrl, intPid: intPid)
        dictArrCache[strKey] = arrObjEntries
        return arrObjEntries.filter { objEntry in
            if case .action(let strTitle, _) = objEntry { return !setStrSkip.contains(strTitle) }
            return true
        }
    }

    /// Re-reads an app's entries in the background shortly after its menu was used,
    /// so the cache tracks changes (new recent items, play/pause state…).
    /// - Parameters:
    ///   - objAppUrl: The app's bundle URL.
    ///   - intPid: The running app's process, if any.
    @MainActor
    static func refreshSoon(forAppAt objAppUrl: URL, intPid: pid_t?) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: objRefreshDelay)
            let arrObjEntries = readEntries(forAppAt: objAppUrl, intPid: intPid)
            await MainActor.run { dictArrCache[objAppUrl.path] = arrObjEntries }
        }
    }

    /// Reads the app's own entries live from its native Dock menu.
    /// - Parameters:
    ///   - objAppUrl: The app's bundle URL.
    ///   - intPid: The running app's process, to skip the Dock's list of its windows.
    /// - Returns: Entries in menu order.
    private static func readEntries(forAppAt objAppUrl: URL, intPid: pid_t?) -> [Entry] {
        guard let objItem = dockItem(forAppAt: objAppUrl), let objMenu = openMenu(on: objItem) else { return [] }
        defer { AXUIElementPerformAction(objMenu, kAXCancelAction as CFString) }
        let arrStrWindowNames = intPid.map(windowNames(ofPid:)) ?? []

        // Split into the menu's separator-delimited sections.
        var arrArrSections: [[(strTitle: String, intIndex: Int, blnEnabled: Bool, blnHasSubmenu: Bool)]] = [[]]
        for (intIndex, objMenuItem) in children(of: objMenu).enumerated() {
            let strTitle: String = attribute(objMenuItem, kAXTitleAttribute) ?? ""
            if strTitle.isEmpty {
                arrArrSections.append([])
                continue
            }
            let blnEnabled: Bool = attribute(objMenuItem, kAXEnabledAttribute) ?? false
            arrArrSections[arrArrSections.count - 1].append((strTitle, intIndex, blnEnabled, !children(of: objMenuItem).isEmpty))
        }

        var arrObjResult: [Entry] = []
        for arrSection in arrArrSections where !arrSection.isEmpty {
            // The Dock lists the app's windows as one section; MacDock shows its own.
            if arrSection.contains(where: { objEntry in arrStrWindowNames.contains { matches(objEntry.strTitle, strWindowTitle: $0) } }) {
                continue
            }
            let arrObjEntries: [Entry] = arrSection.compactMap { objEntry in
                // Submenus (e.g. "Options") can't be mirrored as a single press.
                guard !objEntry.blnHasSubmenu, !setStrStandard.contains(objEntry.strTitle) else { return nil }
                return objEntry.blnEnabled ? .action(objEntry.strTitle, intIndex: objEntry.intIndex) : .header(objEntry.strTitle)
            }
            // A section of only headings has nothing to do.
            guard arrObjEntries.contains(where: { if case .action = $0 { true } else { false } }) else { continue }
            if !arrObjResult.isEmpty { arrObjResult.append(.separator) }
            arrObjResult.append(contentsOf: arrObjEntries)
        }
        return arrObjResult
    }

    /// Names of an app's windows on every desktop, from the window server.
    /// - Parameter intPid: App process.
    /// - Returns: Non-empty window names.
    private static func windowNames(ofPid intPid: pid_t) -> [String] {
        let arrDictWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return arrDictWindows.compactMap { dictWindow in
            guard (dictWindow[kCGWindowOwnerPID as String] as? pid_t) == intPid,
                  let strName = dictWindow[kCGWindowName as String] as? String, !strName.isEmpty else { return nil }
            return strName
        }
    }

    /// Reopens the app's native Dock menu and presses an item: by title, else (when
    /// the title changed since it was cached) whatever enabled item is now at its position.
    /// - Parameters:
    ///   - strTitle: Item title, from an `.action` entry.
    ///   - intIndex: Its position in the native menu.
    ///   - objAppUrl: The app's bundle URL.
    static func perform(_ strTitle: String, intIndex: Int, forAppAt objAppUrl: URL) {
        guard let objItem = dockItem(forAppAt: objAppUrl), let objMenu = openMenu(on: objItem) else { return }
        let arrObjItems = children(of: objMenu)
        let objByTitle = arrObjItems.first { (attribute($0, kAXTitleAttribute) as String?) == strTitle }
        let objByIndex = arrObjItems[safe: intIndex].flatMap { objCandidate -> AXUIElement? in
            let strNow: String = attribute(objCandidate, kAXTitleAttribute) ?? ""
            let blnEnabled: Bool = attribute(objCandidate, kAXEnabledAttribute) ?? false
            return !strNow.isEmpty && blnEnabled && children(of: objCandidate).isEmpty ? objCandidate : nil
        }
        if let objTarget = objByTitle ?? objByIndex {
            AXUIElementPerformAction(objTarget, kAXPressAction as CFString)
        } else {
            AXUIElementPerformAction(objMenu, kAXCancelAction as CFString)
        }
    }

    // MARK: - Dock access

    /// The native Dock's item for an app, matched by bundle URL.
    /// - Parameter objAppUrl: App bundle URL.
    /// - Returns: The `AXDockItem`, if the app is in the Dock (pinned or running).
    private static func dockItem(forAppAt objAppUrl: URL) -> AXUIElement? {
        guard let objDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let objAxDock = AXUIElementCreateApplication(objDock.processIdentifier)
        AXUIElementSetMessagingTimeout(objAxDock, 0.3)
        let strWanted = objAppUrl.standardizedFileURL.resolvingSymlinksInPath().path
        for objList in children(of: objAxDock) {
            for objItem in children(of: objList) {
                guard let objUrl: URL = attribute(objItem, kAXURLAttribute) else { continue }
                if objUrl.standardizedFileURL.resolvingSymlinksInPath().path == strWanted { return objItem }
            }
        }
        return nil
    }

    /// Asks the Dock to open an item's menu and waits for it to appear.
    /// - Parameter objItem: Dock item.
    /// - Returns: The open `AXMenu`, or `nil` if it didn't open in time.
    private static func openMenu(on objItem: AXUIElement) -> AXUIElement? {
        guard AXUIElementPerformAction(objItem, "AXShowMenu" as CFString) == .success else { return nil }
        let objDeadline = ContinuousClock.now + objOpenTimeout
        // A brief synchronous poll: the menu is built by the Dock process, not us.
        while ContinuousClock.now < objDeadline {
            if let objMenu = children(of: objItem).first(where: { (attribute($0, kAXRoleAttribute) as String?) == kAXMenuRole as String }) {
                return objMenu
            }
            usleep(15_000)
        }
        return nil
    }

    /// Whether a (possibly middle-truncated, "Start…End") menu title names a window.
    /// Window titles may carry extra text the Dock drops (e.g. " - Google Chrome").
    /// - Parameters:
    ///   - strMenuTitle: Title from the Dock menu.
    ///   - strWindowTitle: A window's full title.
    /// - Returns: `true` on an exact, prefix or truncated match.
    private static func matches(_ strMenuTitle: String, strWindowTitle: String) -> Bool {
        guard !strWindowTitle.isEmpty else { return false }
        if strMenuTitle == strWindowTitle { return true }
        let arrStrParts = strMenuTitle.components(separatedBy: "…")
        if arrStrParts.count == 2, !arrStrParts[0].isEmpty {
            return strWindowTitle.hasPrefix(arrStrParts[0]) && strWindowTitle.contains(arrStrParts[1])
        }
        // Long enough to be distinctive: the window title starts with the menu title.
        return strMenuTitle.count >= 8 && strWindowTitle.hasPrefix(strMenuTitle)
    }

    // MARK: - AX helpers

    /// An element's children.
    /// - Parameter objElement: Element.
    /// - Returns: Children (empty if none or unreadable).
    private static func children(of objElement: AXUIElement) -> [AXUIElement] {
        attribute(objElement, kAXChildrenAttribute) ?? []
    }

    /// Reads a typed AX attribute.
    /// - Parameters:
    ///   - objElement: Element.
    ///   - strAttribute: Attribute name.
    /// - Returns: Value cast to `T`, or `nil`.
    private static func attribute<T>(_ objElement: AXUIElement, _ strAttribute: String) -> T? {
        var objValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, strAttribute as CFString, &objValue) == .success else { return nil }
        return objValue as? T
    }
}
