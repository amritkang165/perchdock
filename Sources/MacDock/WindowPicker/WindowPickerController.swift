import AppKit

/// Shows, positions and animates the window picker above a dock icon.
@MainActor
final class WindowPickerController {
    private let objState = WindowPickerState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<WindowPickerView>

    /// Whether the picker is on screen (or fading in).
    private(set) var blnIsVisible = false

    /// Whether the mouse is currently over the picker.
    private(set) var blnMouseInside = false

    /// Dock item index the picker belongs to.
    private(set) var intAnchorIndex: Int?

    /// Fired when the mouse enters or leaves the picker.
    var onMouseInsideChanged: ((Bool) -> Void)?

    /// Fired when the user clicks a window row.
    var onSelectWindow: ((WindowInfo) -> Void)?

    /// Builds the (initially hidden) picker panel.
    init() {
        objPanel = DockPanel(contentRect: .zero)
        objHostingView = TrackingHostingView(rootView: WindowPickerView(objState: objState))
        objPanel.contentView = objHostingView

        objHostingView.onMouseMoved = { [weak self] objPoint in
            self?.handleMouseMoved(objPoint)
        }
        objHostingView.onMouseUp = { [weak self] objPoint in
            self?.handleClick(objPoint)
        }
    }

    /// Shows the picker for an app, centered above its dock icon.
    /// - Parameters:
    ///   - strAppName: Header text.
    ///   - arrObjWindows: Windows to list.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    func show(strAppName: String, arrObjWindows: [WindowInfo], intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        objState.blnNeedsPermission = false
        objState.arrObjWindows = arrObjWindows
        present(strAppName: strAppName, intAnchorIndex: intAnchorIndex, objAnchorPoint: objAnchorPoint)
    }

    /// Shows a single row asking for Accessibility access instead of a window list.
    /// - Parameters:
    ///   - strAppName: Header text.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    func showPermissionNotice(strAppName: String, intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        objState.blnNeedsPermission = true
        objState.arrObjWindows = []
        present(strAppName: strAppName, intAnchorIndex: intAnchorIndex, objAnchorPoint: objAnchorPoint)
    }

    /// Positions the panel for the current state and animates it in (or over).
    /// - Parameters:
    ///   - strAppName: Header text.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    private func present(strAppName: String, intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        objState.strAppName = strAppName
        objState.intHoveredRow = nil
        self.intAnchorIndex = intAnchorIndex

        let fltHeight = WindowPickerLayout.height(forRowCount: objState.intRowCount)
        var fltOriginX = objAnchorPoint.x - WindowPickerLayout.fltWidth / 2

        // Keep the picker fully on screen near the screen edges.
        if let objScreen = NSScreen.screens.first(where: { $0.frame.contains(objAnchorPoint) }) ?? NSScreen.main {
            let objBounds = objScreen.frame.insetBy(dx: 8, dy: 0)
            fltOriginX = min(max(fltOriginX, objBounds.minX), objBounds.maxX - WindowPickerLayout.fltWidth)
        }

        let objFinalFrame = NSRect(x: fltOriginX, y: objAnchorPoint.y + 8, width: WindowPickerLayout.fltWidth, height: fltHeight)

        if blnIsVisible {
            // Already open for another icon: glide over instead of re-animating in.
            NSAnimationContext.runAnimationGroup { objContext in
                objContext.duration = 0.14
                objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
                objPanel.animator().setFrame(objFinalFrame, display: true)
                objPanel.animator().alphaValue = 1
            }
            return
        }

        // Fade in while rising a few points: short and snappy.
        blnIsVisible = true
        objPanel.setFrame(objFinalFrame.offsetBy(dx: 0, dy: -6), display: false)
        objPanel.alphaValue = 0
        objPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { objContext in
            objContext.duration = 0.14
            objContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objPanel.animator().setFrame(objFinalFrame, display: true)
            objPanel.animator().alphaValue = 1
        }
    }

    /// Fades the picker out.
    func hide() {
        guard blnIsVisible else { return }
        blnIsVisible = false
        blnMouseInside = false
        intAnchorIndex = nil

        NSAnimationContext.runAnimationGroup({ objContext in
            objContext.duration = 0.1
            objPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade-out wins; don't order out the new picker.
                guard let self, !self.blnIsVisible else { return }
                self.objPanel.orderOut(nil)
            }
        })
    }

    /// Updates row highlight and inside/outside state.
    /// - Parameter objPoint: Local mouse point, or `nil` on exit.
    private func handleMouseMoved(_ objPoint: CGPoint?) {
        objState.intHoveredRow = objPoint.flatMap {
            WindowPickerLayout.rowIndex(at: $0, rowCount: objState.intRowCount)
        }

        let blnInside = objPoint != nil
        if blnInside != blnMouseInside {
            blnMouseInside = blnInside
            onMouseInsideChanged?(blnInside)
        }
    }

    /// Selects the clicked row's window.
    /// - Parameter objPoint: Local click point.
    private func handleClick(_ objPoint: CGPoint) {
        guard let intRow = WindowPickerLayout.rowIndex(at: objPoint, rowCount: objState.intRowCount) else { return }

        if objState.blnNeedsPermission {
            hide()
            AccessibilityPermission.openSystemSettings()
            return
        }
        onSelectWindow?(objState.arrObjWindows[intRow])
    }
}
