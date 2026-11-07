import SwiftUI

/// MacDock entry point. All real setup happens in `AppDelegate`; the SwiftUI
/// `App` only exists to host the (future) Settings scene.
@main
struct MacDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var objAppDelegate

    var body: some Scene {
        // Placeholder until the Settings window lands in Phase 2.
        Settings {
            EmptyView()
        }
    }
}
