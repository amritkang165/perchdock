import Foundation

/// Carries settings over from the app's previous name (MacDock, `com.slynck.macdock`)
/// so renaming doesn't reset the user's dock: pinned apps, groups, position, glass,
/// and the saved native Dock snapshot that restores the user's original Dock on quit.
enum LegacyDefaultsMigration {
    /// The defaults domain used before the rename.
    static let strLegacyDomain = "com.slynck.macdock"
    /// Set once the migration has run, so later launches skip it.
    static let strDoneKey = "MigratedFromMacDock"

    /// Copies every MacDock setting the app doesn't already have.
    /// Runs once; must be called before anything reads the app's settings.
    /// - Parameter objDefaults: Where the app's settings live.
    static func run(objDefaults: UserDefaults = .standard) {
        let strDomain = Bundle.main.bundleIdentifier ?? "com.slynck.perchdock"
        // Not sandboxed, so another app's domain can be read directly by name.
        migrate(objDefaults: objDefaults, strDomain: strDomain,
                dictLegacy: objDefaults.persistentDomain(forName: strLegacyDomain))
    }

    /// Copies the given old settings into the app's settings, once.
    /// - Parameters:
    ///   - objDefaults: Where the app's settings live.
    ///   - strDomain: The defaults domain `objDefaults` saves into.
    ///   - dictLegacy: The old app's settings, or `nil` if it was never installed.
    static func migrate(objDefaults: UserDefaults, strDomain: String, dictLegacy: [String: Any]?) {
        guard !objDefaults.bool(forKey: strDoneKey) else { return }
        // Only values actually saved count as "already set": `object(forKey:)` would
        // also see registered defaults, which would block every key from copying.
        let dictSaved = objDefaults.persistentDomain(forName: strDomain) ?? [:]
        // Keep anything already set under the new name; only fill in gaps.
        for (strKey, objValue) in dictLegacy ?? [:] where dictSaved[strKey] == nil {
            objDefaults.set(objValue, forKey: strKey)
        }
        objDefaults.set(true, forKey: strDoneKey)
    }
}
