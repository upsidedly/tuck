import AppKit

enum TuckIcon {
    // Snap's sibling: the same rounded strokes, ink, and inset icon geometry.
    static func drawMark(in rect: CGRect, color: NSColor, revealed: Bool = false) {
        let unit = rect.width / 100
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 7 * unit
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(13, 78)); path.line(to: point(87, 78))
        path.move(to: point(13, 22)); path.line(to: point(87, 22))
        if revealed {
            path.move(to: point(57, 63)); path.line(to: point(72, 50)); path.line(to: point(57, 37))
            path.move(to: point(21, 50)); path.line(to: point(43, 50))
        } else {
            path.move(to: point(43, 63)); path.line(to: point(28, 50)); path.line(to: point(43, 37))
            path.move(to: point(57, 50)); path.line(to: point(79, 50))
        }
        path.stroke()
    }

    @MainActor static func menuBarImage(revealed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: 0.5, dy: 0.5), color: .black, revealed: revealed)
            return true
        }
        image.isTemplate = true
        return image
    }

    @MainActor static func caretImage(pocketOpen: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: pocketOpen ? "chevron.down" : "chevron.left",
                            accessibilityDescription: pocketOpen ? "Close Pocket" : "Open Pocket")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        image?.isTemplate = true
        return image
    }
}
