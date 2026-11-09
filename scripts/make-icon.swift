#!/usr/bin/env swift
// Turns square artwork into a macOS app icon: masks it to Apple's rounded-square
// shape (824 pt inside a 1024 pt canvas, continuous corners, soft drop shadow) and
// writes every AppIcon size into an asset catalog.
//
// Usage: scripts/make-icon.swift <artwork.png|jpg> [zoom] [--preview out.png]
//   zoom: scales the artwork up inside the mask (e.g. 1.06) to crop away edges.
//   --preview: only writes the 1024 px master to out.png; leaves the app untouched.
import AppKit

/// Canvas and shape metrics from Apple's macOS icon grid (1024 px master).
let fltCanvas: CGFloat = 1024
let fltShape: CGFloat = 824
let fltCornerRadius: CGFloat = 185.4

/// Renders the masked master icon for the given artwork at a 1024 px canvas.
/// - Parameters:
///   - objArtwork: The source artwork (any size; drawn aspect-fill).
///   - fltZoom: Extra scale applied inside the mask to crop the artwork's edges.
/// - Returns: A 1024×1024 bitmap with transparent margins around the shape.
func renderMaster(objArtwork: NSImage, fltZoom: CGFloat) -> NSBitmapImageRep {
    let objRep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(fltCanvas), pixelsHigh: Int(fltCanvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: objRep)

    // The shape is centered horizontally and sits slightly high, like Apple's icons,
    // leaving room for the shadow underneath.
    let fltInset = (fltCanvas - fltShape) / 2
    let objShapeRect = CGRect(x: fltInset, y: fltInset + 10, width: fltShape, height: fltShape)
    let objPath = NSBezierPath(roundedRect: objShapeRect, xRadius: fltCornerRadius, yRadius: fltCornerRadius)

    // Soft drop shadow beneath the shape.
    NSGraphicsContext.saveGraphicsState()
    let objShadow = NSShadow()
    objShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    objShadow.shadowOffset = NSSize(width: 0, height: -10)
    objShadow.shadowBlurRadius = 24
    objShadow.set()
    NSColor.black.setFill()
    objPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Artwork, clipped to the shape and drawn aspect-fill with the requested zoom.
    NSGraphicsContext.saveGraphicsState()
    objPath.addClip()
    let fltSide = fltShape * fltZoom
    let objArtRect = CGRect(x: objShapeRect.midX - fltSide / 2, y: objShapeRect.midY - fltSide / 2,
                            width: fltSide, height: fltSide)
    objArtwork.draw(in: objArtRect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline inner highlight, which gives native icons their crisp edge.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let objEdge = NSBezierPath(roundedRect: objShapeRect.insetBy(dx: 1, dy: 1),
                               xRadius: fltCornerRadius - 1, yRadius: fltCornerRadius - 1)
    objEdge.lineWidth = 2
    objEdge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return objRep
}

/// Scales the master down to a square PNG of the given pixel size.
/// - Parameters:
///   - objMaster: The 1024 px master icon.
///   - intPixels: Target width and height in pixels.
/// - Returns: PNG data for the resized icon.
func resizedPNG(objMaster: NSBitmapImageRep, intPixels: Int) -> Data {
    let objRep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: intPixels, pixelsHigh: intPixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let objContext = NSGraphicsContext(bitmapImageRep: objRep)!
    objContext.imageInterpolation = .high
    NSGraphicsContext.current = objContext
    objMaster.draw(in: CGRect(x: 0, y: 0, width: intPixels, height: intPixels))
    NSGraphicsContext.restoreGraphicsState()
    return objRep.representation(using: .png, properties: [:])!
}

// Parse arguments: artwork path, optional zoom, optional --preview output.
let arrStrArgs = Array(CommandLine.arguments.dropFirst())
guard let strInput = arrStrArgs.first, let objArtwork = NSImage(contentsOfFile: strInput) else {
    FileHandle.standardError.write("Usage: make-icon.swift <artwork> [zoom] [--preview out.png]\n".data(using: .utf8)!)
    exit(1)
}
let fltZoom = arrStrArgs.dropFirst().first.flatMap { Double($0) }.map { CGFloat($0) } ?? 1.0
let objMaster = renderMaster(objArtwork: objArtwork, fltZoom: fltZoom)

// Preview mode: write just the master and stop.
if let intFlag = arrStrArgs.firstIndex(of: "--preview"), intFlag + 1 < arrStrArgs.count {
    try! resizedPNG(objMaster: objMaster, intPixels: 1024).write(to: URL(fileURLWithPath: arrStrArgs[intFlag + 1]))
    exit(0)
}

// Full mode: write every macOS AppIcon slot (16–512 pt at 1x and 2x) plus Contents.json.
let strSetDir = "Sources/PerchDock/Resources/Assets.xcassets/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: strSetDir, withIntermediateDirectories: true)
var arrDictImages: [[String: String]] = []
for intPoints in [16, 32, 128, 256, 512] {
    for intScale in [1, 2] {
        let strName = "icon_\(intPoints)x\(intPoints)\(intScale == 2 ? "@2x" : "").png"
        try! resizedPNG(objMaster: objMaster, intPixels: intPoints * intScale)
            .write(to: URL(fileURLWithPath: "\(strSetDir)/\(strName)"))
        arrDictImages.append(["idiom": "mac", "size": "\(intPoints)x\(intPoints)",
                              "scale": "\(intScale)x", "filename": strName])
    }
}
let dictContents: [String: Any] = ["images": arrDictImages, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: dictContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(strSetDir)/Contents.json"))
let dictCatalog: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: dictCatalog, options: [.prettyPrinted])
    .write(to: URL(fileURLWithPath: "Sources/PerchDock/Resources/Assets.xcassets/Contents.json"))
print("Wrote \(strSetDir)")
