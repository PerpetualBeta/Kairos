#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Brand colour
let brandBlue = NSColor(red: 0x00/255.0, green: 0x40/255.0, blue: 0x80/255.0, alpha: 1.0)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2

    // Background — rounded rect with brand colour
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill()
    bgPath.fill()

    // Subtle radial gradient for depth
    let gradSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        NSColor(white: 1.0, alpha: 0.08).cgColor,
        NSColor(white: 0.0, alpha: 0.10).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: gradSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath)
        ctx.clip()
        ctx.drawRadialGradient(gradient,
            startCenter: CGPoint(x: cx, y: cy + s * 0.12),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: s * 0.55,
            options: [])
        ctx.restoreGState()
    }

    // ── Clock ──
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    let r = s * 0.30

    // Outer glow, as the template's globe has — lifts the glyph off the flat blue
    let glowColors = [
        NSColor(white: 1.0, alpha: 0.06).cgColor,
        NSColor(white: 1.0, alpha: 0.0).cgColor,
    ] as CFArray
    if let glow = CGGradient(colorsSpace: gradSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(glow,
            startCenter: CGPoint(x: cx, y: cy), startRadius: r * 0.9,
            endCenter: CGPoint(x: cx, y: cy), endRadius: r * 1.4,
            options: [])
    }

    let faceColor = NSColor(white: 1.0, alpha: 0.92)
    let tickColor = NSColor(white: 1.0, alpha: 0.45)

    // The ring. Heavy enough to survive 16 px, where a hairline would disappear entirely.
    ctx.setStrokeColor(faceColor.cgColor)
    ctx.setLineWidth(s * 0.05)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

    // Quarter ticks only. Twelve of them turn to mud below 32 px and add nothing above it.
    ctx.setStrokeColor(tickColor.cgColor)
    ctx.setLineWidth(s * 0.030)
    ctx.setLineCap(.round)
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2                       // 12, 3, 6, 9
        let inner = r * 0.66, outer = r * 0.82
        ctx.move(to: CGPoint(x: cx + cos(a) * inner, y: cy + sin(a) * inner))
        ctx.addLine(to: CGPoint(x: cx + cos(a) * outer, y: cy + sin(a) * outer))
        ctx.strokePath()
    }

    // Hands at 10:10 — the horologist's convention for a clock at rest. It is not arbitrary: the hands
    // frame the centre symmetrically and neither hides the other, which is exactly what a glyph needs.
    // Clock angles run clockwise from twelve; drawing angles run anticlockwise from east, hence 90 − θ.
    func hand(clockDegrees: CGFloat, length: CGFloat, width: CGFloat) {
        let a = (90 - clockDegrees) * .pi / 180
        ctx.setStrokeColor(faceColor.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + cos(a) * length, y: cy + sin(a) * length))
        ctx.strokePath()
    }
    hand(clockDegrees: 305, length: r * 0.52, width: s * 0.045)   // hour, just past ten
    hand(clockDegrees: 60,  length: r * 0.74, width: s * 0.035)   // minute, at ten past

    // Centre pin
    ctx.setFillColor(faceColor.cgColor)
    let pin = s * 0.030
    ctx.fillEllipse(in: CGRect(x: cx - pin, y: cy - pin, width: pin * 2, height: pin * 2))

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:           path.move(to: points[0])
            case .lineTo:           path.addLine(to: points[0])
            case .curveTo:          path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:     path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:        path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// Generate all icon sizes
let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let scriptDir = CommandLine.arguments[0].components(separatedBy: "/").dropLast().joined(separator: "/")
let base = scriptDir.isEmpty ? "." : scriptDir
let iconsetDir = base + "/Resources/Kairos.iconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try! png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
    print("  \(name) (\(size)x\(size))")
}

// Generate .icns
let icnsPath = base + "/Resources/AppIcon.icns"
let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! result.run()
result.waitUntilExit()
print("  AppIcon.icns")
print("Done.")
