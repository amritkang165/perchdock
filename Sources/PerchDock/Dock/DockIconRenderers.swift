import AppKit

/// Draws a group's icon: a rounded tile with up to four member icons in a 2×2 grid
/// (like a folder on iOS).
enum GroupIconRenderer {
    /// Canvas size; drawn large so magnification stays sharp.
    private static let fltSize: CGFloat = 256

    /// Builds the group icon.
    /// - Parameters:
    ///   - arrObjIcons: Member icons (first four are used).
    ///   - objColor: Tile color, or `nil` for frosted gray.
    /// - Returns: Composite image.
    static func icon(for arrObjIcons: [NSImage], objColor: NSColor? = nil) -> NSImage {
        NSImage(size: NSSize(width: fltSize, height: fltSize), flipped: true) { objRect in
            // Rounded tile, inset like a real app icon (~10% margin).
            let objTile = objRect.insetBy(dx: fltSize * 0.08, dy: fltSize * 0.08)
            let objPath = NSBezierPath(roundedRect: objTile, xRadius: objTile.width * 0.22, yRadius: objTile.width * 0.22)
            if let objColor {
                // Top-to-bottom sheen so a colored tile reads like an app icon.
                NSGradient(starting: objColor.blended(withFraction: 0.18, of: .white) ?? objColor,
                           ending: objColor.blended(withFraction: 0.12, of: .black) ?? objColor)?
                    .draw(in: objPath, angle: 90)
            } else {
                NSColor(white: 0.5, alpha: 0.35).setFill()
                objPath.fill()
            }
            NSColor(white: 1, alpha: 0.25).setStroke()
            objPath.lineWidth = 3
            objPath.stroke()

            // 2×2 grid of member icons.
            let fltPadding = objTile.width * 0.1
            let fltCell = (objTile.width - fltPadding * 3) / 2
            for (intIndex, objIcon) in arrObjIcons.prefix(4).enumerated() {
                let intColumn = intIndex % 2
                let intRow = intIndex / 2
                let objCell = NSRect(
                    x: objTile.minX + fltPadding + CGFloat(intColumn) * (fltCell + fltPadding),
                    y: objTile.minY + fltPadding + CGFloat(intRow) * (fltCell + fltPadding),
                    width: fltCell,
                    height: fltCell
                )
                objIcon.draw(in: objCell)
            }
            return true
        }
    }
}

/// What a divider looks like while it's being dragged: a short vertical line.
enum DividerDragIcon {
    @MainActor static let image: NSImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { objRect in
        let objLine = NSRect(x: objRect.midX - 1.5, y: objRect.height * 0.15, width: 3, height: objRect.height * 0.7)
        NSColor.labelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: objLine, xRadius: 1.5, yRadius: 1.5).fill()
        return true
    }
}

/// Draws a minimized window's tile: its last preview with the app icon in the corner
/// (like the native Dock's minimized windows).
enum MinimizedIconRenderer {
    private static let fltSize: CGFloat = 256

    /// Builds the tile icon.
    /// - Parameters:
    ///   - objThumbnail: Window preview, if one was captured.
    ///   - objAppIcon: Owning app's icon.
    /// - Returns: Composite image.
    static func icon(objThumbnail: NSImage?, objAppIcon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: fltSize, height: fltSize), flipped: false) { objRect in
            guard let objThumbnail, objThumbnail.size.width > 0, objThumbnail.size.height > 0 else {
                objAppIcon.draw(in: objRect)
                return true
            }

            // Aspect-fit the preview into the tile.
            let fltScale = min(objRect.width / objThumbnail.size.width, objRect.height / objThumbnail.size.height) * 0.92
            let objSize = NSSize(width: objThumbnail.size.width * fltScale, height: objThumbnail.size.height * fltScale)
            let objPreviewRect = NSRect(x: (objRect.width - objSize.width) / 2, y: (objRect.height - objSize.height) / 2,
                                        width: objSize.width, height: objSize.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: objPreviewRect, xRadius: 10, yRadius: 10).addClip()
            objThumbnail.draw(in: objPreviewRect)
            NSGraphicsContext.restoreGraphicsState()

            // App icon badge, bottom-right.
            let fltBadge = fltSize * 0.42
            objAppIcon.draw(in: NSRect(x: objRect.width - fltBadge, y: 0, width: fltBadge, height: fltBadge))
            return true
        }
    }
}
