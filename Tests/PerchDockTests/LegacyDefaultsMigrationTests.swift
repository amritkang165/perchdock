import Foundation
import Testing
@testable import PerchDock

/// Settings carried over from the app's old name. Each test uses its own throwaway
/// defaults domain, so the tests never touch real settings.
@Suite("Settings migration from MacDock")
struct LegacyDefaultsMigrationTests {
    /// Name of this test's throwaway domain.
    private let strSuite = "com.slynck.perchdock.tests.\(UUID().uuidString)"
    /// The "new" app's settings for this test.
    private let objDefaults: UserDefaults

    /// Creates this test's throwaway defaults domain.
    init() {
        objDefaults = UserDefaults(suiteName: strSuite)!
    }

    /// Runs the migration against this test's domain.
    /// - Parameter dictLegacy: The old app's settings, or `nil` if it was never installed.
    private func migrate(_ dictLegacy: [String: Any]?) {
        LegacyDefaultsMigration.migrate(objDefaults: objDefaults, strDomain: strSuite, dictLegacy: dictLegacy)
    }

    /// The values actually saved in this test's domain. Registered defaults from the
    /// test host are visible through `objDefaults`, so read the saved domain instead.
    /// - Returns: The saved key/value pairs.
    private func dictSaved() -> [String: Any] {
        objDefaults.persistentDomain(forName: strSuite) ?? [:]
    }

    /// Deletes this test's domain.
    private func cleanUp() {
        objDefaults.removePersistentDomain(forName: strSuite)
    }

    /// Every old setting lands in an empty new domain.
    @Test("Copies every old setting into an empty new domain")
    func copiesMissingKeys() {
        defer { cleanUp() }
        migrate(["Position": "left", "Transparency": 0.5, "PinnedBundleIds": ["com.apple.finder"]])

        #expect(objDefaults.string(forKey: "Position") == "left")
        #expect(objDefaults.double(forKey: "Transparency") == 0.5)
        #expect(objDefaults.stringArray(forKey: "PinnedBundleIds") == ["com.apple.finder"])
        #expect(objDefaults.bool(forKey: LegacyDefaultsMigration.strDoneKey))
    }

    /// A value the user already saved under the new name wins.
    @Test("Never overwrites a setting the new app already has")
    func keepsExistingValues() {
        defer { cleanUp() }
        objDefaults.set("bottom", forKey: "Position")

        migrate(["Position": "left"])

        #expect(objDefaults.string(forKey: "Position") == "bottom")
    }

    /// The second run is a no-op.
    @Test("Runs only once, so later changes to the old app are ignored")
    func runsOnce() {
        defer { cleanUp() }
        migrate([:])
        migrate(["Position": "right"])

        #expect(dictSaved()["Position"] == nil)
    }

    /// No old domain still marks the migration done.
    @Test("With no old app, it just marks itself done")
    func noLegacyDomain() {
        defer { cleanUp() }
        migrate(nil)

        #expect(objDefaults.bool(forKey: LegacyDefaultsMigration.strDoneKey))
        #expect(dictSaved()["Position"] == nil)
    }
}
