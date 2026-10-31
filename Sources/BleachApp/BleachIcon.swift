import AppKit
import SwiftUI

/// A capped bleach jug with a shoulder handle and a clean-label sparkle.
/// The same vector geometry serves the native sidebar, Dock and exported icon.
struct BleachMark: Shape {
    // The closed bottle/handle geometry carries more ink than its siblings;
    // use a lighter stroke to match their perceived weight.
    static let strokeWidth: CGFloat = 1.25

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height) }
        // Offset cap and narrow neck distinguish a jug from a spray bottle.
        path.addRoundedRect(in: CGRect(x: point(5.7, 2).x, y: point(5.7, 2).y,
            width: rect.width * 6.4 / 24, height: rect.height * 2.7 / 24),
            cornerSize: CGSize(width: rect.width * 0.65 / 24, height: rect.height * 0.65 / 24))
        path.move(to: point(6.7, 4.7))
        path.addLine(to: point(6.7, 6.3))
        path.addQuadCurve(to: point(6.1, 7.6), control: point(6.7, 7))
        path.addLine(to: point(4.7, 9.2))
        path.addQuadCurve(to: point(3.9, 11.6), control: point(3.9, 10.2))
        path.addLine(to: point(3.9, 19.9))
        path.addQuadCurve(to: point(5.8, 21.8), control: point(3.9, 21.8))
        path.addLine(to: point(18.2, 21.8))
        path.addQuadCurve(to: point(20.1, 19.9), control: point(20.1, 21.8))
        path.addLine(to: point(20.1, 12.5))
        path.addQuadCurve(to: point(18.6, 9.8), control: point(20.1, 11))
        path.addLine(to: point(13.2, 6.2))
        path.addQuadCurve(to: point(11.1, 5.6), control: point(12.2, 5.6))
        path.addLine(to: point(11.1, 4.7))

        // A generous handle opening remains legible at Dock/sidebar sizes.
        path.move(to: point(12.9, 9.5))
        path.addQuadCurve(to: point(12.2, 10.1), control: point(12.2, 9))
        path.addLine(to: point(12.2, 11.4))
        path.addQuadCurve(to: point(13, 12.2), control: point(12.2, 12.2))
        path.addLine(to: point(16.1, 12.2))
        path.addQuadCurve(to: point(16.5, 11.3), control: point(17.1, 12.2))
        path.addLine(to: point(13.2, 9.6))
        path.closeSubpath()

        // A single label symbol avoids tiny lettering and generic hazard marks.
        path.move(to: point(11.8, 14.7))
        path.addQuadCurve(to: point(14.4, 17.3), control: point(12.3, 16.8))
        path.addQuadCurve(to: point(11.8, 19.9), control: point(12.3, 17.8))
        path.addQuadCurve(to: point(9.2, 17.3), control: point(11.3, 17.8))
        path.addQuadCurve(to: point(11.8, 14.7), control: point(11.3, 16.8))
        path.closeSubpath()
        return path
    }
}

enum BleachIcon {
    @MainActor static func drawMark(in rect: CGRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.maxY)
        transform.scaleX(by: rect.width / 24, yBy: -rect.height / 24)
        transform.concat()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(BleachMark().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).cgPath)
        context.setLineWidth(BleachMark.strokeWidth); context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor); context.strokePath()
    }
    @MainActor static func image(size: CGFloat = 256) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: false) { bounds in
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: size * 60 / 1024, dy: size * 60 / 1024), xRadius: size * 205 / 1024, yRadius: size * 205 / 1024).fill()
            drawMark(in: bounds.insetBy(dx: size * 196 / 1024, dy: size * 196 / 1024), color: NSColor(calibratedWhite: 0.16, alpha: 1))
            return true
        }
    }
}
