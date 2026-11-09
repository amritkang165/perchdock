import Foundation

/// Carries settings over from the app's previous name (MacDock, `com.slynck.macdock`)
/// so renaming doesn't reset the user's dock: pinned apps, groups, position, glass,
/// and the saved native Dock snapshot that restores the user's original Dock on quit.
enum LegacyDefaultsMigration {
    /// The defaults domain used before the rename.
    private static let strLegacyDomain = "com.slynck.macdock"
    /// Set once the migration has run, so later launches skip it.
    private static let strDoneKey = "MigratedFromMacDock"

    /// Copies every legacy key the current domain doesn't already have.
    /// Runs once; must be called before anything reads `UserDefaults.standard`.
    static func run() {
        let objDefaults = UserDefaults.standard
        guard !objDefaults.bool(forKey: strDoneKey) else { return }

        // Not sandboxed, so another app's domain can be read directly by name.
        if let dictLegacy = objDefaults.persistentDomain(forName: strLegacyDomain) {
            // Keep anything already set under the new name; only fill in gaps.
            for (strKey, objValue) in dictLegacy where objDefaults.object(forKey: strKey) == nil {
                objDefaults.set(objValue, forKey: strKey)
            }
        }
        objDefaults.set(true, forKey: strDoneKey)
    }
}
