import Foundation
import CurlewMesh
import CurlewLinear

/// Precomputed discretisation geometry for a mesh.
public final class FVGeometry: @unchecked Sendable {
    public let mesh: Mesh
    public let nCells: Int
    public let nInternal: Int
    public let nFaces: Int
    /// Owner interpolation weight w: phi_f = w phi_P + (1-w) phi_N.
    public let weight: [Double]
    /// Vector from owner centre to neighbour centre (internal) or face centre (boundary).
    public let delta: [Vec3]
    /// Implicit (orthogonal) diffusion coefficient |S|^2 / (S . d) (over-relaxed decomposition).
    public let orthCoeff: [Double]
    /// Explicit non-orthogonal part T = S - orthCoeff * d.
    public let nonOrth: [Vec3]
    /// Least-squares gradient stencil vectors: grad_P += lsOwner[f] (phi_N - phi_P); grad_N += lsNeighbour[f] (phi_P - phi_N).
    public let lsOwner: [Vec3]
    public let lsNeighbour: [Vec3]
    /// Boundary faces that do not exchange anything (empty 2D planes).
    public let isEmptyFace: [Bool]
    /// Max non-orthogonality flag: skip explicit corrections on orthogonal meshes.
    public let hasNonOrthogonality: Bool
    public let pattern: SparsePattern
    public let upper: [Int32]
    public let lower: [Int32]
    /// Wall-normal distance of each cell (filled by WallDistance).
    public var wallDistance: [Double] = []
    /// For wall-adjacent cells, normal distance to the nearest wall face; for others 0.
    public var wallFaceDistance: [Double] = []

    public init(mesh m: Mesh) {
        mesh = m
        nCells = m.nCells
        nInternal = m.nInternalFaces
        nFaces = m.nFaces
        var w = [Double](repeating: 0.5, count: nFaces)
        var d = [Vec3](repeating: .zero, count: nFaces)
        var oc = [Double](repeating: 0, count: nFaces)
        var no = [Vec3](repeating: .zero, count: nFaces)
        var empty = [Bool](repeating: false, count: nFaces)
        for z in m.boundaryZones where z.kind == .empty { for f in z.faceRange { empty[f] = true } }
        var maxT = 0.0
        for f in 0..<nFaces {
            let P = Int(m.owner[f])
            let S = m.faceAreas[f]
            let dd: Vec3
            if f < nInternal {
                let N = Int(m.neighbour[f])
                dd = m.cellCentres[N] - m.cellCentres[P]
                let dP = dot(S, m.faceCentres[f] - m.cellCentres[P])
                let dN = dot(S, m.cellCentres[N] - m.faceCentres[f])
                let den = dP + dN
                w[f] = abs(den) > 1e-300 ? dN / den : 0.5
            } else {
                dd = m.faceCentres[f] - m.cellCentres[P]
                w[f] = 1
            }
            d[f] = dd
            let sd = dot(S, dd)
            // guard against degenerate faces; floor S.d at 5% of |S||d| (~87 deg)
            let sdSafe = max(sd, 0.05 * norm(S) * norm(dd), 1e-300)
            oc[f] = dot(S, S) / sdSafe
            no[f] = S - oc[f] * dd
            if !empty[f] { maxT = max(maxT, norm(no[f]) / max(norm(S), 1e-300)) }
        }
        weight = w; delta = d; orthCoeff = oc; nonOrth = no; isEmptyFace = empty
        hasNonOrthogonality = maxT > 1e-6

        // Least squares: G = sum w d d^T with w = 1/|d|^2, including boundary faces.
        var G = [SymTensor](repeating: SymTensor(), count: nCells)
        for f in 0..<nFaces {
            let dd = d[f]
            let wt = 1 / max(dot(dd, dd), 1e-300)
            G[Int(m.owner[f])].addOuter(dd, weight: wt)
            if f < nInternal { G[Int(m.neighbour[f])].addOuter(dd, weight: wt) }
        }
        var Ginv = [SymTensor](repeating: SymTensor(), count: nCells)
        for c in 0..<nCells {
            if let inv = G[c].inverse() { Ginv[c] = inv }
            else {
                // Rank-deficient stencil: regularise with a small isotropic term.
                var g = G[c]
                let s = max(g.xx + g.yy + g.zz, 1e-30) * 1e-6
                g.xx += s; g.yy += s; g.zz += s
                Ginv[c] = g.inverse() ?? SymTensor()
            }
        }
        var lo = [Vec3](repeating: .zero, count: nFaces)
        var ln = [Vec3](repeating: .zero, count: nInternal)
        for f in 0..<nFaces {
            let dd = d[f]
            let wt = 1 / max(dot(dd, dd), 1e-300)
            lo[f] = Ginv[Int(m.owner[f])].times(dd) * wt
            if f < nInternal { ln[f] = Ginv[Int(m.neighbour[f])].times(-dd) * wt }
        }
        lsOwner = lo; lsNeighbour = ln

        let (pat, up, low) = SparsePattern.fromPairs(n: nCells, owner: m.owner, neighbour: m.neighbour)
        pattern = pat; upper = up; lower = low
    }

    /// Normal distance between owner centre and boundary face (S.d/|S|).
    @inline(__always) public func normalDistance(_ f: Int) -> Double {
        max(dot(mesh.faceAreas[f], delta[f]) / max(mesh.faceAreaMag[f], 1e-300), 1e-300)
    }
}

/// Gradient reconstruction.
public enum Gradient {
    /// Least-squares (cell-based) or Green-Gauss (cell-based) gradient. `boundary`
    /// holds face values for every boundary face (index f - nInternal).
    public static func compute(_ g: FVGeometry, _ phi: [Double], boundary: [Double],
                               scheme: GradientScheme, into grad: inout [Vec3]) {
        let m = g.mesh
        if grad.count != g.nCells { grad = [Vec3](repeating: .zero, count: g.nCells) }
        for i in 0..<g.nCells { grad[i] = .zero }
        let nI = g.nInternal
        switch scheme {
        case .leastSquares:
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                let dphi = phi[N] - phi[P]
                grad[P] += g.lsOwner[f] * dphi
                grad[N] -= g.lsNeighbour[f] * dphi
            }
            for f in nI..<g.nFaces {
                let P = Int(m.owner[f])
                grad[P] += g.lsOwner[f] * (boundary[f - nI] - phi[P])
            }
        case .greenGauss:
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                let w = g.weight[f]
                let pf = w * phi[P] + (1 - w) * phi[N]
                let flux = m.faceAreas[f] * pf
                grad[P] += flux; grad[N] -= flux
            }
            for f in nI..<g.nFaces {
                let P = Int(m.owner[f])
                grad[P] += m.faceAreas[f] * (g.isEmptyFace[f] ? phi[P] : boundary[f - nI])
            }
            for c in 0..<g.nCells { grad[c] /= m.cellVolumes[c] }
        }
    }

    /// Vector-field gradient as three component gradients.
    public static func compute(_ g: FVGeometry, _ u: [Vec3], boundary: [Vec3], scheme: GradientScheme,
                               into grads: inout [[Vec3]], scratch: inout [Double], scratchB: inout [Double]) {
        if grads.count != 3 { grads = [[], [], []] }
        if scratch.count != g.nCells { scratch = [Double](repeating: 0, count: g.nCells) }
        if scratchB.count != g.nFaces - g.nInternal { scratchB = [Double](repeating: 0, count: g.nFaces - g.nInternal) }
        for c in 0..<3 {
            for i in 0..<g.nCells { scratch[i] = u[i][c] }
            for i in 0..<scratchB.count { scratchB[i] = boundary[i][c] }
            compute(g, scratch, boundary: scratchB, scheme: scheme, into: &grads[c])
        }
    }

    /// Barth-Jespersen limiter factors (0..1) per cell.
    public static func barthJespersen(_ g: FVGeometry, _ phi: [Double], boundary: [Double], grad: [Vec3]) -> [Double] {
        let m = g.mesh
        var lo = phi, hi = phi
        for f in 0..<g.nInternal {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            lo[P] = min(lo[P], phi[N]); hi[P] = max(hi[P], phi[N])
            lo[N] = min(lo[N], phi[P]); hi[N] = max(hi[N], phi[P])
        }
        for f in g.nInternal..<g.nFaces where !g.isEmptyFace[f] {
            let P = Int(m.owner[f]); let b = boundary[f - g.nInternal]
            lo[P] = min(lo[P], b); hi[P] = max(hi[P], b)
        }
        var lim = [Double](repeating: 1, count: g.nCells)
        func apply(_ c: Int, _ r: Vec3) {
            let dphi = dot(grad[c], r)
            if dphi > 1e-300 { lim[c] = min(lim[c], min(1, (hi[c] - phi[c]) / dphi)) }
            else if dphi < -1e-300 { lim[c] = min(lim[c], min(1, (lo[c] - phi[c]) / dphi)) }
        }
        for f in 0..<g.nFaces where !g.isEmptyFace[f] {
            let P = Int(m.owner[f])
            apply(P, m.faceCentres[f] - m.cellCentres[P])
            if f < g.nInternal { let N = Int(m.neighbour[f]); apply(N, m.faceCentres[f] - m.cellCentres[N]) }
        }
        return lim
    }
}
