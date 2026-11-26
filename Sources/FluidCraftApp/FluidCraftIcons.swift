import SwiftUI
import AppKit

/// FluidCraft's own symbols, drawn in code on a 64-unit grid (the same drawing as
/// Docs/ai-icon-brain.html, option H) and used like SF Symbols: template images that take
/// the label's tint. A symbol name starting with "fluidcraft." refers to one of these.
enum FluidCraftIcons {
    static let aiName = "fluidcraft.ai"

    /// AI: the left half a brain with folds, the right half a network of nodes and links.
    static let ai: NSImage = template(size: 20) { ctx in
        func path(_ build: (NSBezierPath) -> Void, width: CGFloat, alpha: CGFloat = 1, dash: [CGFloat]? = nil) {
            let p = NSBezierPath()
            build(p)
            p.lineWidth = width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
            NSColor.black.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        // brain outline, left half
        path({ p in
            p.move(to: pt(32, 7.5))
            p.curve(to: pt(25, 10), controlPoint1: pt(29, 6.2), controlPoint2: pt(26.5, 7.6))
            p.curve(to: pt(12, 19), controlPoint1: pt(19, 8), controlPoint2: pt(12, 12))
            p.curve(to: pt(9, 33), controlPoint1: pt(6, 21), controlPoint2: pt(5, 29))
            p.curve(to: pt(20, 46), controlPoint1: pt(7, 40), controlPoint2: pt(12, 46))
            p.curve(to: pt(32, 48), controlPoint1: pt(22, 49.5), controlPoint2: pt(28, 50.5))
        }, width: 3.6)
        // folds
        path({ p in
            p.move(to: pt(17, 21)); p.curve(to: pt(26, 22.5), controlPoint1: pt(20, 23), controlPoint2: pt(23, 20))
            p.move(to: pt(12.5, 31)); p.curve(to: pt(24, 31.5), controlPoint1: pt(17, 29), controlPoint2: pt(19, 34))
            p.move(to: pt(17.5, 40)); p.curve(to: pt(27.5, 39.5), controlPoint1: pt(21, 38), controlPoint2: pt(24, 42))
            p.move(to: pt(27, 13)); p.curve(to: pt(27, 24), controlPoint1: pt(25, 17), controlPoint2: pt(29, 19))
        }, width: 2.6)
        // midline
        path({ p in p.move(to: pt(32, 6)); p.line(to: pt(32, 50)) }, width: 1.8, alpha: 0.6, dash: [2.5, 3.5])
        // the network half
        let nodes: [NSPoint] = [pt(38, 8.5), pt(48, 11), pt(54, 20), pt(55, 31), pt(50, 41), pt(40, 47), pt(40, 21), pt(45, 30), pt(38, 37)]
        let links = [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (0, 6), (1, 6), (6, 7), (2, 7), (3, 7), (7, 8), (4, 8), (5, 8), (6, 8)]
        path({ p in for (a, b) in links { p.move(to: nodes[a]); p.line(to: nodes[b]) } }, width: 1.9, alpha: 0.8)
        NSColor.black.setFill()
        for n in nodes { NSBezierPath(ovalIn: NSRect(x: n.x - 2.8, y: n.y - 2.8, width: 5.6, height: 5.6)).fill() }
    }

    /// A template image of `size` points, drawn on the 64-unit grid (y down, like SVG).
    static func template(size: CGFloat, draw: @escaping (CGContext) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.scaleBy(x: rect.width / 64, y: rect.height / 64)
            draw(ctx)
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "AI"
        return img
    }

    static func image(_ name: String) -> Image {
        name == aiName ? Image(nsImage: ai) : Image(systemName: name)
    }
}

/// A label whose icon may be one of FluidCraft's own symbols.
struct SymbolLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        Label { Text(title) } icon: { FluidCraftIcons.image(symbol) }
    }
}
