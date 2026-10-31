import AppKit

@main enum IconGenerator {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "BleachIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supply an output directory"] ) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "BleachIcon", code: 2) }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
                NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 60, y: 60, width: 904, height: 904), xRadius: 205, yRadius: 205).fill()
                BleachIcon.drawMark(in: CGRect(x: 196, y: 196, width: 632, height: 632), color: NSColor(calibratedWhite: 0.16, alpha: 1))
                NSGraphicsContext.restoreGraphicsState()
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "BleachIcon", code: 3) }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "BleachIcon", code: Int(process.terminationStatus)) }
    }
}
