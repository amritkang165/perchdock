import AppKit
import CoreServices

/// Recently opened documents for an app, for its right-click menu (like the native
/// Dock's recent items, or Windows jump lists).
///
/// Two sources, best first:
/// 1. macOS's own per-app recent-documents list (exactly what the app's
///    File › Open Recent shows). It lives in a protected folder, so it's only
///    readable when MacDock has Full Disk Access.
/// 2. Otherwise Spotlight: files the app is the default opener for, ordered by
///    when they were last opened.
enum RecentDocumentsService {
    /// Folder holding each app's recent-documents list (`<bundle id>.sfl3` / `.sfl2`).
    private static let objSharedListsUrl = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments")

    /// Content types too broad to mean "this app's documents" (e.g. any file at all).
    private static let setStrBroadTypes: Set<String> = [
        "public.item", "public.data", "public.content", "public.folder", "public.directory",
        "public.composite-content", "com.apple.package", "public.archive", "public.executable",
    ]

    /// Recent documents for an app, newest first.
    /// - Parameters:
    ///   - strBundleId: App's bundle ID.
    ///   - objAppUrl: App bundle (for its declared document types).
    ///   - intLimit: Maximum number of documents.
    /// - Returns: Existing files, newest first.
    static func documents(forBundleId strBundleId: String, objAppUrl: URL?, intLimit: Int = 8) -> [URL] {
        if let arrObjFromList = sharedListDocuments(forBundleId: strBundleId) {
            return Array(arrObjFromList.prefix(intLimit))
        }
        guard let objAppUrl else { return [] }
        return spotlightDocuments(forAppAt: objAppUrl, intLimit: intLimit)
    }

    // MARK: - macOS recent-documents list

    /// Reads the app's recent-documents list.
    /// - Parameter strBundleId: App's bundle ID.
    /// - Returns: Files (newest first), or `nil` if the list isn't readable.
    private static func sharedListDocuments(forBundleId strBundleId: String) -> [URL]? {
        // Newer macOS writes .sfl3; older .sfl2. File names are lowercased bundle IDs.
        let arrObjCandidates = ["sfl3", "sfl2"].flatMap { strExtension in
            [strBundleId, strBundleId.lowercased()].map {
                objSharedListsUrl.appendingPathComponent("\($0).\(strExtension)")
            }
        }
        guard let objData = arrObjCandidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              let objUnarchiver = try? NSKeyedUnarchiver(forReadingFrom: objData) else { return nil }
        // The archive contains private classes; plain decoding still yields dictionaries/arrays.
        objUnarchiver.requiresSecureCoding = false
        guard let dictRoot = objUnarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any],
              let arrDictItems = dictRoot["items"] as? [[String: Any]] else { return nil }

        // Items are stored newest first; each carries a bookmark to the file.
        return arrDictItems.compactMap { dictItem -> URL? in
            guard let objBookmark = dictItem["Bookmark"] as? Data else { return nil }
            var blnStale = false
            guard let objUrl = try? URL(resolvingBookmarkData: objBookmark, options: [.withoutUI, .withoutMounting],
                                        relativeTo: nil, bookmarkDataIsStale: &blnStale),
                  FileManager.default.fileExists(atPath: objUrl.path) else { return nil }
            return objUrl
        }
    }

    // MARK: - Spotlight fallback

    /// Recently opened files that this app opens by default.
    /// - Parameters:
    ///   - objAppUrl: App bundle.
    ///   - intLimit: Maximum number of documents.
    /// - Returns: Files, newest first.
    private static func spotlightDocuments(forAppAt objAppUrl: URL, intLimit: Int) -> [URL] {
        let arrStrTypes = documentTypes(ofAppAt: objAppUrl)
        guard !arrStrTypes.isEmpty else { return [] }

        // Files of those types opened in the last 60 days, anywhere in the home folder.
        let strTypes = arrStrTypes.prefix(40).map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ")
        let strQuery = "(\(strTypes)) && kMDItemLastUsedDate >= $time.today(-60)"
        guard let objQuery = MDQueryCreate(kCFAllocatorDefault, strQuery as CFString,
                                           [kMDItemPath, kMDItemLastUsedDate] as CFArray,
                                           [kMDItemLastUsedDate] as CFArray) else { return [] }
        MDQuerySetSearchScope(objQuery, searchFolders() as CFArray, 0)
        MDQuerySetMaxCount(objQuery, 500)
        guard MDQueryExecute(objQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        // Collect (path, last used), skipping Library folders, hidden files and bundle innards.
        var arrObjFound: [(objUrl: URL, objDate: Date)] = []
        for intIndex in 0..<MDQueryGetResultCount(objQuery) {
            guard let ptrItem = MDQueryGetResultAtIndex(objQuery, intIndex) else { continue }
            let objItem = Unmanaged<MDItem>.fromOpaque(ptrItem).takeUnretainedValue()
            guard let strPath = MDItemCopyAttribute(objItem, kMDItemPath) as? String,
                  let objDate = MDItemCopyAttribute(objItem, kMDItemLastUsedDate) as? Date else { continue }
            let arrStrParts = strPath.split(separator: "/")
            guard !arrStrParts.contains("Library"),
                  !arrStrParts.contains(where: { $0.hasPrefix(".") }),
                  !arrStrParts.dropLast().contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".xcodeproj") }) else { continue }
            arrObjFound.append((URL(fileURLWithPath: strPath), objDate))
        }

        // Newest first, keeping only files this app opens by default (keeps the list relevant).
        let strAppPath = objAppUrl.standardizedFileURL.path
        return arrObjFound
            .sorted { $0.objDate > $1.objDate }
            .lazy
            .map(\.objUrl)
            .filter { NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL.path == strAppPath }
            .prefix(intLimit)
            .map { $0 }
    }

    /// Home-folder subfolders to search: everything visible except `~/Library`.
    ///
    /// `~/Library` holds cloud-synced folders (Google Drive, OneDrive…) whose providers
    /// stamp a "last opened" date on files as they sync, which would drown out what
    /// the user actually opened. Files there still show when macOS's own list is readable.
    /// - Returns: Folder paths.
    private static func searchFolders() -> [String] {
        let objHome = FileManager.default.homeDirectoryForCurrentUser
        let arrObjChildren = (try? FileManager.default.contentsOfDirectory(
            at: objHome, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return arrObjChildren
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "Library" }
            .map(\.path)
    }

    /// Specific content types the app declares it can open.
    /// - Parameter objAppUrl: App bundle.
    /// - Returns: UTIs (broad catch-alls removed).
    private static func documentTypes(ofAppAt objAppUrl: URL) -> [String] {
        guard let arrDictTypes = Bundle(url: objAppUrl)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        var arrStrTypes: [String] = []
        for dictType in arrDictTypes {
            for strType in dictType["LSItemContentTypes"] as? [String] ?? [] where !setStrBroadTypes.contains(strType) {
                if !arrStrTypes.contains(strType) { arrStrTypes.append(strType) }
            }
        }
        return arrStrTypes
    }
}
