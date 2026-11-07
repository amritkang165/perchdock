import Foundation

/// Hides and restores the native macOS Dock.
///
/// The Dock process can't be stopped (launchd relaunches it, and it also runs
/// Mission Control, Spaces and Cmd-Tab), so we use the same trick as other dock
/// apps: auto-hide with a huge reveal delay. The user's original values are
/// snapshotted first so `restore()` puts back exactly what they had.
///
/// A hidden Dock still bounces icons (on launch and for attention), and the bounce
/// pokes up above the screen edge, so bouncing is turned off while it's hidden too.
/// MacDock does its own launch and attention bounces.
@MainActor
final class NativeDockController {
    /// The user's native Dock values captured before we changed them.
    /// `nil` fields mean the key was unset (macOS default).
    private struct Snapshot: Codable {
        let blnAutohide: Bool?
        let fltAutohideDelay: Double?
        let fltAutohideTimeModifier: Double?
        let blnLaunchAnim: Bool?
        let blnNoBouncing: Bool?
        /// Whether the bounce keys were captured (snapshots from older versions lack them).
        var blnHasBounceKeys: Bool? = true
    }

    private static let strDockDomain = "com.apple.dock"
    private static let strSnapshotKey = "NativeDockSnapshot"
    private static let fltHiddenDelay: Double = 1000

    /// Background shell that restores the Dock if MacDock dies without quitting cleanly.
    private var objWatchdog: Process?

    /// True when we've hidden the Dock and still hold the user's original values.
    var blnIsHiddenByUs: Bool {
        UserDefaults.standard.data(forKey: Self.strSnapshotKey) != nil
    }

    /// Hides the native Dock, snapshotting the user's values on first use.
    func hide() {
        // Only snapshot once, so a re-hide never overwrites the true originals.
        let objCurrent = readCurrentValues()
        if let objSnapshot = loadSnapshot() {
            // Snapshot from an older version: add the bounce keys while they're still the user's.
            if objSnapshot.blnHasBounceKeys != true {
                saveSnapshot(Snapshot(blnAutohide: objSnapshot.blnAutohide,
                                      fltAutohideDelay: objSnapshot.fltAutohideDelay,
                                      fltAutohideTimeModifier: objSnapshot.fltAutohideTimeModifier,
                                      blnLaunchAnim: objCurrent.blnLaunchAnim,
                                      blnNoBouncing: objCurrent.blnNoBouncing))
            }
        } else {
            saveSnapshot(objCurrent)
        }

        startWatchdog()

        // Skip the Dock restart if it's already in the hidden state.
        let blnAlreadyHidden = objCurrent.blnAutohide == true
            && objCurrent.fltAutohideDelay == Self.fltHiddenDelay
            && objCurrent.blnLaunchAnim == false
            && objCurrent.blnNoBouncing == true
        guard !blnAlreadyHidden else { return }

        writeDefault("autohide", arrStrValue: ["-bool", "true"])
        writeDefault("autohide-delay", arrStrValue: ["-float", String(Self.fltHiddenDelay)])
        writeDefault("autohide-time-modifier", arrStrValue: ["-float", "0"])
        // No bouncing icons poking up from the hidden Dock.
        writeDefault("launchanim", arrStrValue: ["-bool", "false"])
        writeDefault("no-bouncing", arrStrValue: ["-bool", "true"])
        restartDock()
    }

    /// Restores the user's original native Dock values and forgets the snapshot.
    func restore() {
        stopWatchdog()
        guard let objSnapshot = loadSnapshot() else { return }

        applyOriginal("autohide", objValue: objSnapshot.blnAutohide.map { ["-bool", $0 ? "true" : "false"] })
        applyOriginal("autohide-delay", objValue: objSnapshot.fltAutohideDelay.map { ["-float", String($0)] })
        applyOriginal("autohide-time-modifier", objValue: objSnapshot.fltAutohideTimeModifier.map { ["-float", String($0)] })
        applyOriginal("launchanim", objValue: objSnapshot.blnLaunchAnim.map { ["-bool", $0 ? "true" : "false"] })
        applyOriginal("no-bouncing", objValue: objSnapshot.blnNoBouncing.map { ["-bool", $0 ? "true" : "false"] })

        UserDefaults.standard.removeObject(forKey: Self.strSnapshotKey)
        restartDock()
    }

    // MARK: - Crash safety

    /// Starts a detached shell that waits for MacDock to exit and, if the Dock is
    /// still hidden by us (a crash or force quit skipped `restore()`), puts the
    /// user's original values back so they're never left without a dock.
    ///
    /// The shell outlives MacDock (it's reparented to launchd) and does nothing
    /// after a clean quit, because `restore()` stops it and clears the snapshot.
    private func startWatchdog() {
        guard objWatchdog?.isRunning != true, let objSnapshot = loadSnapshot() else { return }
        let strDomain = Self.strDockDomain
        let strOwnDomain = Bundle.main.bundleIdentifier ?? "com.slynck.macdock"

        /// `defaults` command restoring one key (or deleting it if it was unset).
        func restoreCommand(_ strKey: String, _ strTypedValue: String?) -> String {
            strTypedValue.map { "/usr/bin/defaults write \(strDomain) \(strKey) \($0)" }
                ?? "/usr/bin/defaults delete \(strDomain) \(strKey) 2>/dev/null"
        }
        let arrStrRestore = [
            restoreCommand("autohide", objSnapshot.blnAutohide.map { "-bool \($0)" }),
            restoreCommand("autohide-delay", objSnapshot.fltAutohideDelay.map { "-float \($0)" }),
            restoreCommand("autohide-time-modifier", objSnapshot.fltAutohideTimeModifier.map { "-float \($0)" }),
            restoreCommand("launchanim", objSnapshot.blnLaunchAnim.map { "-bool \($0)" }),
            restoreCommand("no-bouncing", objSnapshot.blnNoBouncing.map { "-bool \($0)" }),
        ]

        // Poll our PID; once it's gone, restore only if the snapshot is still there.
        let strScript = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 2; done
        if /usr/bin/defaults read \(strOwnDomain) \(Self.strSnapshotKey) >/dev/null 2>&1; then
          \(arrStrRestore.joined(separator: "\n  "))
          /usr/bin/defaults delete \(strOwnDomain) \(Self.strSnapshotKey)
          /usr/bin/killall Dock
        fi
        """
        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        objProcess.arguments = ["-c", strScript]
        objProcess.standardOutput = FileHandle.nullDevice
        objProcess.standardError = FileHandle.nullDevice
        do {
            try objProcess.run()
            objWatchdog = objProcess
        } catch {
            NSLog("MacDock: couldn't start the Dock watchdog: \(error)")
        }
    }

    /// Stops the watchdog (the Dock is being restored normally).
    private func stopWatchdog() {
        if objWatchdog?.isRunning == true { objWatchdog?.terminate() }
        objWatchdog = nil
    }

    // MARK: - Preferences I/O

    /// Reads the Dock's current auto-hide values straight from its preferences domain.
    /// - Returns: A snapshot of the live values.
    private func readCurrentValues() -> Snapshot {
        let strDomain = Self.strDockDomain as CFString
        CFPreferencesAppSynchronize(strDomain)

        /// Reads one key from the Dock domain as an `NSNumber`, if set.
        func number(_ strKey: String) -> NSNumber? {
            CFPreferencesCopyAppValue(strKey as CFString, strDomain) as? NSNumber
        }

        return Snapshot(
            blnAutohide: number("autohide")?.boolValue,
            fltAutohideDelay: number("autohide-delay")?.doubleValue,
            fltAutohideTimeModifier: number("autohide-time-modifier")?.doubleValue,
            blnLaunchAnim: number("launchanim")?.boolValue,
            blnNoBouncing: number("no-bouncing")?.boolValue
        )
    }

    /// Writes a single key back to its original value, or deletes it if it was unset.
    /// - Parameters:
    ///   - strKey: Dock preference key.
    ///   - objValue: `defaults` type flag and value, or `nil` to delete the key.
    private func applyOriginal(_ strKey: String, objValue: [String]?) {
        if let arrStrValue = objValue {
            writeDefault(strKey, arrStrValue: arrStrValue)
        } else {
            runTool("/usr/bin/defaults", arrStrArgs: ["delete", Self.strDockDomain, strKey])
        }
    }

    /// Writes a Dock preference via `defaults`, which reliably notifies cfprefsd.
    /// - Parameters:
    ///   - strKey: Dock preference key.
    ///   - arrStrValue: Type flag and value, e.g. `["-bool", "true"]`.
    private func writeDefault(_ strKey: String, arrStrValue: [String]) {
        runTool("/usr/bin/defaults", arrStrArgs: ["write", Self.strDockDomain, strKey] + arrStrValue)
    }

    /// Restarts the Dock so it picks up new preferences (launchd relaunches it instantly).
    private func restartDock() {
        runTool("/usr/bin/killall", arrStrArgs: ["Dock"])
    }

    /// Runs a command-line tool synchronously, ignoring failures.
    /// - Parameters:
    ///   - strPath: Absolute path of the executable.
    ///   - arrStrArgs: Arguments to pass.
    private func runTool(_ strPath: String, arrStrArgs: [String]) {
        let objProcess = Process()
        objProcess.executableURL = URL(fileURLWithPath: strPath)
        objProcess.arguments = arrStrArgs
        objProcess.standardOutput = FileHandle.nullDevice
        objProcess.standardError = FileHandle.nullDevice
        do {
            try objProcess.run()
            objProcess.waitUntilExit()
        } catch {
            NSLog("MacDock: failed to run \(strPath): \(error)")
        }
    }

    // MARK: - Snapshot persistence

    /// Persists the user's original Dock values in MacDock's own defaults.
    /// - Parameter objSnapshot: Values to remember.
    private func saveSnapshot(_ objSnapshot: Snapshot) {
        if let objData = try? JSONEncoder().encode(objSnapshot) {
            UserDefaults.standard.set(objData, forKey: Self.strSnapshotKey)
        }
    }

    /// Loads the saved original Dock values, if any.
    /// - Returns: The snapshot, or `nil` if we never hid the Dock.
    private func loadSnapshot() -> Snapshot? {
        guard let objData = UserDefaults.standard.data(forKey: Self.strSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: objData)
    }
}
