import AppKit

/// Borderless, transparent, non-activating panel used for the dock bar and the
/// window picker. Clicking it never steals focus from the app you're working in.
final class DockPanel: NSPanel {
    /// Creates a floating panel at Dock window level, visible on every Space.
    /// - Parameter objContentRect: Initial frame.
    init(contentRect objContentRect: NSRect) {
        super.init(
            contentRect: objContentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Same layer as the native Dock: above normal windows, below menus.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))

        // Every Space, unaffected by Mission Control, allowed over full-screen
        // apps, and skipped by Cmd-` window cycling.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    /// Allow frames beyond the screen edge, where the auto-hidden dock tucks away.
    /// - Parameters:
    ///   - frameRect: Requested frame.
    ///   - screen: Target screen.
    /// - Returns: The requested frame, unchanged.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Lets a panel take the keyboard temporarily (e.g. to type a group name).
    var blnAllowsKey = false

    /// Normally never key, so keystrokes keep going to the user's app.
    override var canBecomeKey: Bool { blnAllowsKey }

    /// Never become main.
    override var canBecomeMain: Bool { false }
}
