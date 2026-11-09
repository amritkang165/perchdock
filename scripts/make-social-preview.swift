#!/usr/bin/env swift
// Renders the GitHub social preview card (the image shown when the repository link
// is shared on X, Slack, Discord, Hacker News previews and so on).
// GitHub wants 1280×640; upload the result under Settings → General → Social preview.
//
// Usage: scripts/make-social-preview.swift [out.png]
//   out.png defaults to docs/images/social-preview.png.
import AppKit

/// Card size GitHub recommends for social previews.
let fltWidth: CGFloat = 1280
let fltHeight: CGFloat = 640

/// Repository root, so the script works from any directory.
let objRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let objOutUrl = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : objRoot.appendingPathComponent("docs/images/social-preview.png")

/// Loads an image from docs/images or exits with a readable error.
/// - Parameter strName: File name inside docs/images.
/// - Returns: The image.
func loadImage(_ strName: String) -> NSImage {
    let objUrl = objRoot.appendingPathComponent("docs/images/\(strName)")
    guard let objImage = NSImage(contentsOf: objUrl) else {
        FileHandle.standardError.write("Can't read \(objUrl.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return objImage
}

/// Draws a single line of text with its top-left corner at the given point (top-down coordinates).
/// - Parameters:
///   - strText: Text to draw.
///   - objFont: Font.
///   - objColor: Text color.
///   - objTopLeft: Top-left corner, measured from the top of the card.
func drawText(_ strText: String, objFont: NSFont, objColor: NSColor, objTopLeft: CGPoint) {
    let objString = NSAttributedString(string: strText, attributes: [.font: objFont, .foregroundColor: objColor])
    let objSize = objString.size()
    objString.draw(at: CGPoint(x: objTopLeft.x, y: fltHeight - objTopLeft.y - objSize.height))
}

let objRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(fltWidth), pixelsHigh: Int(fltHeight),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: objRep)

// Background: deep blue-to-violet gradient, like a macOS 26 wallpaper at dusk.
let objBackground = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.22, green: 0.12, blue: 0.36, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.36, alpha: 1),
])!
objBackground.draw(in: CGRect(x: 0, y: 0, width: fltWidth, height: fltHeight), angle: -20)

// Header: app icon, name and the one-line pitch.
let fltMargin: CGFloat = 72
let fltIconSide: CGFloat = 148
loadImage("icon.png").draw(in: CGRect(x: fltMargin, y: fltHeight - fltMargin - fltIconSide, width: fltIconSide, height: fltIconSide))

let fltTextX = fltMargin + fltIconSide + 36
drawText("PerchDock", objFont: .systemFont(ofSize: 76, weight: .bold), objColor: .white,
         objTopLeft: CGPoint(x: fltTextX, y: fltMargin - 4))
drawText("A faster, smarter Dock for macOS", objFont: .systemFont(ofSize: 34, weight: .medium),
         objColor: NSColor.white.withAlphaComponent(0.85), objTopLeft: CGPoint(x: fltTextX, y: fltMargin + 92))

// Feature line under the header.
drawText("Live window previews  ·  App groups  ·  Now Playing  ·  Liquid Glass",
         objFont: .systemFont(ofSize: 27, weight: .regular), objColor: NSColor.white.withAlphaComponent(0.7),
         objTopLeft: CGPoint(x: fltMargin, y: fltMargin + fltIconSide + 36))

// Screenshot of the dock along the bottom. The source has a lot of wallpaper above and
// beside the dock, so crop to the lower band and trim the sides before scaling it up.
let objDock = loadImage("dock-bottom.png")
let objCrop = CGRect(x: objDock.size.width * 0.06, y: 0,
                     width: objDock.size.width * 0.88, height: objDock.size.height * 0.62)
let fltDockWidth = fltWidth - fltMargin * 2
let fltDockHeight = fltDockWidth * objCrop.height / objCrop.width
let objDockRect = CGRect(x: fltMargin, y: 56, width: fltDockWidth, height: fltDockHeight)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: objDockRect, xRadius: 20, yRadius: 20).addClip()
objDock.draw(in: objDockRect, from: objCrop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// Footer: open-source tag in the top-right corner.
let strTag = "Free & open source"
let objTagFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
let fltTagWidth = NSAttributedString(string: strTag, attributes: [.font: objTagFont]).size().width + 36
let objTagRect = CGRect(x: fltWidth - fltMargin - fltTagWidth, y: fltHeight - fltMargin - 44, width: fltTagWidth, height: 44)
NSColor.white.withAlphaComponent(0.14).setFill()
NSBezierPath(roundedRect: objTagRect, xRadius: 22, yRadius: 22).fill()
drawText(strTag, objFont: objTagFont, objColor: .white, objTopLeft: CGPoint(x: objTagRect.minX + 18, y: fltMargin + 9))

NSGraphicsContext.restoreGraphicsState()

guard let objPng = objRep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Couldn't encode the PNG\n".data(using: .utf8)!)
    exit(1)
}
try objPng.write(to: objOutUrl)
print("Wrote \(objOutUrl.path)")
