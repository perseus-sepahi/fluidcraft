import Foundation
import CurlewMesh

/// Static k-d tree over points, used for nearest-wall searches.
struct KDTree {
    let points: [Vec3]
    var order: [Int32]
    struct Node { var lo: Int32; var hi: Int32; var axis: Int8; var split: Double; var left: Int32; var right: Int32 }
    var nodes: [Node] = []

    init(points: [Vec3]) {
        self.points = points
        order = Array(0..<Int32(points.count))
        if !points.isEmpty { _ = build(0, points.count) }
    }

    mutating func build(_ lo: Int, _ hi: Int) -> Int32 {
        let id = Int32(nodes.count)
        nodes.append(Node(lo: Int32(lo), hi: Int32(hi), axis: -1, split: 0, left: -1, right: -1))
        if hi - lo <= 8 { return id }
        var bmin = Vec3(repeating: .infinity), bmax = Vec3(repeating: -.infinity)
        for i in lo..<hi { let p = points[Int(order[i])]; bmin = pointwiseMin(bmin, p); bmax = pointwiseMax(bmax, p) }
        let ext = bmax - bmin
        let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        let mid = (lo + hi) / 2
        var sub = Array(order[lo..<hi])
        sub.sort { points[Int($0)][axis] < points[Int($1)][axis] }
        for i in 0..<sub.count { order[lo + i] = sub[i] }
        let split = points[Int(order[mid])][axis]
        let l = build(lo, mid), r = build(mid, hi)
        nodes[Int(id)].axis = Int8(axis); nodes[Int(id)].split = split
        nodes[Int(id)].left = l; nodes[Int(id)].right = r
        return id
    }

    /// k nearest point indices to q.
    func nearest(_ q: Vec3, k: Int) -> [Int] {
        var best: [(Double, Int)] = []
        func visit(_ n: Int32) {
            let node = nodes[Int(n)]
            if node.axis < 0 {
                for i in Int(node.lo)..<Int(node.hi) {
                    let idx = Int(order[i])
                    let d = lengthSquared(points[idx] - q)
                    if best.count < k { best.append((d, idx)); best.sort { $0.0 < $1.0 } }
                    else if d < best[k - 1].0 { best[k - 1] = (d, idx); best.sort { $0.0 < $1.0 } }
                }
                return
            }
            let diff = q[Int(node.axis)] - node.split
            let (first, second) = diff < 0 ? (node.left, node.right) : (node.right, node.left)
            visit(first)
            if best.count < k || diff * diff < best[best.count - 1].0 { visit(second) }
        }
        if !nodes.isEmpty { visit(0) }
        return best.map { $0.1 }
    }
}


enum WallDistance {
    /// Distance from p to a polygonal face (triangle fan around the face centre).
    static func distanceToFace(_ p: Vec3, _ m: Mesh, _ f: Int) -> Double {
        let r = m.faceNodeRange(f)
        let c = m.faceCentres[f]
        var best = Double.infinity
        let nodes = r.map { m.points[Int(m.faceNodes[$0])] }
        for i in 0..<nodes.count {
            best = min(best, pointTriangle(p, c, nodes[i], nodes[(i + 1) % nodes.count]))
        }
        return best
    }

    static func pointTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        // Ericson, Real-Time Collision Detection 5.1.5
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return norm(p - a) }
        let bp = p - b
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return norm(p - b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return norm(p - (a + v * ab)) }
        let cp = p - c
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return norm(p - c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return norm(p - (a + w * ac)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return norm(p - (b + w * (c - b)))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return norm(p - (a + ab * v + ac * w))
    }
}

extension PressureBasedSolver {
    /// Exact distance from each cell centre to the nearest wall face.
    func computeWallDistance() throws {
        let m = mesh
        let wallFaces = walls.map(\.face)
        guard !wallFaces.isEmpty else {
            geo.wallDistance = [Double](repeating: 1e10, count: m.nCells)
            return
        }
        let tree = KDTree(points: wallFaces.map { m.faceCentres[$0] })
        var d = [Double](repeating: 0, count: m.nCells)
        let n = m.nCells
        d.withUnsafeMutableBufferPointer { dp in
            let D = SharedPtrD(dp.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: max(1, min(64, n / 512))) { chunk in
                let chunks = max(1, min(64, n / 512))
                let lo = chunk * n / chunks, hi = (chunk + 1) * n / chunks
                for c in lo..<hi {
                    let p = m.cellCentres[c]
                    var best = Double.infinity
                    for idx in tree.nearest(p, k: 6) { best = min(best, WallDistance.distanceToFace(p, m, wallFaces[idx])) }
                    D[c] = max(best, 1e-12)
                }
            }
        }
        // wall-adjacent cells: use the wall-normal distance of their wall face
        for w in walls {
            let f = w.face
            let dn = abs(dot(m.faceAreas[f], m.faceCentres[f] - m.cellCentres[w.cell])) / max(m.faceAreaMag[f], 1e-300)
            d[w.cell] = min(d[w.cell], max(dn, 1e-12))
        }
        geo.wallDistance = d
    }
}

struct SharedPtrD: @unchecked Sendable {
    let p: UnsafeMutablePointer<Double>
    init(_ p: UnsafeMutablePointer<Double>) { self.p = p }
    subscript(i: Int) -> Double { get { p[i] } nonmutating set { p[i] = newValue } }
}
