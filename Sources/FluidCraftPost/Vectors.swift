import Foundation
import simd
import FluidCraftMesh
import FluidCraftSolver

/// Line geometry for vectors and pathlines: segments (pairs) or strips, with values.
public struct LineSet: Sendable {
    public var name: String
    public var positions: [SIMD3<Float>] = []
    public var values: [Float] = []
    /// Pairs of vertex indices.
    public var segments: [UInt32] = []
    public init(name: String) { self.name = name }
    public var valueRange: ClosedRange<Float>? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return lo...max(hi, lo)
    }
}

extension PostProcessor {
    /// Velocity arrows on a surface (one per triangle-vertex sample, thinned by `skip`).
    /// Arrow length = scale * |u| / |u|max * reference length.
    public func vectors(on def: SurfaceDefinition, colorField: String = "velocity-magnitude", scale: Double = 1, skip: Int = 0,
                        inPlane: Bool = false) -> LineSet {
        var out = LineSet(name: "vectors on \(def.label)")
        let st = solver.state
        let colour = FieldCatalog.cellValues(colorField, solver)
        let m = mesh
        // sample points: cell centres for 2D/planes, face centres for zones
        var samples: [(Vec3, Int)] = []
        switch def {
        case .twoDimensionalDomain:
            let ax = m.twoDimensionalAxis ?? 2
            let zlow = m.bounds.min[ax]
            for c in 0..<m.nCells { var p = m.cellCentres[c]; p[ax] = zlow; samples.append((p, c)) }
        case .zone(let name):
            if let z = m.zone(named: name) { for f in z.faceRange { samples.append((m.faceCentres[f], Int(m.owner[f]))) } }
        case .plane, .isoSurface:
            let s = surface(def, field: nil)
            var seen = Set<Int32>()
            for (i, src) in s.vertexSource.enumerated() where !seen.contains(src) {
                seen.insert(src)
                let p = s.positions[i]
                samples.append((Vec3(Double(p.x), Double(p.y), Double(p.z)), Int(src)))
            }
        }
        if skip > 0 { samples = samples.enumerated().filter { $0.offset % (skip + 1) == 0 }.map(\.element) }
        guard !samples.isEmpty else { return out }
        var umax = 0.0
        for (_, c) in samples { umax = max(umax, FluidCraftMesh.norm(st.u[c])) }
        // reference arrow length: typical cell size
        let h = cbrt(m.totalVolume / Double(m.nCells)) * (m.isTwoDimensional ? sqrt(Double(m.nCells) * 1.0) / sqrt(Double(m.nCells)) : 1)
        var href = h
        if m.isTwoDimensional, let ax = m.twoDimensionalAxis {
            let depth = m.bounds.size[ax]
            href = sqrt(m.totalVolume / depth / Double(m.nCells))
        }
        let L = 2.0 * href * scale
        var normal: Vec3? = nil
        if case .plane(_, let n) = def, inPlane { normal = FluidCraftMesh.normalized(Vec3(n[0], n[1], n[2])) }
        if m.isTwoDimensional, let ax = m.twoDimensionalAxis { var n = Vec3.zero; n[ax] = 1; normal = n }
        for (p, c) in samples {
            var u = st.u[c]
            if let n = normal { u -= FluidCraftMesh.dot(u, n) * n }
            let mag = FluidCraftMesh.norm(u)
            guard mag > 1e-14 * max(umax, 1e-300) else { continue }
            let tip = p + u / max(umax, 1e-300) * L
            let val = Float(colour?[c] ?? mag)
            let base = UInt32(out.positions.count)
            out.positions += [f(p), f(tip)]
            out.values += [val, val]
            out.segments += [base, base + 1]
            // arrow head
            let dir = FluidCraftMesh.normalized(tip - p)
            var side = FluidCraftMesh.cross(dir, normal ?? Vec3(0, 0, 1))
            if FluidCraftMesh.norm(side) < 1e-6 { side = FluidCraftMesh.cross(dir, Vec3(0, 1, 0)) }
            side = FluidCraftMesh.normalized(side)
            let hl = 0.3 * FluidCraftMesh.norm(tip - p)
            let h1 = tip - dir * hl + side * hl * 0.45, h2 = tip - dir * hl - side * hl * 0.45
            out.positions += [f(h1), f(h2)]
            out.values += [val, val]
            out.segments += [base + 1, base + 2, base + 1, base + 3]
        }
        return out
    }

    @inline(__always) func f(_ v: Vec3) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }

    /// Pathlines (massless particle traces) released from a zone or rake, RK2 through the cell velocity field.
    public func pathlines(seeds: [Vec3], colorField: String = "velocity-magnitude", maxSteps: Int = 2000,
                          stepFactor: Double = 0.3) -> LineSet {
        var out = LineSet(name: "pathlines")
        let st = solver.state
        let m = mesh
        let loc = solver.locator
        let colour = FieldCatalog.cellValues(colorField, solver)
        var gradU: [[Vec3]] = [[], [], []]
        var scratch: [Double] = [], scratchB: [Double] = []
        Gradient.compute(solver.geo, st.u, boundary: st.bU, scheme: .leastSquares, into: &gradU, scratch: &scratch, scratchB: &scratchB)
        let twoD = m.twoDimensionalAxis
        func velocity(_ c: Int, _ p: Vec3) -> Vec3 {
            let d = p - m.cellCentres[c]
            var u = st.u[c] + Vec3(FluidCraftMesh.dot(gradU[0][c], d), FluidCraftMesh.dot(gradU[1][c], d), FluidCraftMesh.dot(gradU[2][c], d))
            if let ax = twoD { u[ax] = 0 }
            return u
        }
        for seed in seeds {
            guard var c = loc.locate(seed) else { continue }
            var p = seed
            var lastIndex = UInt32(out.positions.count)
            out.positions.append(f(p)); out.values.append(Float(colour?[c] ?? FluidCraftMesh.norm(st.u[c])))
            for _ in 0..<maxSteps {
                let h = cbrt(m.cellVolumes[c]) * (twoD != nil ? 1 : 1)
                var hh = h
                if let ax = twoD { hh = sqrt(m.cellVolumes[c] / m.bounds.size[ax]) }
                let u1 = velocity(c, p)
                let speed = FluidCraftMesh.norm(u1)
                if speed < 1e-12 { break }
                let dt = stepFactor * hh / speed
                let mid = p + 0.5 * dt * u1
                let cm = loc.walk(from: c, to: mid)
                let u2 = velocity(cm, mid)
                let np = p + dt * u2
                let nc = loc.walk(from: cm, to: np)
                if !loc.inside(nc, np, tolerance: 1e-6) { break } // left the domain
                p = np; c = nc
                let idx = UInt32(out.positions.count)
                out.positions.append(f(p)); out.values.append(Float(colour?[c] ?? FluidCraftMesh.norm(st.u[c])))
                out.segments += [lastIndex, idx]
                lastIndex = idx
            }
        }
        return out
    }

    /// Seed points: face centres of a boundary zone (every `stride`-th face), slightly inside the domain.
    public func seeds(fromZone name: String, count: Int = 40) -> [Vec3] {
        guard let z = mesh.zone(named: name), z.count > 0 else { return [] }
        let step = max(1, z.count / max(count, 1))
        var out: [Vec3] = []
        var f = z.start
        while f < z.start + z.count {
            let P = Int(mesh.owner[f])
            out.append(mesh.faceCentres[f] + 0.05 * (mesh.cellCentres[P] - mesh.faceCentres[f]))
            f += step
        }
        if let ax = mesh.twoDimensionalAxis {
            let mid = mesh.bounds.centre[ax]
            out = out.map { var p = $0; p[ax] = mid; return p }
            // collapse duplicates from front/back faces
            var unique: [Vec3] = []
            for p in out where !unique.contains(where: { FluidCraftMesh.norm($0 - p) < 1e-12 }) { unique.append(p) }
            out = unique
        }
        return out
    }

    /// Seed points along a line rake.
    public static func rake(from a: Vec3, to b: Vec3, count: Int) -> [Vec3] {
        (0..<max(count, 1)).map { a + (b - a) * (Double($0) + 0.5) / Double(max(count, 1)) }
    }

    /// Field sampled along a line (XY plot).
    public func lineSample(_ field: String, from a: Vec3, to b: Vec3, points n: Int = 200) -> [(Double, Double)] {
        var pts = (0...n).map { a + (b - a) * Double($0) / Double(n) }
        if let ax = mesh.twoDimensionalAxis { let mid = mesh.bounds.centre[ax]; pts = pts.map { var p = $0; p[ax] = mid; return p } }
        let vals = solver.sample(field, at: pts)
        let L = FluidCraftMesh.norm(b - a)
        return (0...n).compactMap { i in
            vals[i].isFinite ? (L * Double(i) / Double(n), vals[i]) : nil
        }
    }

    /// Field on a boundary zone versus a coordinate (e.g. pressure coefficient vs x on a wall).
    public func zoneSample(_ field: String, zone: String, axis: Int) -> [(Double, Double)] {
        guard let z = mesh.zone(named: zone), let v = FieldCatalog.boundaryValues(field, solver) else { return [] }
        var out: [(Double, Double)] = []
        let ax2 = mesh.twoDimensionalAxis
        for f in z.faceRange {
            if let a = ax2, mesh.faceAreas[f][a] != 0 && abs(FluidCraftMesh.normalized(mesh.faceAreas[f])[a]) > 0.9 { continue }
            out.append((mesh.faceCentres[f][axis], v[f - mesh.nInternalFaces]))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
