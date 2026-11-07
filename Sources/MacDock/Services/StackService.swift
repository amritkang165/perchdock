import AppKit

/// Folder stacks and the Trash.
@MainActor
enum StackService {
    /// Most files a stack popover shows (newest first).
    static let intMaxStackEntries = 20

    /// The user's Trash folder.
    static var objTrashUrl: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// Newest items in a folder, by date added (falling back to modification date).
    /// - Parameter objFolder: Folder.
    /// - Returns: Up to `intMaxStackEntries` file URLs, newest first.
    static func newestEntries(in objFolder: URL) -> [URL] {
        let arrObjKeys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let arrObjUrls = (try? FileManager.default.contentsOfDirectory(
            at: objFolder,
            includingPropertiesForKeys: arrObjKeys,
            options: [.skipsHiddenFiles]
        )) ?? []

        /// Date used for sorting.
        func date(_ objUrl: URL) -> Date {
            let objValues = try? objUrl.resourceValues(forKeys: Set(arrObjKeys))
            return objValues?.addedToDirectoryDate ?? objValues?.contentModificationDate ?? .distantPast
        }

        return arrObjUrls
            .map { ($0, date($0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(intMaxStackEntries)
            .map(\.0)
    }

    /// Grid tiles for a folder's newest items.
    /// - Parameter objFolder: Folder.
    /// - Returns: Tiles with file icons and names.
    static func entries(in objFolder: URL) -> [GridEntry] {
        newestEntries(in: objFolder).map { objUrl in
            GridEntry(
                id: objUrl.path,
                strName: FileManager.default.displayName(atPath: objUrl.path),
                objIcon: NSWorkspace.shared.icon(forFile: objUrl.path),
                objFileUrl: objUrl
            )
        }
    }

    /// Moves files into a folder (used when dropping onto a stack).
    /// - Parameters:
    ///   - arrObjUrls: Files.
    ///   - objFolder: Destination.
    /// - Returns: Whether at least one moved.
    @discardableResult
    static func move(_ arrObjUrls: [URL], into objFolder: URL) -> Bool {
        var blnMovedAny = false
        for objUrl in arrObjUrls where objUrl.deletingLastPathComponent().standardizedFileURL != objFolder.standardizedFileURL {
            let objDestination = objFolder.appendingPathComponent(objUrl.lastPathComponent)
            if (try? FileManager.default.moveItem(at: objUrl, to: objDestination)) != nil {
                blnMovedAny = true
            }
        }
        return blnMovedAny
    }

    /// Moves files to the Trash.
    /// - Parameter arrObjUrls: Files.
    /// - Returns: Whether at least one was trashed.
    @discardableResult
    static func trash(_ arrObjUrls: [URL]) -> Bool {
        var blnTrashedAny = false
        for objUrl in arrObjUrls where (try? FileManager.default.trashItem(at: objUrl, resultingItemURL: nil)) != nil {
            blnTrashedAny = true
        }
        if blnTrashedAny {
            NSSound(named: "Purr")?.play()
        }
        return blnTrashedAny
    }

    /// Opens the Trash in Finder.
    static func openTrash() {
        NSWorkspace.shared.open(objTrashUrl)
    }

    /// Empties the Trash through Finder (asks for confirmation like Finder does,
    /// and needs one-time permission to control Finder).
    static func emptyTrash() {
        NSApp.activate()
        let objAlert = NSAlert()
        objAlert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        objAlert.informativeText = "You can’t undo this action."
        objAlert.addButton(withTitle: "Empty Trash")
        objAlert.addButton(withTitle: "Cancel")
        guard objAlert.runModal() == .alertFirstButtonReturn else { return }

        var objError: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&objError)
        if objError != nil {
            // Usually: Finder automation was declined. Point the user at the setting.
            let objFail = NSAlert()
            objFail.messageText = "Couldn’t empty the Trash"
            objFail.informativeText = "Allow MacDock to control Finder in System Settings → Privacy & Security → Automation."
            objFail.runModal()
        }
    }
}
