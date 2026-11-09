import Testing
@testable import PerchDock

/// Matching the native Dock's window-list entries to real window titles, so they're
/// left out of the borrowed app menu actions.
@Suite("App menu window matching")
struct NativeDockMenuServiceTests {
    @Test("An exact title matches")
    func exactMatch() {
        #expect(NativeDockMenuService.matches("Inbox", strWindowTitle: "Inbox"))
    }

    @Test("The Dock drops app suffixes like \" - Google Chrome\"")
    func prefixMatch() {
        #expect(NativeDockMenuService.matches("GitHub - Pull requests", strWindowTitle: "GitHub - Pull requests - Google Chrome"))
    }

    @Test("Middle-truncated titles (\"Start…End\") match on both halves")
    func truncatedMatch() {
        #expect(NativeDockMenuService.matches("Quarterly…Final.xlsx", strWindowTitle: "Quarterly Report 2026 Final.xlsx"))
        #expect(!NativeDockMenuService.matches("Quarterly…Draft.xlsx", strWindowTitle: "Quarterly Report 2026 Final.xlsx"))
    }

    @Test("Short titles must match exactly, so actions like \"New\" aren't mistaken for windows")
    func shortTitlesNeedExactMatch() {
        #expect(!NativeDockMenuService.matches("New", strWindowTitle: "New Tab - Google Chrome"))
    }

    @Test("Untitled windows never match")
    func emptyWindowTitle() {
        #expect(!NativeDockMenuService.matches("New Window", strWindowTitle: ""))
    }
}
