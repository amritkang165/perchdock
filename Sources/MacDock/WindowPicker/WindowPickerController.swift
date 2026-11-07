import AppKit
import SwiftUI

/// Shows, positions and animates the window picker above a dock icon, and
/// streams window thumbnails into it.
@MainActor
final class WindowPickerController {
    private let objState = WindowPickerState()
    private let objPanel: DockPanel
    private let objHostingView: TrackingHostingView<WindowPickerView>
    private let objThumbnailService: ThumbnailService
    private var objThumbnailTask: Task<Void, Never>?
    private var objLastAnchorPoint: CGPoint = .zero

    /// Whether the picker is on screen (or fading in).
    private(set) var blnIsVisible = false

    /// Whether the mouse is currently over the picker.
    private(set) var blnMouseInside = false

    /// Dock item index the picker belongs to.
    private(set) var intAnchorIndex: Int?

    /// Fired when the mouse enters or leaves the picker.
    var onMouseInsideChanged: ((Bool) -> Void)?

    /// Fired when the user clicks a window card.
    var onSelectWindow: ((WindowInfo) -> Void)?

    /// Fired when the user clicks a card's close button.
    var onCloseWindow: ((WindowInfo) -> Void)?

    /// Builds the (initially hidden) picker panel.
    /// - Parameter objThumbnailService: Source of window thumbnails.
    init(objThumbnailService: ThumbnailService) {
        self.objThumbnailService = objThumbnailService
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
    ///   - objAppIcon: Placeholder shown until a thumbnail arrives.
    ///   - arrObjWindows: Windows to show.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    func show(strAppName: String, objAppIcon: NSImage, arrObjWindows: [WindowInfo], intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        let blnSameApp = blnIsVisible && self.intAnchorIndex == intAnchorIndex

        objState.blnNeedsPermission = false
        objState.objAppIcon = objAppIcon
        objState.arrObjWindows = arrObjWindows

        // Seed with cached thumbnails so cards never flash empty on re-open.
        var dictObjSeed: [Int: NSImage] = blnSameApp ? objState.dictObjThumbnails : [:]
        for objWindow in arrObjWindows {
            if let intWindowId = objWindow.intWindowId, let objCached = objThumbnailService.cachedThumbnail(for: intWindowId) {
                dictObjSeed[objWindow.id] = objCached
            }
        }
        objState.dictObjThumbnails = dictObjSeed

        present(strAppName: strAppName, intAnchorIndex: intAnchorIndex, objAnchorPoint: objAnchorPoint)
        refreshThumbnails(for: arrObjWindows, intAnchorIndex: intAnchorIndex)
    }

    /// Shows a single row asking for Accessibility access instead of window cards.
    /// - Parameters:
    ///   - strAppName: Header text.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    func showPermissionNotice(strAppName: String, intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        objThumbnailTask?.cancel()
        objState.blnNeedsPermission = true
        objState.arrObjWindows = []
        objState.dictObjThumbnails = [:]
        present(strAppName: strAppName, intAnchorIndex: intAnchorIndex, objAnchorPoint: objAnchorPoint)
    }

    /// Fades the picker out.
    func hide() {
        guard blnIsVisible else { return }
        blnIsVisible = false
        blnMouseInside = false
        intAnchorIndex = nil
        objThumbnailTask?.cancel()

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

    // MARK: - Presentation

    /// Sizes and positions the panel for the current state, then animates it in (or over).
    /// - Parameters:
    ///   - strAppName: Header text.
    ///   - intAnchorIndex: Dock item index the picker belongs to.
    ///   - objAnchorPoint: Screen point at the top-center of the icon.
    private func present(strAppName: String, intAnchorIndex: Int, objAnchorPoint: CGPoint) {
        objState.strAppName = strAppName
        objState.objHoveredHit = nil
        self.intAnchorIndex = intAnchorIndex
        objLastAnchorPoint = objAnchorPoint

        let objSize = WindowPickerLayout.size(forCount: objState.arrObjWindows.count, blnNotice: objState.blnNeedsPermission)
        var fltOriginX = objAnchorPoint.x - objSize.width / 2

        // Keep the picker fully on screen near the screen edges.
        if let objScreen = NSScreen.screens.first(where: { $0.frame.contains(objAnchorPoint) }) ?? NSScreen.main {
            let objBounds = objScreen.frame.insetBy(dx: 8, dy: 0)
            fltOriginX = min(max(fltOriginX, objBounds.minX), objBounds.maxX - objSize.width)
        }

        let objFinalFrame = NSRect(x: fltOriginX.rounded(), y: objAnchorPoint.y + 8, width: objSize.width, height: objSize.height)

        if blnIsVisible {
            // Already open: glide to the new icon/size instead of re-animating in.
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

    /// Captures fresh thumbnails in the background and fades each in as it arrives.
    /// - Parameters:
    ///   - arrObjWindows: Windows shown in the picker.
    ///   - intAnchorIndex: Dock item the capture belongs to (stale results are dropped).
    private func refreshThumbnails(for arrObjWindows: [WindowInfo], intAnchorIndex: Int) {
        objThumbnailTask?.cancel()
        objThumbnailService.requestPermissionIfNeeded()

        let dictIntIdsByWindowId = Dictionary(
            arrObjWindows.compactMap { objWindow in objWindow.intWindowId.map { ($0, objWindow.id) } },
            uniquingKeysWith: { intFirst, _ in intFirst }
        )
        let arrIntWindowIds = arrObjWindows.compactMap(\.intWindowId)

        objThumbnailTask = Task { [weak self] in
            guard let self else { return }
            await self.objThumbnailService.captureThumbnails(for: arrIntWindowIds) { intWindowId, objImage in
                // Ignore results that land after the picker moved to another app or closed.
                guard self.blnIsVisible, self.intAnchorIndex == intAnchorIndex,
                      let intCardId = dictIntIdsByWindowId[intWindowId] else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    self.objState.dictObjThumbnails[intCardId] = objImage
                }
            }
        }
    }

    // MARK: - Mouse

    /// Updates hover highlight and inside/outside state.
    /// - Parameter objPoint: Local mouse point, or `nil` on exit.
    private func handleMouseMoved(_ objPoint: CGPoint?) {
        let objHit = objPoint.flatMap {
            WindowPickerLayout.hit(at: $0, count: objState.arrObjWindows.count, blnNotice: objState.blnNeedsPermission)
        }
        if objHit != objState.objHoveredHit {
            withAnimation(.easeOut(duration: 0.1)) {
                objState.objHoveredHit = objHit
            }
        }

        let blnInside = objPoint != nil
        if blnInside != blnMouseInside {
            blnMouseInside = blnInside
            onMouseInsideChanged?(blnInside)
        }
    }

    /// Raises or closes the clicked window, or opens Accessibility settings.
    /// - Parameter objPoint: Local click point.
    private func handleClick(_ objPoint: CGPoint) {
        let objHit = WindowPickerLayout.hit(at: objPoint, count: objState.arrObjWindows.count, blnNotice: objState.blnNeedsPermission)

        switch objHit {
        case .notice:
            hide()
            AccessibilityPermission.openSystemSettings()
        case .close(let intIndex) where objState.arrObjWindows[intIndex].objElement != nil:
            onCloseWindow?(objState.arrObjWindows[intIndex])
        case .card(let intIndex), .close(let intIndex):
            onSelectWindow?(objState.arrObjWindows[intIndex])
        case nil:
            break
        }
    }
}
