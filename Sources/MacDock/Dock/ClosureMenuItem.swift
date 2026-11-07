import AppKit

/// `NSMenuItem` that runs a closure, so context menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let fnAction: () -> Void

    /// Creates an item that runs `fnAction` when chosen.
    /// - Parameters:
    ///   - strTitle: Menu title.
    ///   - objState: Checkmark state.
    ///   - fnAction: Work to do when chosen.
    init(_ strTitle: String, objState: NSControl.StateValue = .off, fnAction: @escaping () -> Void) {
        self.fnAction = fnAction
        super.init(title: strTitle, action: #selector(run), keyEquivalent: "")
        target = self
        state = objState
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Invokes the closure.
    @objc private func run() {
        fnAction()
    }
}
