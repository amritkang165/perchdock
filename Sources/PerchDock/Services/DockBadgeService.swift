import AppKit
import ApplicationServices
import Observation
import os

/// Reads notification badges (unread counts) and icon progress bars from the system Dock.
///
/// The native Dock keeps running while hidden, and its items expose their badge
/// text through Accessibility (`AXStatusLabel`), so the same counts you'd see on
/// Slack or Mail show up here without any per-app integration.
@MainActor
@Observable
final class DockBadgeService {
    /// How often badges are refreshed.
    private static let objPollInterval: Duration = .seconds(2)

    /// Badge text per bundle ID (e.g. "3", "•").
    private(set) var dictStrBadges: [String: String] = [:]

    /// Progress (0…1) the app shows on its Dock icon, e.g. a download.
    private(set) var dictFltProgress: [String: Double] = [:]

    /// Bumped when an app asks for attention (a badge appears or its count rises);
    /// the dock bounces the icon once per bump.
    private(set) var dictIntAttention: [String: Int] = [:]

    @ObservationIgnored private var objPollTask: Task<Void, Never>?
    @ObservationIgnored private var blnHasBaseline = false

    /// Starts polling the system Dock.
    func start() {
        guard objPollTask == nil else { return }
        objPollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.objPollInterval)
            }
        }
    }

    /// Re-reads every Dock item's badge and publishes changes.
    private func poll() {
        guard AXIsProcessTrusted() else { return }
        var dictStrNew: [String: String] = [:]
        var dictFltNewProgress: [String: Double] = [:]
        for objItem in dockItems() {
            guard let objUrl: URL = attribute(objItem, kAXURLAttribute),
                  let strBundleId = Bundle(url: objUrl)?.bundleIdentifier else { continue }
            if let strLabel: String = attribute(objItem, "AXStatusLabel"), !strLabel.isEmpty {
                dictStrNew[strBundleId] = strLabel
            }
            if let objProgress: NSNumber = attribute(objItem, "AXProgressValue") {
                dictFltNewProgress[strBundleId] = min(max(objProgress.doubleValue, 0), 1)
            }
        }

        // Attention: a badge that appeared or grew since the last poll (not at launch).
        if blnHasBaseline {
            for (strBundleId, strLabel) in dictStrNew where isIncrease(from: dictStrBadges[strBundleId], to: strLabel) {
                dictIntAttention[strBundleId, default: 0] += 1
            }
        }
        blnHasBaseline = true

        if dictStrNew != dictStrBadges {
            dictStrBadges = dictStrNew
        }
        if dictFltNewProgress != dictFltProgress {
            dictFltProgress = dictFltNewProgress
        }
    }

    /// Whether a badge change means "new activity".
    /// - Parameters:
    ///   - strOld: Previous badge text, if any.
    ///   - strNew: Current badge text.
    /// - Returns: `true` when a badge appeared or its number went up.
    private func isIncrease(from strOld: String?, to strNew: String) -> Bool {
        guard let strOld else { return true }
        guard let intOld = Int(strOld), let intNew = Int(strNew) else { return strOld != strNew }
        return intNew > intOld
    }

    /// The system Dock's item elements.
    /// - Returns: `AXDockItem` elements (apps, folders, trash).
    private func dockItems() -> [AXUIElement] {
        guard let objDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let objAxDock = AXUIElementCreateApplication(objDock.processIdentifier)
        AXUIElementSetMessagingTimeout(objAxDock, 0.3)
        let arrObjLists: [AXUIElement] = attribute(objAxDock, kAXChildrenAttribute) ?? []
        return arrObjLists.flatMap { objList -> [AXUIElement] in
            attribute(objList, kAXChildrenAttribute) ?? []
        }
    }

    /// Debug: shows a sample badge and progress bar, and bounces the badged app.
    /// - Parameters:
    ///   - strBadgeId: App to badge.
    ///   - strProgressId: App to show progress on.
    func debugFake(strBadgeId: String, strProgressId: String) {
        objPollTask?.cancel()
        dictStrBadges = [strBadgeId: "3"]
        dictFltProgress = [strProgressId: 0.6]
        dictIntAttention[strBadgeId, default: 0] += 1
    }

    /// Debug: logs every Dock item's attributes, to discover what the Dock exposes.
    /// - Parameter objLogger: Destination.
    func debugDump(objLogger: Logger) {
        for objItem in dockItems().prefix(40) {
            var objNames: CFArray?
            AXUIElementCopyAttributeNames(objItem, &objNames)
            let arrStrNames = (objNames as? [String]) ?? []
            let strTitle: String = attribute(objItem, kAXTitleAttribute) ?? "?"
            let arrStrPairs = arrStrNames.map { strName -> String in
                var objValue: CFTypeRef?
                AXUIElementCopyAttributeValue(objItem, strName as CFString, &objValue)
                let strValue = (objValue.map { "\($0)" } ?? "nil").replacingOccurrences(of: "\n", with: " ")
                return "\(strName)=\(strValue.prefix(40))"
            }
            objLogger.notice("dock item \(strTitle, privacy: .public): \(arrStrPairs.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Reads a typed AX attribute.
    /// - Parameters:
    ///   - objElement: Element.
    ///   - strAttribute: Attribute name.
    /// - Returns: Value cast to `T`, or `nil`.
    private func attribute<T>(_ objElement: AXUIElement, _ strAttribute: String) -> T? {
        var objValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(objElement, strAttribute as CFString, &objValue) == .success else { return nil }
        return objValue as? T
    }
}
