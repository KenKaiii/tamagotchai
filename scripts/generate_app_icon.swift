#!/usr/bin/env swift
// Generates AppIcon PNGs from the MenuBarIcon vector drawing.
// Run: swift scripts/generate_app_icon.swift

import AppKit
import CoreGraphics

// MARK: - Reproduce the MenuBarIcon drawing logic

struct Layout {
    let w: CGFloat
    let h: CGFloat
    let headCenterX: CGFloat
    let headCenterY: CGFloat
    let headRadiusX: CGFloat
    let headRadiusY: CGFloat
    let eyeSpacing: CGFloat
    let eyeY: CGFloat
    let mouthY: CGFloat

    init(rect: NSRect) {
        w = rect.width
        h = rect.height
        headCenterX = w / 2
        headCenterY = h * 0.46
        headRadiusX = w * 0.38
        headRadiusY = h * 0.33
        eyeSpacing = headRadiusX * 0.52
        eyeY = headCenterY + headRadiusY * 0.08
        mouthY = headCenterY - headRadiusY * 0.38
    }
}

func drawMascot(in rect: NSRect, ctx: CGContext) {
    let layout = Layout(rect: rect)
    let color = CGColor(srgbRed: 0.2, green: 0.2, blue: 0.25, alpha: 1.0)
    let bgColor = CGColor(srgbRed: 0.95, green: 0.88, blue: 0.75, alpha: 1.0)

    // Background with rounded corners
    let cornerRadius = rect.width * 0.22
    let bgPath = CGPath(
        roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.setFillColor(bgColor)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // Inset the mascot slightly so it doesn't touch edges
    let inset = rect.width * 0.12
    let mascotRect = rect.insetBy(dx: inset, dy: inset)

    ctx.saveGState()
    ctx.translateBy(x: mascotRect.origin.x, y: mascotRect.origin.y)

    let scale = mascotRect.width
    let drawRect = NSRect(x: 0, y: 0, width: scale, height: scale)
    let ml = Layout(rect: drawRect)

    ctx.setFillColor(color)
    ctx.setStrokeColor(color)

    // Antenna
    let antennaBaseY = ml.headCenterY + ml.headRadiusY * 0.85
    let antennaTipY = scale - scale * 0.08
    let antennaTipRadius: CGFloat = scale * 0.05

    ctx.setLineWidth(scale * 0.06)
    ctx.move(to: CGPoint(x: ml.headCenterX, y: antennaBaseY))
    ctx.addLine(to: CGPoint(x: ml.headCenterX, y: antennaTipY - antennaTipRadius))
    ctx.strokePath()

    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX - antennaTipRadius,
        y: antennaTipY - antennaTipRadius,
        width: antennaTipRadius * 2,
        height: antennaTipRadius * 2
    ))

    // Head
    let headRect = CGRect(
        x: ml.headCenterX - ml.headRadiusX,
        y: ml.headCenterY - ml.headRadiusY,
        width: ml.headRadiusX * 2,
        height: ml.headRadiusY * 2
    )
    let headPath = CGPath(
        roundedRect: headRect,
        cornerWidth: ml.headRadiusX * 0.55,
        cornerHeight: ml.headRadiusY * 0.55,
        transform: nil
    )
    ctx.addPath(headPath)
    ctx.fillPath()

    // Ears
    let earRadius: CGFloat = scale * 0.08
    let earY = ml.headCenterY + ml.headRadiusY * 0.1

    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX - ml.headRadiusX - earRadius * 0.6,
        y: earY - earRadius,
        width: earRadius * 2,
        height: earRadius * 2
    ))
    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX + ml.headRadiusX - earRadius * 1.4,
        y: earY - earRadius,
        width: earRadius * 2,
        height: earRadius * 2
    ))

    // Eyes (cut out)
    ctx.setBlendMode(.clear)
    let eyeRX: CGFloat = scale * 0.09
    let eyeRY: CGFloat = scale * 0.11

    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX - ml.eyeSpacing - eyeRX,
        y: ml.eyeY - eyeRY,
        width: eyeRX * 2,
        height: eyeRY * 2
    ))
    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX + ml.eyeSpacing - eyeRX,
        y: ml.eyeY - eyeRY,
        width: eyeRX * 2,
        height: eyeRY * 2
    ))

    // Mouth (cut out) - smile
    let mouthW = ml.headRadiusX * 0.6
    let mouthH: CGFloat = scale * 0.06
    let mouthRect = CGRect(
        x: ml.headCenterX - mouthW / 2,
        y: ml.mouthY - mouthH / 2,
        width: mouthW,
        height: mouthH
    )
    let mouthPath = CGPath(
        roundedRect: mouthRect,
        cornerWidth: mouthH / 2,
        cornerHeight: mouthH / 2,
        transform: nil
    )
    ctx.addPath(mouthPath)
    ctx.fillPath()

    // Eye glints (restore blend mode)
    ctx.setBlendMode(.normal)
    ctx.setFillColor(color)

    let glintRadius: CGFloat = scale * 0.035
    let glintOffsetX: CGFloat = scale * 0.025
    let glintOffsetY: CGFloat = scale * 0.03

    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX - ml.eyeSpacing + glintOffsetX - glintRadius,
        y: ml.eyeY + glintOffsetY - glintRadius,
        width: glintRadius * 2,
        height: glintRadius * 2
    ))
    ctx.fillEllipse(in: CGRect(
        x: ml.headCenterX + ml.eyeSpacing + glintOffsetX - glintRadius,
        y: ml.eyeY + glintOffsetY - glintRadius,
        width: glintRadius * 2,
        height: glintRadius * 2
    ))

    ctx.restoreGState()
}

func renderIcon(size: Int) -> Data? {
    let scale: CGFloat = 1.0
    let pixelSize = size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: CGFloat(pixelSize) / scale, height: CGFloat(pixelSize) / scale)
    drawMascot(in: rect, ctx: ctx.cgContext)

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Generate all sizes

let outputDir = "tama/Assets.xcassets/AppIcon.appiconset"

struct IconSize {
    let size: Int
    let scale: Int
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)@\(scale)x.png" }
}

let sizes: [IconSize] = [
    IconSize(size: 16, scale: 1),
    IconSize(size: 16, scale: 2),
    IconSize(size: 32, scale: 1),
    IconSize(size: 32, scale: 2),
    IconSize(size: 128, scale: 1),
    IconSize(size: 128, scale: 2),
    IconSize(size: 256, scale: 1),
    IconSize(size: 256, scale: 2),
    IconSize(size: 512, scale: 1),
    IconSize(size: 512, scale: 2),
]

for iconSize in sizes {
    guard let data = renderIcon(size: iconSize.pixels) else {
        print("Failed to render \(iconSize.filename)")
        continue
    }
    let path = "\(outputDir)/\(iconSize.filename)"
    let url = URL(fileURLWithPath: path)
    try data.write(to: url)
    print("Generated \(iconSize.filename) (\(iconSize.pixels)x\(iconSize.pixels)px)")
}

// Update Contents.json
let contentsJSON: [String: Any] = [
    "images": sizes.map { iconSize -> [String: String] in
        [
            "filename": iconSize.filename,
            "idiom": "mac",
            "scale": "\(iconSize.scale)x",
            "size": "\(iconSize.size)x\(iconSize.size)",
        ]
    },
    "info": [
        "author": "xcode",
        "version": 1,
    ] as [String: Any],
]

let jsonData = try JSONSerialization.data(withJSONObject: contentsJSON, options: [.prettyPrinted, .sortedKeys])
let contentsPath = "\(outputDir)/Contents.json"
try jsonData.write(to: URL(fileURLWithPath: contentsPath))
print("Updated Contents.json")
print("Done!")
