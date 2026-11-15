// The icon generator: draws the app icon and writes Resources/AppIcon.icns.
//
//     gmake icon
//
import AppKit
import CoreGraphics

/// The app icon, drawn: the forelock of Kairos.
///
/// Kairos, the god of the opportune moment, had a long lock of hair at the front and none at the back.
/// You seize the moment by the forelock as it comes; once it has passed there is nothing to hold. The
/// icon is that lock: thick at the root, sweeping forward and curling to a point.
///
/// It is static on purpose. The app used to redraw its Dock icon as a live clock, but macOS applies its
/// Dark, Clear and Tinted icon styles only to the bundle icon, never to an image an app sets at runtime
/// (FB20291186), so a live icon could never match the icons beside it.
enum IconRenderer {

    static let brandBlue = NSColor(red: 0x00 / 255.0, green: 0x40 / 255.0, blue: 0x80 / 255.0, alpha: 1.0)

    /// Apple's macOS icon grid: an 824-point tile, inset 100, in a 1024 canvas, with this corner radius.
    static let gridCanvas: CGFloat = 1024
    static let gridBody: CGFloat = 824
    static let gridRadius: CGFloat = 185

    static func draw(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let s = size, cx = s / 2, cy = s / 2
        let b = s * gridBody / gridCanvas                  // the tile's side; the drawing is measured in it
        let inset = (s - b) / 2

        // Background: the brand blue tile, with a soft light from above for depth.
        let bgRect = NSRect(x: inset, y: inset, width: b, height: b)
        let radius = s * gridRadius / gridCanvas
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
        brandBlue.setFill()
        bgPath.fill()

        let depth = [
            NSColor(white: 1.0, alpha: 0.10).cgColor,
            NSColor(white: 0.0, alpha: 0.10).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: depth, locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(bgPath.cgPath)
            ctx.clip()
            ctx.drawRadialGradient(gradient,
                                   startCenter: CGPoint(x: cx, y: cy + b * 0.20), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: b * 0.70,
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }

        // The forelock. Its centre line is a sweep up from the root, then a spiral turning clockwise and
        // inward; the width tapers along it from root to tip.
        let curl = CGPoint(x: cx + b * 0.10, y: cy + b * 0.06)     // the spiral's centre
        let curlStart = b * 0.17                                   // its radius where the sweep joins it
        let curlEnd = b * 0.045                                    // and at the tip
        let curlTurn: CGFloat = 1.05                               // turns of the spiral
        let root = CGPoint(x: cx - b * 0.27, y: cy - b * 0.31)
        let join = CGPoint(x: curl.x, y: curl.y + curlStart)      // top of the spiral, heading right
        let c1 = CGPoint(x: root.x + b * 0.03, y: root.y + b * 0.32)
        let c2 = CGPoint(x: join.x - b * 0.24, y: join.y)

        var line: [CGPoint] = []
        let sweepSteps = 60, curlSteps = 90
        for i in 0...sweepSteps {
            let t = CGFloat(i) / CGFloat(sweepSteps), u = 1 - t
            line.append(CGPoint(
                x: u*u*u*root.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*join.x,
                y: u*u*u*root.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*join.y))
        }
        let shrink = log(curlStart / curlEnd)
        for i in 1...curlSteps {
            let t = CGFloat(i) / CGFloat(curlSteps)
            let angle = .pi / 2 - t * curlTurn * 2 * .pi           // clockwise from the top
            let r = curlStart * exp(-shrink * t)
            line.append(CGPoint(x: curl.x + cos(angle) * r, y: curl.y + sin(angle) * r))
        }

        // Width at each point: full at the root, a little less where the curl begins, nearly nothing at the tip.
        let rootWidth = b * 0.115, joinWidth = b * 0.085, tipWidth = b * 0.012
        func width(_ i: Int) -> CGFloat {
            if i <= sweepSteps {
                let t = CGFloat(i) / CGFloat(sweepSteps)
                return rootWidth + (joinWidth - rootWidth) * t
            }
            let t = CGFloat(i - sweepSteps) / CGFloat(curlSteps)
            return joinWidth + (tipWidth - joinWidth) * t
        }

        // The outline: one edge out along the line, the other back, offset either side by half the width.
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in line.indices {
            let a = line[max(i - 1, 0)], c = line[min(i + 1, line.count - 1)]
            let dx = c.x - a.x, dy = c.y - a.y, len = max(hypot(dx, dy), .ulpOfOne)
            let nx = -dy / len, ny = dx / len, h = width(i) / 2
            left.append(CGPoint(x: line[i].x + nx * h, y: line[i].y + ny * h))
            right.append(CGPoint(x: line[i].x - nx * h, y: line[i].y - ny * h))
        }
        let lock = CGMutablePath()
        lock.addLines(between: left + right.reversed())
        lock.closeSubpath()

        // Solid white in a layer, faded as a whole: drawn translucent directly, the root's cap and the
        // strand would add up where they overlap and leave a seam.
        ctx.setAlpha(0.95)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(lock)
        ctx.fillPath()
        // The root is rounded, as a stroke's cap would be.
        ctx.fillEllipse(in: CGRect(x: root.x - rootWidth / 2, y: root.y - rootWidth / 2,
                                   width: rootWidth, height: rootWidth))
        ctx.endTransparencyLayer()

        image.unlockFocus()
        return image
    }

    // ── build-time generation ───────────────────────────────────────────────
    static let iconsetSizes: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    /// Writes `Resources/Kairos.iconset` and pipes it through `iconutil` into `Resources/AppIcon.icns`.
    static func writeIcns(base: String) {
        let iconsetDir = base + "/Resources/Kairos.iconset"
        try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
        for (size, name) in iconsetSizes {
            let image = draw(size: CGFloat(size))
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
            print("  \(name) (\(size)x\(size))")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconsetDir, "-o", base + "/Resources/AppIcon.icns"]
        try? p.run()
        p.waitUntilExit()
        print("  AppIcon.icns")
    }
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

let base = FileManager.default.currentDirectoryPath
IconRenderer.writeIcns(base: base)
print("Done.")
