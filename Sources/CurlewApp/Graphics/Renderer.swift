import Foundation
import Metal
import MetalKit
import simd
import CurlewMesh
import CurlewPost

struct Uniforms {
    var mvp: simd_float4x4
    var view: simd_float4x4
    var flat: SIMD4<Float>
    var params: SIMD4<Float>   // vmin, vmax, bands, mode (0 flat, 1 colormap)
    var light: SIMD4<Float>    // direction (view space), ambient (0 = unlit)
}

/// Orbit camera.
struct Camera {
    var target = SIMD3<Float>(0, 0, 0)
    var radius: Float = 1
    var yaw: Float = -0.6
    var pitch: Float = 0.45
    var zoom: Float = 1
    var pan = SIMD2<Float>(0, 0)
    var orthographic = true
    var lockedAxis: Int? = nil   // 2D: look along this axis

    mutating func fit(_ b: BoundingBox, twoD: Int?) {
        let c = b.centre
        target = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        radius = max(Float(b.diagonal) * 0.5, 1e-6)
        if let ax = twoD {
            // radius from in-plane extents only
            var s = b.size; s[ax] = 0
            radius = max(Float(norm(s)) * 0.5, 1e-6)
        }
        zoom = 1; pan = .zero
        lockedAxis = twoD
        if twoD != nil { yaw = 0; pitch = 0 }
    }

    func basis() -> (eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        var dir: SIMD3<Float>
        var upHint = SIMD3<Float>(0, 1, 0)
        if let ax = lockedAxis {
            switch ax {
            case 0: dir = SIMD3(1, 0, 0); upHint = SIMD3(0, 0, 1)
            case 1: dir = SIMD3(0, 1, 0); upHint = SIMD3(0, 0, 1)
            default: dir = SIMD3(0, 0, 1)
            }
        } else {
            dir = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        }
        let forward = -simd_normalize(dir)
        var right = simd_cross(forward, upHint)
        if simd_length(right) < 1e-5 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let dist = radius * 3
        let centre = target + right * pan.x * radius + up * pan.y * radius
        return (centre - forward * dist, right, up, forward)
    }

    func viewMatrix() -> simd_float4x4 {
        let (eye, r, u, f) = basis()
        return simd_float4x4(rows: [
            SIMD4(r.x, r.y, r.z, -simd_dot(r, eye)),
            SIMD4(u.x, u.y, u.z, -simd_dot(u, eye)),
            SIMD4(-f.x, -f.y, -f.z, simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1)])
    }

    func projection(aspect: Float) -> simd_float4x4 {
        let near = radius * 0.01, far = radius * 10
        if orthographic {
            let h = radius * 1.1 / zoom
            let w = h * aspect
            return simd_float4x4(rows: [
                SIMD4(1 / w, 0, 0, 0),
                SIMD4(0, 1 / h, 0, 0),
                SIMD4(0, 0, -1 / (far - near), -near / (far - near)),
                SIMD4(0, 0, 0, 1)])
        }
        let fovy: Float = 0.6 / zoom
        let ys = 1 / tan(fovy * 0.5), xs = ys / aspect
        return simd_float4x4(rows: [
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, far / (near - far), far * near / (near - far)),
            SIMD4(0, 0, -1, 0)])
    }
}

final class GPUObject {
    var positions: MTLBuffer
    var normals: MTLBuffer
    var values: MTLBuffer
    var triangles: MTLBuffer?
    var triangleCount = 0
    var edges: MTLBuffer?
    var edgeCount = 0
    var segments: MTLBuffer?
    var segmentCount = 0
    var features: MTLBuffer?
    var featureCount = 0
    var flat: Bool
    init?(device: MTLDevice, surface s: SurfaceMesh, flat: Bool) {
        guard !s.positions.isEmpty,
              let p = device.makeBuffer(bytes: s.positions, length: s.positions.count * MemoryLayout<SIMD3<Float>>.stride),
              let n = device.makeBuffer(bytes: s.normals, length: s.normals.count * MemoryLayout<SIMD3<Float>>.stride) else { return nil }
        let vals = s.values.isEmpty ? [Float](repeating: 0, count: s.positions.count) : s.values
        guard let v = device.makeBuffer(bytes: vals, length: vals.count * 4) else { return nil }
        positions = p; normals = n; values = v; self.flat = flat
        if !s.triangles.isEmpty {
            triangles = device.makeBuffer(bytes: s.triangles, length: s.triangles.count * 4); triangleCount = s.triangles.count
        }
        if !s.edges.isEmpty {
            edges = device.makeBuffer(bytes: s.edges, length: s.edges.count * 4); edgeCount = s.edges.count
        }
        if !s.featureEdges.isEmpty {
            features = device.makeBuffer(bytes: s.featureEdges, length: s.featureEdges.count * 4); featureCount = s.featureEdges.count
        }
    }
    init?(device: MTLDevice, lines l: LineSet) {
        guard !l.positions.isEmpty,
              let p = device.makeBuffer(bytes: l.positions, length: l.positions.count * MemoryLayout<SIMD3<Float>>.stride),
              let v = device.makeBuffer(bytes: l.values, length: l.values.count * 4),
              !l.segments.isEmpty, let sgm = device.makeBuffer(bytes: l.segments, length: l.segments.count * 4) else { return nil }
        positions = p; normals = p; values = v; flat = false
        segments = sgm; segmentCount = l.segments.count
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipeline: MTLRenderPipelineState!
    var bgPipeline: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!
    var depthNoWrite: MTLDepthStencilState!
    var sampler: MTLSamplerState!
    var cmapTexture: MTLTexture?
    var objects: [GPUObject] = []
    var flatObjects: [GPUObject] = []
    var lineObjects: [GPUObject] = []
    var camera = Camera()
    var scene = SceneContent()
    var sceneVersion = UUID()
    var dark = false
    var showEdges = false
    var showTriad = true
    var triad: GPUObject?

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float val [[attribute(2)]]; };
    struct VOut { float4 position [[position]]; float3 nrm; float val; };
    struct U { float4x4 mvp; float4x4 view; float4 flat; float4 params; float4 light; };
    vertex VOut vmain(VIn in [[stage_in]], constant U& u [[buffer(3)]]) {
        VOut o;
        o.position = u.mvp * float4(in.pos, 1.0);
        o.nrm = (u.view * float4(in.nrm, 0.0)).xyz;
        o.val = in.val;
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], constant U& u [[buffer(3)]],
                          texture2d<float> cmap [[texture(0)]], sampler smp [[sampler(0)]]) {
        float3 c;
        if (u.params.w < 0.5) {
            c = u.flat.rgb;
        } else {
            float t = clamp((in.val - u.params.x) / max(u.params.y - u.params.x, 1e-30), 0.0, 1.0);
            if (u.params.z > 0.5) { float b = u.params.z; t = (floor(min(t, 0.99999) * b) + 0.5) / b; }
            c = cmap.sample(smp, float2(t, 0.5)).rgb;
        }
        if (u.light.w > 0.0) {
            float3 n = normalize(in.nrm);
            float d = abs(dot(n, normalize(u.light.xyz)));
            c *= (u.light.w + (1.0 - u.light.w) * d);
        }
        return float4(c, u.flat.a);
    }
    struct BOut { float4 position [[position]]; float y; };
    vertex BOut bgv(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BOut o; o.position = float4(p[vid], 0.9999, 1); o.y = p[vid].y * 0.5 + 0.5; return o;
    }
    fragment float4 bgf(BOut in [[stage_in]], constant float4* cols [[buffer(0)]]) {
        return mix(cols[0], cols[1], clamp(in.y, 0.0, 1.0));
    }
    """

    init?(view: MTKView) {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        super.init()
        view.device = d
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        do {
            let lib = try d.makeLibrary(source: Renderer.shaderSource, options: nil)
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3; vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float3; vd.attributes[1].bufferIndex = 1
            vd.attributes[2].format = .float; vd.attributes[2].bufferIndex = 2
            vd.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride
            vd.layouts[1].stride = MemoryLayout<SIMD3<Float>>.stride
            vd.layouts[2].stride = 4
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "vmain")
            pd.fragmentFunction = lib.makeFunction(name: "fmain")
            pd.vertexDescriptor = vd
            pd.rasterSampleCount = 4
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pd.colorAttachments[0].isBlendingEnabled = true
            pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pd.depthAttachmentPixelFormat = .depth32Float
            pipeline = try d.makeRenderPipelineState(descriptor: pd)
            let bd = MTLRenderPipelineDescriptor()
            bd.vertexFunction = lib.makeFunction(name: "bgv")
            bd.fragmentFunction = lib.makeFunction(name: "bgf")
            bd.rasterSampleCount = 4
            bd.colorAttachments[0].pixelFormat = .bgra8Unorm
            bd.depthAttachmentPixelFormat = .depth32Float
            bgPipeline = try d.makeRenderPipelineState(descriptor: bd)
        } catch {
            NSLog("Curlew: Metal pipeline error \(error)")
            return nil
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        depthState = d.makeDepthStencilState(descriptor: ds)
        let ds2 = MTLDepthStencilDescriptor()
        ds2.depthCompareFunction = .lessEqual
        ds2.isDepthWriteEnabled = false
        depthNoWrite = d.makeDepthStencilState(descriptor: ds2)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sampler = d.makeSamplerState(descriptor: sd)
        setColormap(.rainbow)
    }

    func setColormap(_ c: Colormap) {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        guard let t = device.makeTexture(descriptor: td) else { return }
        let table = c.table
        table.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * 4) }
        cmapTexture = t
    }

    func load(_ sc: SceneContent, refit: Bool) {
        scene = sc
        objects = sc.surfaces.compactMap { GPUObject(device: device, surface: $0, flat: false) }
        flatObjects = sc.flatSurfaces.compactMap { GPUObject(device: device, surface: $0, flat: true) }
        lineObjects = sc.lines.compactMap { GPUObject(device: device, lines: $0) }
        setColormap(sc.colormap)
        showEdges = sc.showEdges
        if refit { camera.fit(sc.bounds, twoD: sc.twoDimensionalAxis) }
        else { camera.lockedAxis = sc.twoDimensionalAxis }
        buildTriad()
    }

    func buildTriad() {
        var l = LineSet(name: "triad")
        let o = SIMD3<Float>(0, 0, 0)
        for (i, axis) in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)].enumerated() {
            let b = UInt32(l.positions.count)
            l.positions += [o, axis]
            l.values += [Float(i), Float(i)]
            l.segments += [b, b + 1]
        }
        triad = GPUObject(device: device, lines: l)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        drawScene(rpd: rpd, size: view.drawableSize, present: drawable)
    }

    func drawScene(rpd: MTLRenderPassDescriptor, size: CGSize, present drawable: MTLDrawable?) {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        // background gradient
        enc.setRenderPipelineState(bgPipeline)
        var cols: [SIMD4<Float>] = dark
            ? [SIMD4(0.10, 0.11, 0.13, 1), SIMD4(0.20, 0.22, 0.26, 1)]
            : [SIMD4(1, 1, 1, 1), SIMD4(0.80, 0.85, 0.92, 1)]
        enc.setFragmentBytes(&cols, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setFragmentSamplerState(sampler, index: 0)
        if let t = cmapTexture { enc.setFragmentTexture(t, index: 0) }
        let viewM = camera.viewMatrix()
        let mvp = camera.projection(aspect: aspect) * viewM
        let lightDir = SIMD4<Float>(0.3, 0.5, 1, 0.45)
        let range = scene.range
        func uniforms(flat: SIMD4<Float>, mode: Float, lit: Bool) -> Uniforms {
            Uniforms(mvp: mvp, view: viewM, flat: flat,
                     params: SIMD4(range.lowerBound, range.upperBound, Float(scene.bands), mode),
                     light: lit ? lightDir : SIMD4(0, 0, 1, 0))
        }
        func bind(_ o: GPUObject) {
            enc.setVertexBuffer(o.positions, offset: 0, index: 0)
            enc.setVertexBuffer(o.normals, offset: 0, index: 1)
            enc.setVertexBuffer(o.values, offset: 0, index: 2)
        }
        let lit = scene.twoDimensionalAxis == nil
        let edgeColor: SIMD4<Float> = dark ? SIMD4(0.75, 0.78, 0.82, 0.55) : SIMD4(0.15, 0.17, 0.22, 0.55)
        enc.setDepthBias(2, slopeScale: 2, clamp: 0)
        // contour surfaces
        for o in objects {
            guard let tri = o.triangles else { continue }
            bind(o)
            var u = uniforms(flat: SIMD4(1, 1, 1, 1), mode: 1, lit: lit)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: o.triangleCount, indexType: .uint32, indexBuffer: tri, indexBufferOffset: 0)
        }
        // flat (mesh / outline) surfaces
        let hasContours = !objects.isEmpty || !lineObjects.isEmpty
        let hasContoursScene = hasContours
        let outlineOnly = hasContoursScene && scene.twoDimensionalAxis == nil
        for o in flatObjects where !outlineOnly {
            guard let tri = o.triangles else { continue }
            bind(o)
            let base: SIMD4<Float> = dark ? SIMD4(0.55, 0.60, 0.68, 1) : SIMD4(0.80, 0.84, 0.90, 1)
            var col = base
            if hasContours { col.w = scene.twoDimensionalAxis != nil ? 0.25 : 0.35 }
            var u = uniforms(flat: col, mode: 0, lit: lit)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            if hasContours { enc.setDepthStencilState(depthNoWrite) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: o.triangleCount, indexType: .uint32, indexBuffer: tri, indexBufferOffset: 0)
            enc.setDepthStencilState(depthState)
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        // edges
        let edgeTargets: [GPUObject] = (showEdges ? objects : []) + (hasContours ? [] : flatObjects)
        for o in edgeTargets {
            guard let e = o.edges else { continue }
            bind(o)
            var u = uniforms(flat: edgeColor, mode: 0, lit: false)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .line, indexCount: o.edgeCount, indexType: .uint32, indexBuffer: e, indexBufferOffset: 0)
        }
        // geometry outline (feature edges) around 3D results
        if outlineOnly {
            let c: SIMD4<Float> = dark ? SIMD4(0.85, 0.87, 0.9, 0.8) : SIMD4(0.2, 0.22, 0.26, 0.8)
            for o in flatObjects {
                guard let fe = o.features else { continue }
                bind(o)
                var u = uniforms(flat: c, mode: 0, lit: false)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
                enc.drawIndexedPrimitives(type: .line, indexCount: o.featureCount, indexType: .uint32, indexBuffer: fe, indexBufferOffset: 0)
            }
        }
        // vectors / pathlines
        for o in lineObjects {
            guard let s = o.segments else { continue }
            bind(o)
            var u = uniforms(flat: SIMD4(1, 1, 1, 1), mode: 1, lit: false)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .line, indexCount: o.segmentCount, indexType: .uint32, indexBuffer: s, indexBufferOffset: 0)
        }
        // axis triad in the lower-left corner
        if showTriad, let t = triad, let seg = t.segments {
            let vpSize = min(size.width, size.height) * 0.16
            enc.setViewport(MTLViewport(originX: 8, originY: size.height - vpSize - 8, width: vpSize, height: vpSize, znear: 0, zfar: 1))
            var rot = viewM
            rot.columns.3 = SIMD4(0, 0, 0, 1)
            let ortho = simd_float4x4(rows: [SIMD4(0.8, 0, 0, 0), SIMD4(0, 0.8, 0, 0), SIMD4(0, 0, -0.4, 0.5), SIMD4(0, 0, 0, 1)])
            for i in 0..<3 {
                var c = SIMD4<Float>(0, 0, 0, 1); c[i] = 0.85
                var u = Uniforms(mvp: ortho * rot, view: rot, flat: c, params: SIMD4(0, 2, 0, 0), light: SIMD4(0, 0, 1, 0))
                bind(t)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
                enc.drawIndexedPrimitives(type: .line, indexCount: 2, indexType: .uint32, indexBuffer: seg, indexBufferOffset: i * 8)
            }
        }
        enc.endEncoding()
        if let drawable { cb.present(drawable); cb.commit() }
        else { cb.commit(); cb.waitUntilCompleted() }
    }
}
