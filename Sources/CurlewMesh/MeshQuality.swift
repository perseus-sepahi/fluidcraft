import Foundation

/// Mesh quality report (Fluent-style metrics).
public struct MeshQualityReport: Sendable, Codable {
    public var cells: Int
    public var faces: Int
    public var nodes: Int
    public var minVolume: Double
    public var maxVolume: Double
    public var totalVolume: Double
    /// Orthogonal quality: 0 (worst) .. 1 (best), per Fluent's definition.
    public var minOrthogonalQuality: Double
    public var meanOrthogonalQuality: Double
    public var maxAspectRatio: Double
    /// Maximum angle (degrees) between face normal and owner→neighbour vector.
    public var maxNonOrthogonality: Double
    public var negativeVolumes: Int
    /// Cells with orthogonal quality below 0.01 (Fluent warns at this level).
    public var poorCells: Int
    public var bounds: BoundingBox

    public var text: String {
        var s = ""
        s += String(format: "Domain extents: x [%.6g, %.6g]  y [%.6g, %.6g]  z [%.6g, %.6g]\n",
                    bounds.min.x, bounds.max.x, bounds.min.y, bounds.max.y, bounds.min.z, bounds.max.z)
        s += String(format: "Volume statistics: min %.6e m3, max %.6e m3, total %.6e m3\n", minVolume, maxVolume, totalVolume)
        s += String(format: "Orthogonal quality: min %.6f, mean %.6f (%d cells < 0.01)\n",
                    minOrthogonalQuality, meanOrthogonalQuality, poorCells)
        s += String(format: "Maximum aspect ratio: %.4g\n", maxAspectRatio)
        s += String(format: "Maximum non-orthogonality: %.2f deg\n", maxNonOrthogonality)
        if negativeVolumes > 0 { s += "ERROR: \(negativeVolumes) cells with non-positive volume\n" }
        return s
    }
}

public enum MeshQuality {
    public static func report(_ m: Mesh) -> MeshQualityReport {
        var oq = [Double](repeating: 1, count: m.nCells)
        var dmin = [Double](repeating: .infinity, count: m.nCells)
        var dmax = [Double](repeating: 0, count: m.nCells)
        var maxNonOrth = 0.0
        for f in 0..<m.nFaces {
            let P = Int(m.owner[f])
            let S = m.faceAreas[f]
            let aMag = m.faceAreaMag[f]
            guard aMag > 0 else { continue }
            let fP = m.faceCentres[f] - m.cellCentres[P]
            let dfP = norm(fP)
            oq[P] = min(oq[P], dot(S, fP) / (aMag * max(dfP, 1e-300)))
            dmin[P] = min(dmin[P], dfP); dmax[P] = max(dmax[P], dfP)
            if f < m.nInternalFaces {
                let N = Int(m.neighbour[f])
                let d = m.cellCentres[N] - m.cellCentres[P]
                let dd = norm(d)
                let cosT = dot(S, d) / (aMag * max(dd, 1e-300))
                oq[P] = min(oq[P], cosT)
                oq[N] = min(oq[N], cosT)
                let fN = m.faceCentres[f] - m.cellCentres[N]
                let dfN = norm(fN)
                oq[N] = min(oq[N], dot(-S, fN) / (aMag * max(dfN, 1e-300)))
                dmin[N] = min(dmin[N], dfN); dmax[N] = max(dmax[N], dfN)
                maxNonOrth = max(maxNonOrth, acos(max(-1, min(1, cosT))) * 180 / .pi)
            }
        }
        var minV = Double.infinity, maxV = -Double.infinity, neg = 0, poor = 0
        var minOQ = 1.0, sumOQ = 0.0, maxAR = 1.0
        // Empty (2D) faces distort aspect ratio; ignore them for the AR statistic.
        let emptyFaces: Set<Int> = {
            var s = Set<Int>()
            for z in m.boundaryZones where z.kind == .empty { for f in z.faceRange { s.insert(f) } }
            return s
        }()
        if !emptyFaces.isEmpty {
            dmin = [Double](repeating: .infinity, count: m.nCells)
            dmax = [Double](repeating: 0, count: m.nCells)
            for f in 0..<m.nFaces where !emptyFaces.contains(f) {
                let P = Int(m.owner[f])
                let dP = norm(m.faceCentres[f] - m.cellCentres[P])
                dmin[P] = min(dmin[P], dP); dmax[P] = max(dmax[P], dP)
                if f < m.nInternalFaces {
                    let N = Int(m.neighbour[f])
                    let dN = norm(m.faceCentres[f] - m.cellCentres[N])
                    dmin[N] = min(dmin[N], dN); dmax[N] = max(dmax[N], dN)
                }
            }
        }
        for c in 0..<m.nCells {
            let v = m.cellVolumes[c]
            minV = min(minV, v); maxV = max(maxV, v)
            if v <= 1e-300 { neg += 1 }
            let q = max(0, oq[c])
            minOQ = min(minOQ, q); sumOQ += q
            if q < 0.01 { poor += 1 }
            if dmin[c] > 0 && dmin[c].isFinite { maxAR = max(maxAR, dmax[c] / dmin[c]) }
        }
        return MeshQualityReport(cells: m.nCells, faces: m.nFaces, nodes: m.nPoints,
                                 minVolume: minV, maxVolume: maxV, totalVolume: m.totalVolume,
                                 minOrthogonalQuality: minOQ, meanOrthogonalQuality: sumOQ / Double(max(m.nCells, 1)),
                                 maxAspectRatio: maxAR, maxNonOrthogonality: maxNonOrth,
                                 negativeVolumes: neg, poorCells: poor, bounds: m.bounds)
    }

    /// Per-cell orthogonal quality, for contouring.
    public static func orthogonalQuality(_ m: Mesh) -> [Double] {
        var oq = [Double](repeating: 1, count: m.nCells)
        for f in 0..<m.nFaces {
            let P = Int(m.owner[f])
            let S = m.faceAreas[f], a = m.faceAreaMag[f]
            guard a > 0 else { continue }
            let fP = m.faceCentres[f] - m.cellCentres[P]
            oq[P] = min(oq[P], dot(S, fP) / (a * max(norm(fP), 1e-300)))
            if f < m.nInternalFaces {
                let N = Int(m.neighbour[f])
                let d = m.cellCentres[N] - m.cellCentres[P]
                let c = dot(S, d) / (a * max(norm(d), 1e-300))
                oq[P] = min(oq[P], c); oq[N] = min(oq[N], c)
                let fN = m.faceCentres[f] - m.cellCentres[N]
                oq[N] = min(oq[N], dot(-S, fN) / (a * max(norm(fN), 1e-300)))
            }
        }
        return oq.map { max(0, $0) }
    }
}
