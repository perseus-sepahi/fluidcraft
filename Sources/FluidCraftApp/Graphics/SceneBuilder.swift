import Foundation
import simd
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftPost

/// GPU-ready geometry for the graphics window.
struct SceneContent {
    var surfaces: [SurfaceMesh] = []
    /// Surfaces drawn in a flat colour (mesh display, outline context).
    var flatSurfaces: [SurfaceMesh] = []
    var lines: [LineSet] = []
    var showEdges = false
    var colorField: String? = nil
    var range: ClosedRange<Float> = 0...1
    var colormap: Colormap = .rainbow
    var bands = 0
    var bounds = BoundingBox(min: .zero, max: Vec3(1, 1, 1))
    var twoDimensionalAxis: Int? = nil
    var version = UUID()
    var title = ""
}

enum SceneBuilder {
    static func meshScene(mesh: Mesh, settings: DisplaySettings) -> SceneContent {
        var sc = SceneContent()
        let zones = settings.surfaces.filter { s in mesh.boundaryZones.contains { $0.name == s } }
        var s = PostProcessor.meshSurface(mesh, zones: zones)
        s.name = "mesh"
        sc.flatSurfaces = [s]
        sc.showEdges = true
        sc.bounds = mesh.bounds
        sc.twoDimensionalAxis = mesh.twoDimensionalAxis
        sc.title = "Mesh — \(mesh.nCells) cells"
        return sc
    }

    static func definition(_ name: String, mesh: Mesh, named: [NamedSurface]) -> SurfaceDefinition {
        if name == "2D domain" { return .twoDimensionalDomain }
        if let s = named.first(where: { $0.name == name }) { return s.definition }
        return .zone(name)
    }

    /// Default surfaces when the user selected none: the 2D domain, or all non-empty walls for 3D.
    static func defaultSurfaces(_ mesh: Mesh) -> [SurfaceDefinition] {
        if mesh.isTwoDimensional { return [.twoDimensionalDomain] }
        return mesh.boundaryZones.filter { $0.kind == .wall }.map { .zone($0.name) }
    }

    static func build(post: PostProcessor, mesh: Mesh, settings: DisplaySettings, named: [NamedSurface]) -> SceneContent {
        var sc = SceneContent()
        sc.bounds = mesh.bounds
        sc.twoDimensionalAxis = mesh.twoDimensionalAxis
        sc.colormap = settings.colormap
        sc.bands = settings.bands
        sc.showEdges = settings.showEdges
        let defs = settings.surfaces.isEmpty ? defaultSurfaces(mesh) : settings.surfaces.map { definition($0, mesh: mesh, named: named) }
        switch settings.mode {
        case .mesh:
            return meshScene(mesh: mesh, settings: settings)
        case .contours:
            sc.colorField = settings.field
            sc.surfaces = defs.map { post.surface($0, field: settings.field) }.filter { !$0.isEmpty }
            sc.title = "Contours of \(settings.field)"
        case .vectors:
            sc.colorField = "velocity-magnitude"
            sc.lines = defs.map { post.vectors(on: $0, colorField: settings.field, scale: settings.vectorScale, skip: settings.vectorSkip) }
            sc.title = "Velocity vectors coloured by \(settings.field)"
            sc.colorField = settings.field
        case .pathlines:
            let seedZone = settings.pathlineSeeds.isEmpty ? (mesh.boundaryZones.first { $0.kind == .velocityInlet }?.name ?? mesh.boundaryZones.first?.name ?? "") : settings.pathlineSeeds
            let seeds = post.seeds(fromZone: seedZone, count: settings.pathlineCount)
            sc.lines = [post.pathlines(seeds: seeds, colorField: settings.field, maxSteps: settings.pathlineSteps)]
            sc.colorField = settings.field
            sc.title = "Pathlines from \(seedZone) coloured by \(settings.field)"
        }
        // context outline: walls drawn flat & translucent edges
        if settings.showOutline && (settings.mode != .contours || !mesh.isTwoDimensional) {
            // 3D: all boundaries (drawn as feature edges); 2D: the domain (drawn as a translucent backdrop)
            var outline = mesh.isTwoDimensional ? PostProcessor.meshSurface(mesh, zones: [])
                : PostProcessor.meshSurface(mesh, zones: mesh.boundaryZones.filter { $0.kind != .empty }.map(\.name))
            outline.name = "outline"
            if !outline.isEmpty { sc.flatSurfaces = [outline] }
        }
        // range
        var lo = Float.infinity, hi = -Float.infinity
        for s in sc.surfaces { if let r = s.valueRange { lo = min(lo, r.lowerBound); hi = max(hi, r.upperBound) } }
        for l in sc.lines { if let r = l.valueRange { lo = min(lo, r.lowerBound); hi = max(hi, r.upperBound) } }
        if settings.autoRange {
            if lo.isFinite && hi.isFinite { sc.range = lo...max(hi, lo + max(abs(lo), 1) * 1e-6) }
        } else {
            sc.range = Float(settings.minValue)...Float(max(settings.maxValue, settings.minValue + 1e-12))
        }
        return sc
    }
}
