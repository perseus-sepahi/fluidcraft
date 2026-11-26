import SwiftUI
import MetalKit

/// MTKView subclass with orbit / pan / zoom mouse handling.
final class InteractiveMTKView: MTKView {
    var renderer: Renderer?
    private var lastPoint = CGPoint.zero
    private var panning = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        lastPoint = convert(e.locationInWindow, from: nil)
        panning = e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) || renderer?.camera.lockedAxis != nil
    }
    override func rightMouseDown(with e: NSEvent) { lastPoint = convert(e.locationInWindow, from: nil); panning = true }
    override func otherMouseDown(with e: NSEvent) { lastPoint = convert(e.locationInWindow, from: nil); panning = true }

    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func otherMouseDragged(with e: NSEvent) { drag(e) }

    private func drag(_ e: NSEvent) {
        guard let r = renderer else { return }
        let p = convert(e.locationInWindow, from: nil)
        let dx = Float(p.x - lastPoint.x), dy = Float(p.y - lastPoint.y)
        lastPoint = p
        if panning {
            let scale = 2.2 / Float(max(bounds.height, 1)) / r.camera.zoom
            r.camera.pan.x -= dx * scale
            r.camera.pan.y -= dy * scale
        } else {
            r.camera.yaw -= dx * 0.008
            r.camera.pitch = max(-1.55, min(1.55, r.camera.pitch - dy * 0.008))
        }
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
        let d = Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1)
        r.camera.zoom = max(0.02, min(500, r.camera.zoom * exp(d)))
        needsDisplay = true
    }
    override func magnify(with e: NSEvent) {
        guard let r = renderer else { return }
        r.camera.zoom = max(0.02, min(500, r.camera.zoom * Float(1 + e.magnification)))
        needsDisplay = true
    }
}

enum ViewPreset: String, CaseIterable, Identifiable {
    case fit = "Fit", front = "+Z", back = "-Z", top = "+Y", bottom = "-Y", right = "+X", left = "-X", iso = "Iso"
    var id: String { rawValue }
}

final class ViewController: ObservableObject {
    weak var view: InteractiveMTKView?
    var renderer: Renderer? { view?.renderer }
    func apply(_ p: ViewPreset) {
        guard let r = renderer else { return }
        switch p {
        case .fit: r.camera.fit(r.scene.bounds, twoD: r.scene.twoDimensionalAxis)
        case .front: r.camera.yaw = 0; r.camera.pitch = 0
        case .back: r.camera.yaw = .pi; r.camera.pitch = 0
        case .top: r.camera.yaw = 0; r.camera.pitch = 1.5707
        case .bottom: r.camera.yaw = 0; r.camera.pitch = -1.5707
        case .right: r.camera.yaw = .pi / 2; r.camera.pitch = 0
        case .left: r.camera.yaw = -.pi / 2; r.camera.pitch = 0
        case .iso: r.camera.yaw = -0.6; r.camera.pitch = 0.45
        }
        if p != .fit { r.camera.pan = .zero }
        view?.needsDisplay = true
    }
    func toggleProjection() {
        guard let r = renderer else { return }
        r.camera.orthographic.toggle()
        view?.needsDisplay = true
    }
    /// Render the current view to a PNG.
    func snapshot(to url: URL, scale: CGFloat = 2) throws {
        guard let v = view, let r = v.renderer else { return }
        let w = Int(v.drawableSize.width), h = Int(v.drawableSize.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let colorTex = r.device.makeTexture(descriptor: td) else { return }
        let ms = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        ms.textureType = .type2DMultisample; ms.sampleCount = 4; ms.usage = .renderTarget; ms.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.textureType = .type2DMultisample; dd.sampleCount = 4; dd.usage = .renderTarget; dd.storageMode = .private
        guard let msTex = r.device.makeTexture(descriptor: ms), let depth = r.device.makeTexture(descriptor: dd) else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = msTex
        rpd.colorAttachments[0].resolveTexture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.loadAction = .clear
        r.drawScene(rpd: rpd, size: CGSize(width: w, height: h), present: nil)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        colorTex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA -> RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let annotated = Legend.composite(img, scene: r.scene, dark: r.dark) ?? img
        let bmp = NSBitmapImageRep(cgImage: annotated)
        try bmp.representation(using: .png, properties: [:])?.write(to: url)
    }
}

struct MetalView: NSViewRepresentable {
    var scene: SceneContent
    var resetToken: Int
    var dark: Bool
    var controller: ViewController

    final class Coordinator { var version: UUID? = nil; var reset = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let v = InteractiveMTKView()
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        if let r = Renderer(view: v) {
            v.renderer = r
            v.delegate = r
        }
        controller.view = v
        return v
    }

    func updateNSView(_ v: InteractiveMTKView, context: Context) {
        guard let r = v.renderer else { return }
        r.dark = dark
        if context.coordinator.version != scene.version {
            let refit = context.coordinator.reset != resetToken || context.coordinator.version == nil
            r.load(scene, refit: refit)
            context.coordinator.version = scene.version
            context.coordinator.reset = resetToken
        } else if context.coordinator.reset != resetToken {
            r.camera.fit(r.scene.bounds, twoD: r.scene.twoDimensionalAxis)
            context.coordinator.reset = resetToken
        }
        controller.view = v
        v.needsDisplay = true
    }
}
