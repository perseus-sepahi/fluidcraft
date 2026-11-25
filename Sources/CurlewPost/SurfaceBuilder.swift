import Foundation
import simd
import CurlewMesh
import CurlewSolver

/// Surfaces that post-processing can display: boundary zones, planes and iso-surfaces.
public enum SurfaceDefinition: Codable, Sendable, Equatable, Hashable {
    case zone(String)
    /// Plane through `point` with `normal`.
    case plane(point: [Double], normal: [Double])
    case isoSurface(field: String, value: Double)
    /// The visible symmetry plane of a 2D slab (one of the empty faces).
    case twoDimensionalDomain

    public var label: String {
        switch self {
        case .zone(let n): return n
        case .plane(let p, let n): return String(format: "plane (%.3g, %.3g, %.3g) n=(%.2g, %.2g, %.2g)", p[0], p[1], p[2], n[0], n[1], n[2])
        case .isoSurface(let f, let v): return "iso \(f) = \(Quantity.format(v))"
        case .twoDimensionalDomain: return "2D domain"
        }
    }
}

public final class SurfaceBuilder: @unchecked Sendable {
    public let mesh: Mesh

    public init(mesh: Mesh) { self.mesh = mesh }

    @inline(__always) func f3(_ v: Vec3) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }

    /// Triangulate boundary faces. `nodeValues` (per mesh node) colours the vertices.
    public func zoneSurface(faces: [Int], name: String, nodeValues: [Double]?) -> SurfaceMesh {
        var s = SurfaceMesh(name: name)
        var map: [Int32: UInt32] = [:]
        map.reserveCapacity(faces.count * 2)
        var edgeNormals: [UInt64: (SIMD3<Float>, Int, Bool)] = [:]   // first normal, count, crease
        for f in faces {
            let r = mesh.faceNodeRange(f)
            let n = normalized(mesh.faceAreas[f])
            let nf = f3(n)
            var ids: [UInt32] = []
            for j in r {
                let node = mesh.faceNodes[j]
                if let id = map[node] { ids.append(id); s.normals[Int(id)] += f3(n); continue }
                let id = UInt32(s.positions.count)
                map[node] = id
                s.positions.append(f3(mesh.points[Int(node)]))
                s.normals.append(f3(n))
                s.values.append(Float(nodeValues?[Int(node)] ?? 0))
                s.vertexSource.append(Int32(f))
                ids.append(id)
            }
            for k in 1..<(ids.count - 1) { s.triangles += [ids[0], ids[k], ids[k + 1]] }
            for k in 0..<ids.count {
                let a = ids[k], b = ids[(k + 1) % ids.count]
                s.edges += [a, b]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let e = edgeNormals[key] {
                    edgeNormals[key] = (e.0, e.1 + 1, e.2 || simd_dot(e.0, nf) < 0.866)
                } else {
                    edgeNormals[key] = (nf, 1, false)
                }
            }
        }
        for (key, e) in edgeNormals where e.1 == 1 || e.2 {
            s.featureEdges += [UInt32(key >> 32), UInt32(key & 0xFFFF_FFFF)]
        }
        for i in 0..<s.normals.count { s.normals[i] = simd_normalize(s.normals[i] + SIMD3<Float>(0, 0, 1e-12)) }
        return s
    }

    /// Faces of the 2D slab on the low side of the empty axis.
    public func twoDimensionalFaces() -> [Int] {
        guard let ax = mesh.twoDimensionalAxis else { return [] }
        var out: [Int] = []
        for z in mesh.boundaryZones where z.kind == .empty {
            for f in z.faceRange where mesh.faceAreas[f][ax] < 0 { out.append(f) }
        }
        return out
    }

    /// Generic level-set slicing: polygon per cell where `phi` (per node) changes sign.
    public func slice(levelSet phi: [Double], name: String, nodeValues: [Double]?) -> SurfaceMesh {
        var s = SurfaceMesh(name: name)
        var edgePoint: [UInt64: UInt32] = [:]
        for c in 0..<mesh.nCells {
            // quick reject
            var lo = Double.infinity, hi = -Double.infinity
            for k in mesh.cellFaceRange(c) {
                let f = Int(mesh.cellFaces[k])
                for j in mesh.faceNodeRange(f) { let v = phi[Int(mesh.faceNodes[j])]; lo = min(lo, v); hi = max(hi, v) }
            }
            if lo > 0 || hi < 0 || lo == hi { continue }
            var ids: [UInt32] = []
            var pts: [SIMD3<Float>] = []
            for k in mesh.cellFaceRange(c) {
                let f = Int(mesh.cellFaces[k])
                let r = Array(mesh.faceNodeRange(f))
                for i in 0..<r.count {
                    let a = Int(mesh.faceNodes[r[i]]), b = Int(mesh.faceNodes[r[(i + 1) % r.count]])
                    let pa = phi[a], pb = phi[b]
                    if (pa < 0) == (pb < 0) { continue }
                    let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                    let id: UInt32
                    if let e = edgePoint[key] { id = e } else {
                        let t = pa / (pa - pb)
                        let p = mesh.points[a] + t * (mesh.points[b] - mesh.points[a])
                        id = UInt32(s.positions.count)
                        s.positions.append(f3(p))
                        s.normals.append(SIMD3<Float>(0, 0, 1))
                        if let nv = nodeValues { s.values.append(Float(nv[a] + t * (nv[b] - nv[a]))) } else { s.values.append(0) }
                        s.vertexSource.append(Int32(c))
                        edgePoint[key] = id
                    }
                    if !ids.contains(id) { ids.append(id); pts.append(s.positions[Int(id)]) }
                }
            }
            guard ids.count >= 3 else { continue }
            // order around the centroid in the polygon plane
            var cen = SIMD3<Float>(repeating: 0)
            for p in pts { cen += p }
            cen /= Float(pts.count)
            var nrm = SIMD3<Float>(repeating: 0)
            for i in 0..<pts.count { nrm += simd_cross(pts[i] - cen, pts[(i + 1) % pts.count] - cen) }
            if simd_length(nrm) < 1e-30 {
                nrm = simd_cross(pts[1] - pts[0], pts[2] - pts[0])
            }
            let n = simd_normalize(nrm + SIMD3<Float>(1e-20, 0, 0))
            let u = simd_normalize(pts[0] - cen + SIMD3<Float>(0, 1e-20, 0))
            let v = simd_cross(n, u)
            let order = ids.indices.sorted { i, j in
                atan2(simd_dot(pts[i] - cen, v), simd_dot(pts[i] - cen, u)) < atan2(simd_dot(pts[j] - cen, v), simd_dot(pts[j] - cen, u))
            }
            let sorted = order.map { ids[$0] }
            for k in 1..<(sorted.count - 1) { s.triangles += [sorted[0], sorted[k], sorted[k + 1]] }
            for k in 0..<sorted.count { s.edges += [sorted[k], sorted[(k + 1) % sorted.count]] }
            for id in sorted { s.normals[Int(id)] = n }
        }
        return s
    }

    public func plane(point: Vec3, normal: Vec3, nodeValues: [Double]?) -> SurfaceMesh {
        let n = normalized(normal)
        let phi = mesh.points.map { CurlewMesh.dot($0 - point, n) }
        return slice(levelSet: phi, name: "plane", nodeValues: nodeValues)
    }
}

/// Builds display surfaces for a solved case.
public final class PostProcessor: @unchecked Sendable {
    public let solver: Solution
    public let builder: SurfaceBuilder
    var nodeCache: [String: [Double]] = [:]
    var cachedIteration = -1

    public init(solver: Solution) {
        self.solver = solver
        builder = SurfaceBuilder(mesh: solver.mesh)
    }

    public var mesh: Mesh { solver.mesh }

    /// Node values of a field (cached per iteration).
    public func nodeValues(_ field: String) -> [Double]? {
        if cachedIteration != solver.state.iteration { nodeCache = [:]; cachedIteration = solver.state.iteration }
        if let v = nodeCache[field] { return v }
        guard let cell = FieldCatalog.cellValues(field, solver) else { return nil }
        let bnd = FieldCatalog.boundaryValues(field, solver)
        var b = bnd
        if var bb = b {
            for (i, k) in solver.bc.kind.enumerated() where k == .empty { bb[i] = cell[Int(mesh.owner[i + mesh.nInternalFaces])] }
            b = bb
        }
        let v = NodeInterpolation.nodeValues(mesh: mesh, cell: cell, boundary: b)
        nodeCache[field] = v
        return v
    }

    public func surface(_ def: SurfaceDefinition, field: String?) -> SurfaceMesh {
        let nv = field.flatMap { nodeValues($0) }
        switch def {
        case .zone(let name):
            guard let z = mesh.zone(named: name) else { return SurfaceMesh(name: name) }
            return builder.zoneSurface(faces: Array(z.faceRange), name: name, nodeValues: nv)
        case .twoDimensionalDomain:
            return builder.zoneSurface(faces: builder.twoDimensionalFaces(), name: "2D domain", nodeValues: nv)
        case .plane(let p, let n):
            var s = builder.plane(point: Vec3(p[0], p[1], p[2]), normal: Vec3(n[0], n[1], n[2]), nodeValues: nv)
            s.name = def.label
            return s
        case .isoSurface(let f, let value):
            guard let phi = nodeValues(f) else { return SurfaceMesh(name: def.label) }
            var s = builder.slice(levelSet: phi.map { $0 - value }, name: def.label, nodeValues: nv)
            s.name = def.label
            return s
        }
    }

    /// Mesh-only surface (no field).
    public static func meshSurface(_ mesh: Mesh, zones: [String]) -> SurfaceMesh {
        let b = SurfaceBuilder(mesh: mesh)
        if mesh.isTwoDimensional && zones.isEmpty {
            return b.zoneSurface(faces: b.twoDimensionalFaces(), name: "2D domain", nodeValues: nil)
        }
        let faces = mesh.boundaryZones.filter { (zones.isEmpty ? $0.kind != .empty : zones.contains($0.name)) }.flatMap { Array($0.faceRange) }
        return b.zoneSurface(faces: faces, name: "mesh", nodeValues: nil)
    }
}
