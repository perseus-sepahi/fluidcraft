import Foundation
import FluidCraftMesh
import FluidCraftSolver

/// Triangulated display surface with per-vertex scalar values.
public struct SurfaceMesh: Sendable {
    public var name: String
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var values: [Float] = []
    public var triangles: [UInt32] = []
    /// Polygon outline segments (pairs of vertex indices) for mesh-edge display.
    public var edges: [UInt32] = []
    /// Feature edges only (open boundaries and creases sharper than ~30°) for outline display.
    public var featureEdges: [UInt32] = []
    /// Source cell (cut surfaces) or face (zone surfaces) per vertex, for probing.
    public var vertexSource: [Int32] = []
    public init(name: String) { self.name = name }
    public var isEmpty: Bool { triangles.isEmpty }

    public var bounds: BoundingBox {
        var b = BoundingBox.empty
        for p in positions { b.include(Vec3(Double(p.x), Double(p.y), Double(p.z))) }
        return b
    }

    public var valueRange: ClosedRange<Float>? {
        guard let lo = values.min(), let hi = values.max(), lo.isFinite, hi.isFinite else { return nil }
        return lo...max(hi, lo)
    }

    /// Area-weighted average of the vertex values (for surface reports on cut planes).
    public func areaAverage() -> (average: Double, area: Double) {
        var num = 0.0, den = 0.0
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let a = positions[Int(triangles[t])], b = positions[Int(triangles[t + 1])], c = positions[Int(triangles[t + 2])]
            let area = Double(simd_length(simd_cross(b - a, c - a))) * 0.5
            let v = (Double(values[Int(triangles[t])]) + Double(values[Int(triangles[t + 1])]) + Double(values[Int(triangles[t + 2])])) / 3
            num += v * area; den += area
        }
        return (den > 0 ? num / den : 0, den)
    }
}

import simd

/// Cell-to-node interpolation (inverse-distance weighting; boundary nodes use face values).
public enum NodeInterpolation {
    public static func nodeValues(mesh m: Mesh, cell: [Double], boundary: [Double]?, emptyIsCell: [Bool]? = nil) -> [Double] {
        var num = [Double](repeating: 0, count: m.nPoints)
        var den = [Double](repeating: 0, count: m.nPoints)
        var bnum = [Double](repeating: 0, count: m.nPoints)
        var bden = [Double](repeating: 0, count: m.nPoints)
        // cell contributions via faces (each cell touches its nodes through its faces)
        var seen = [Int32](repeating: -1, count: m.nPoints)
        for c in 0..<m.nCells {
            let cc = m.cellCentres[c]
            for k in m.cellFaceRange(c) {
                let f = Int(m.cellFaces[k])
                for j in m.faceNodeRange(f) {
                    let n = Int(m.faceNodes[j])
                    if seen[n] == Int32(c) { continue }
                    seen[n] = Int32(c)
                    let w = 1 / max(norm(m.points[n] - cc), 1e-30)
                    num[n] += w * cell[c]; den[n] += w
                }
            }
        }
        if let boundary {
            for z in m.boundaryZones where z.kind != .empty {
                for f in z.faceRange {
                    let v = boundary[f - m.nInternalFaces]
                    let fc = m.faceCentres[f]
                    for j in m.faceNodeRange(f) {
                        let n = Int(m.faceNodes[j])
                        let w = 1 / max(norm(m.points[n] - fc), 1e-30)
                        bnum[n] += w * v; bden[n] += w
                    }
                }
            }
        }
        var out = [Double](repeating: 0, count: m.nPoints)
        for n in 0..<m.nPoints {
            if bden[n] > 0 { out[n] = bnum[n] / bden[n] }
            else if den[n] > 0 { out[n] = num[n] / den[n] }
        }
        return out
    }
}
