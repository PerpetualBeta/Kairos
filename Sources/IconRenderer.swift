import AppKit
import CoreGraphics

/// The app icon, drawn.
///
/// ONE COPY, USED TWICE: `gmake icon` renders it to `Resources/AppIcon.icns` at build time, and the running
/// app redraws it each minute with the real time and hands that to the Dock. Two copies of this drawing —
/// one in a generator script, one in the app — would drift the moment either was touched, and the drift
/// would stay invisible until someone held a Dock icon next to a Finder icon.
enum IconRenderer {

    static let brandBlue = NSColor(red: 0x00 / 255.0, green: 0x40 / 255.0, blue: 0x80 / 255.0, alpha: 1.0)

    /// `date` nil draws the icon at rest — 10:10, the horologist's convention, where the hands frame the
    /// centre symmetrically and neither hides the other. That is the static bundle icon. Pass a date and it
    /// tells the time instead.
    static func draw(size: CGFloat, date: Date? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let s = size, cx = s / 2, cy = s / 2

        // Background — rounded rect with brand colour
        let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
        brandBlue.setFill()
        bgPath.fill()

        // Subtle radial gradient for depth
        let gradSpace = CGColorSpaceCreateDeviceRGB()
        let gradColors = [
            NSColor(white: 1.0, alpha: 0.08).cgColor,
            NSColor(white: 0.0, alpha: 0.10).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: gradSpace, colors: gradColors, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.addPath(bgPath.cgPath)
            ctx.clip()
            ctx.drawRadialGradient(gradient,
                                   startCenter: CGPoint(x: cx, y: cy + s * 0.12), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: s * 0.55,
                                   options: [])
            ctx.restoreGState()
        }

        // ── Clock ──
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath)
        ctx.clip()

        let r = s * 0.30

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

        // The ring, heavy enough to survive 16 px where a hairline disappears entirely.
        ctx.setStrokeColor(faceColor.cgColor)
        ctx.setLineWidth(s * 0.05)
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

        // Quarter ticks only. Twelve turn to mud below 32 px and add nothing above it.
        ctx.setStrokeColor(tickColor.cgColor)
        ctx.setLineWidth(s * 0.030)
        ctx.setLineCap(.round)
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2
            ctx.move(to: CGPoint(x: cx + cos(a) * r * 0.66, y: cy + sin(a) * r * 0.66))
            ctx.addLine(to: CGPoint(x: cx + cos(a) * r * 0.82, y: cy + sin(a) * r * 0.82))
            ctx.strokePath()
        }

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

        let hourDeg: CGFloat, minuteDeg: CGFloat
        if let date {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let h = CGFloat(c.hour ?? 10), m = CGFloat(c.minute ?? 10)
            // The hour hand creeps between numerals, or it reads as wrong for fifty-nine minutes an hour.
            hourDeg = (h.truncatingRemainder(dividingBy: 12) + m / 60) * 30
            minuteDeg = m * 6
        } else {
            hourDeg = 305; minuteDeg = 60          // 10:10
        }
        hand(clockDegrees: hourDeg, length: r * 0.52, width: s * 0.045)
        hand(clockDegrees: minuteDeg, length: r * 0.74, width: s * 0.035)

        ctx.setFillColor(faceColor.cgColor)
        let pin = s * 0.030
        ctx.fillEllipse(in: CGRect(x: cx - pin, y: cy - pin, width: pin * 2, height: pin * 2))

        ctx.restoreGState()
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
            let image = draw(size: CGFloat(size))          // at rest — the bundle icon is not a live clock
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
