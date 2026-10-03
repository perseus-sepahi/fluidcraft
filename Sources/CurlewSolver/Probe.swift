import Foundation
import CurlewMesh

/// Point location and interpolation on cell data.
public final class CellLocator: @unchecked Sendable {
    let mesh: Mesh
    let grid: [Int: [Int32]]
    let origin: Vec3
    let h: Double

    public init(mesh: Mesh) {
        self.mesh = mesh
        let b = mesh.bounds
        let n = max(mesh.nCells, 1)
        let vol = max(b.size.x, 1e-12) * max(b.size.y, 1e-12) * max(b.size.z, 1e-12)
        h = max(cbrt(vol / Double(n)) * 2, 1e-12)
        origin = b.min
        var g: [Int: [Int32]] = [:]
        for c in 0..<mesh.nCells { g[CellLocator.key(mesh.cellCentres[c], origin, h), default: []].append(Int32(c)) }
        grid = g
    }

    static func key(_ p: Vec3, _ o: Vec3, _ h: Double) -> Int {
        let i = Int(floor((p.x - o.x) / h)) & 0x1FFFFF
        let j = Int(floor((p.y - o.y) / h)) & 0x1FFFFF
        let k = Int(floor((p.z - o.z) / h)) & 0x1FFFFF
        return (i << 42) | (j << 21) | k
    }

    /// Cell whose centre is nearest to `p`, refined by walking to the containing cell.
    public func locate(_ p: Vec3) -> Int? {
        guard mesh.nCells > 0 else { return nil }
        var best = -1, bd = Double.infinity
        var r = 0
        while best < 0 || Double(r - 1) * h < sqrt(bd) {
            for di in -r...r { for dj in -r...r { for dk in -r...r where max(abs(di), abs(dj), abs(dk)) == r {
                let q = p + Vec3(Double(di), Double(dj), Double(dk)) * h
                if let list = grid[CellLocator.key(q, origin, h)] {
                    for c in list {
                        let d = lengthSquared(mesh.cellCentres[Int(c)] - p)
                        if d < bd { bd = d; best = Int(c) }
                    }
                }
            }}}
            r += 1
            if r > 64 { break }
        }
        guard best >= 0 else { return nil }
        return walk(from: best, to: p)
    }

    /// Walk across faces towards the point until it is inside the cell (all faces see it behind them).
    public func walk(from start: Int, to p: Vec3) -> Int {
        var c = start
        for _ in 0..<64 {
            var next = -1, worst = 0.0
            for k in mesh.cellFaceRange(c) {
                let f = Int(mesh.cellFaces[k])
                var S = mesh.faceAreas[f]
                if Int(mesh.owner[f]) != c { S = -S }
                let d = dot(S, p - mesh.faceCentres[f]) / max(mesh.faceAreaMag[f], 1e-300)
                if d > worst {
                    if f < mesh.nInternalFaces {
                        worst = d
                        next = Int(mesh.owner[f]) == c ? Int(mesh.neighbour[f]) : Int(mesh.owner[f])
                    }
                }
            }
            if next < 0 { return c }
            c = next
        }
        return c
    }

    public func inside(_ c: Int, _ p: Vec3, tolerance: Double = 1e-9) -> Bool {
        for k in mesh.cellFaceRange(c) {
            let f = Int(mesh.cellFaces[k])
            var S = mesh.faceAreas[f]
            if Int(mesh.owner[f]) != c { S = -S }
            if dot(S, p - mesh.faceCentres[f]) > tolerance * mesh.faceAreaMag[f] { return false }
        }
        return true
    }
}

extension PressureBasedSolver {
    /// Sample a named field at points (gradient-reconstructed from the containing cell).
    public func sample(_ field: String, at points: [Vec3]) -> [Double] {
        guard let v = FieldCatalog.cellValues(field, self) else { return points.map { _ in .nan } }
        var bvals = FieldCatalog.boundaryValues(field, self) ?? [Double](repeating: 0, count: mesh.nBoundaryFaces)
        for bf in 0..<bvals.count where bc.kind[bf] == .empty { bvals[bf] = v[Int(mesh.owner[bf + mesh.nInternalFaces])] }
        var grad: [Vec3] = []
        Gradient.compute(geo, v, boundary: bvals, scheme: .leastSquares, into: &grad)
        let loc = locator
        return points.map { p in
            guard let c = loc.locate(p) else { return .nan }
            return v[c] + dot(grad[c], p - mesh.cellCentres[c])
        }
    }

    public var locator: CellLocator {
        if let l = _locator { return l }
        let l = CellLocator(mesh: mesh)
        _locator = l
        return l
    }
}

