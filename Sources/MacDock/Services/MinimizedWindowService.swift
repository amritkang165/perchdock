import AppKit
import ApplicationServices

/// A minimized window and the app it belongs to.
struct MinimizedWindow {
    let objWindow: WindowInfo
    let objApp: NSRunningApplication
}

/// Keeps a list of every minimized window, for the dock's minimized tiles.
///
/// Polls each regular app's AX window list (short timeouts so a hung app can't
/// stall the dock) and reports when the set of minimized windows changes.
@MainActor
final class MinimizedWindowService {
    /// How often windows are re-checked.
    private static let objPollInterval: Duration = .seconds(2)

    /// Minimized windows, oldest first.
    private(set) var arrObjWindows: [MinimizedWindow] = []

    /// Fired when the list changes.
    var onChange: (() -> Void)?

    private var objPollTask: Task<Void, Never>?

    /// Starts polling.
    func start() {
        guard objPollTask == nil else { return }
        objPollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.objPollInterval)
            }
        }
    }

    /// Re-reads minimized windows and publishes changes (keeping existing order).
    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let strOwnId = Bundle.main.bundleIdentifier
        var arrObjFound: [MinimizedWindow] = []

        for objApp in NSWorkspace.shared.runningApplications where objApp.activationPolicy == .regular && objApp.bundleIdentifier != strOwnId {
            let objAxApp = AXUIElementCreateApplication(objApp.processIdentifier)
            AXUIElementSetMessagingTimeout(objAxApp, 0.15)
            var objValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(objAxApp, kAXWindowsAttribute as CFString, &objValue) == .success,
                  let arrObjElements = objValue as? [AXUIElement] else { continue }

            for objElement in arrObjElements {
                var objMinimized: CFTypeRef?
                guard AXUIElementCopyAttributeValue(objElement, kAXMinimizedAttribute as CFString, &objMinimized) == .success,
                      (objMinimized as? Bool) == true,
                      let intWindowId = PrivateWindowAPI.windowId(for: objElement) else { continue }
                var objTitle: CFTypeRef?
                AXUIElementCopyAttributeValue(objElement, kAXTitleAttribute as CFString, &objTitle)
                let strTitle = (objTitle as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (objApp.localizedName ?? "Window")
                arrObjFound.append(MinimizedWindow(
                    objWindow: WindowInfo(
                        id: Int(intWindowId),
                        strTitle: strTitle,
                        blnIsMinimized: true,
                        blnIsOnOtherSpace: false,
                        intWindowId: intWindowId,
                        objElement: objElement
                    ),
                    objApp: objApp
                ))
            }
        }

        // Keep tiles in the order windows were minimized: existing ones first.
        let arrIntOldIds = arrObjWindows.map(\.objWindow.id)
        let arrObjSorted = arrObjFound.sorted { objA, objB in
            (arrIntOldIds.firstIndex(of: objA.objWindow.id) ?? Int.max) < (arrIntOldIds.firstIndex(of: objB.objWindow.id) ?? Int.max)
        }
        if arrObjSorted.map(\.objWindow.id) != arrIntOldIds {
            arrObjWindows = arrObjSorted
            onChange?()
        }
    }
}
