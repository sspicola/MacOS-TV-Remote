import AppKit

// Draw at each target size so small Finder icons stay sharp.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()

        let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920),
                                      xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.32, blue: 0.45, alpha: 1),
                   ending: NSColor(srgbRed: 0.06, green: 0.12, blue: 0.20, alpha: 1))!
            .draw(in: background, angle: -90)

        let screen = NSBezierPath(roundedRect: NSRect(x: 202, y: 346, width: 620, height: 406),
                                 xRadius: 60, yRadius: 60)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        screen.lineWidth = 34
        screen.stroke()
        let stand = NSBezierPath(roundedRect: NSRect(x: 402, y: 249, width: 220, height: 30),
                                xRadius: 15, yRadius: 15)
        NSColor.white.withAlphaComponent(0.95).setFill()
        stand.fill()
        let neck = NSBezierPath(rect: NSRect(x: 493, y: 277, width: 38, height: 52))
        neck.fill()

        let play = NSBezierPath()
        play.move(to: NSPoint(x: 455, y: 436))
        play.line(to: NSPoint(x: 455, y: 654))
        play.line(to: NSPoint(x: 637, y: 545))
        play.close()
        NSColor(srgbRed: 0.45, green: 0.88, blue: 0.85, alpha: 1).setFill()
        play.fill()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
