// Draws the Curlew app icon (1024x1024): streamlines curling around a cylinder
// into a vortex wake, coloured with the solver's rainbow field map.
// Usage: swift Scripts/make-icon.swift Assets/AppIcon-1024.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)

// macOS icon grid: content square 824 px centred, corner radius ~185
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.18, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// background gradient
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1),
                                               CGColor(red: 0.07, green: 0.20, blue: 0.33, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: inset), end: CGPoint(x: 0, y: S - inset), options: [])

func rainbow(_ t: CGFloat) -> CGColor {
    let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.15, 0.35, 1), (0, 0.9, 1), (0.2, 1, 0.35), (1, 0.92, 0.1), (1, 0.25, 0.15)]
    let x = max(0, min(1, t)) * CGFloat(stops.count - 1)
    let k = min(Int(x), stops.count - 2)
    let f = x - CGFloat(k)
    let a = stops[k], b = stops[k + 1]
    return CGColor(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
}

// Potential flow around a cylinder plus a decaying wake vortex street.
let cx: CGFloat = 400, cy: CGFloat = 512, R: CGFloat = 78
func velocity(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
    let dx = x - cx, dy = y - cy
    let r2 = dx * dx + dy * dy
    let R2 = R * R
    // uniform flow + doublet
    var u = 1 - R2 * (dx * dx - dy * dy) / (r2 * r2)
    var v = -R2 * (2 * dx * dy) / (r2 * r2)
    // alternating wake vortices
    let vortices: [(CGFloat, CGFloat, CGFloat)] = [(560, 560, 1.0), (680, 455, -0.9), (800, 565, 0.75), (900, 465, -0.6)]
    for (vx, vy, g) in vortices {
        let ex = x - vx, ey = y - vy
        let d2 = ex * ex + ey * ey + 900
        u += -g * 55 * ey / d2
        v += g * 55 * ex / d2
    }
    return (u, v)
}

ctx.setLineCap(.round)
let lines = 15
for i in 0..<lines {
    let y0 = cy + (CGFloat(i) - CGFloat(lines - 1) / 2) * 38
    var x = inset + 10, y = y0
    var pts: [CGPoint] = []
    for _ in 0..<1400 {
        let dx = x - cx, dy = y - cy
        if dx * dx + dy * dy < R * R * 1.02 { break }
        pts.append(CGPoint(x: x, y: y))
        let (u, v) = velocity(x, y)
        let m = max(sqrt(u * u + v * v), 1e-6)
        x += 1.6 * u / m; y += 1.6 * v / m
        if x > S - inset - 10 || y < inset || y > S - inset { break }
    }
    guard pts.count > 2 else { continue }
    // draw in short segments coloured by speed
    for k in stride(from: 1, to: pts.count, by: 4) {
        let a = pts[k - 1], b = pts[min(k + 3, pts.count - 1)]
        let (u, v) = velocity(a.x, a.y)
        let speed = sqrt(u * u + v * v)
        ctx.setStrokeColor(rainbow((speed - 0.35) / 1.4))
        ctx.setLineWidth(9)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
}

// cylinder
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
let cyl = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1),
                                                CGColor(red: 0.62, green: 0.68, blue: 0.78, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.addEllipse(in: CGRect(x: cx - R, y: cy - R, width: 2 * R, height: 2 * R))
ctx.clip()
ctx.drawLinearGradient(cyl, start: CGPoint(x: cx - R, y: cy + R), end: CGPoint(x: cx + R, y: cy - R), options: [])
ctx.restoreGState()

// subtle top highlight
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let hl = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.10), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: S - inset), end: CGPoint(x: 0, y: S * 0.55), options: [])
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
