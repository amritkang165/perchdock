import AppKit
import ApplicationServices

/// Helpers for the Accessibility (AX) permission MacDock needs to list and raise windows.
@MainActor
enum AccessibilityPermission {
    /// Whether MacDock is currently trusted for Accessibility.
    static var blnIsTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt if MacDock isn't trusted yet.
    /// The string key mirrors `kAXTrustedCheckOptionPrompt`, whose global var
    /// isn't safe to touch under Swift 6 strict concurrency.
    static func requestIfNeeded() {
        guard !blnIsTrusted else { return }
        let dictOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(dictOptions)
    }

    /// Opens System Settings at Privacy & Security → Accessibility.
    static func openSystemSettings() {
        let strUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let objUrl = URL(string: strUrl) {
            NSWorkspace.shared.open(objUrl)
        }
    }
}
