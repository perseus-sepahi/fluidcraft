import Foundation

/// A mesh split into regions (one per group of cell zones) for multi-region solvers such as
/// OpenFOAM's chtMultiRegionFoam. Each region is a complete mesh of its own; faces between
/// two regions become a pair of interface patches `<a>_to_<b>` / `<b>_to_<a>` with the same
/// faces in the same order, and every cell and face keeps a map back to the original mesh.
public struct MeshRegion: Sendable {
    public var name: String
    public var mesh: Mesh
    /// Original cell of each region cell (ascending: the region keeps the original order).
    public var cellMap: [Int32]
    /// Original face of each region face.
    public var faceMap: [Int32]
    /// Interface patches: patch name → (neighbour region, neighbour patch).
    public var interfaces: [String: (region: String, patch: String)]
}

public enum MeshRegions {
    /// Split by region of each cell zone (zone index → region name).
    public static func split(_ m: Mesh, regionOfZone: [String]) throws -> [MeshRegion] {
        precondition(regionOfZone.count == m.cellZones.count)
        var names: [String] = []
        for r in regionOfZone where !names.contains(r) { names.append(r) }
        let cellRegion = (0..<m.nCells).map { Int32(names.firstIndex(of: regionOfZone[Int(m.cellZone[$0])])!) }
        var out: [MeshRegion] = []
        for (ri, name) in names.enumerated() {
            var local = [Int32](repeating: -1, count: m.nCells)
            var cellMap: [Int32] = []
            for c in 0..<m.nCells where cellRegion[c] == Int32(ri) { local[c] = Int32(cellMap.count); cellMap.append(Int32(c)) }
            guard !cellMap.isEmpty else { continue }
            var pointLocal = [Int32](repeating: -1, count: m.nPoints)
            var points: [Vec3] = []
            var offsets: [Int32] = [0], nodes: [Int32] = [], owner: [Int32] = [], nei: [Int32] = [], faceMap: [Int32] = []
            func addFace(_ f: Int, reversed: Bool, own: Int32, nb: Int32?) {
                var ns = Array(m.faceNodeRange(f).map { m.faceNodes[$0] })
                if reversed { ns.reverse() }
                for n in ns {
                    if pointLocal[Int(n)] < 0 { pointLocal[Int(n)] = Int32(points.count); points.append(m.points[Int(n)]) }
                    nodes.append(pointLocal[Int(n)])
                }
                offsets.append(Int32(nodes.count))
                owner.append(own)
                if let nb { nei.append(nb) }
                faceMap.append(Int32(f))
            }
            // internal faces: original order is (owner, neighbour)-sorted and the local
            // numbering is monotone, so the region stays upper-triangular
            for f in 0..<m.nInternalFaces {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                if local[P] >= 0 && local[N] >= 0 { addFace(f, reversed: false, own: local[P], nb: local[N]) }
            }
            var zones: [BoundaryZone] = []
            var interfaces: [String: (region: String, patch: String)] = [:]
            // original boundary patches
            for z in m.boundaryZones {
                let start = owner.count
                for f in z.faceRange where local[Int(m.owner[f])] >= 0 { addFace(f, reversed: false, own: local[Int(m.owner[f])], nb: nil) }
                if owner.count > start { zones.append(BoundaryZone(id: zones.count, name: z.name, kind: z.kind, start: start, count: owner.count - start)) }
            }
            // interfaces with every other region, faces in original order on both sides
            for (qi, other) in names.enumerated() where qi != ri {
                let start = owner.count
                for f in 0..<m.nInternalFaces {
                    let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                    if cellRegion[P] == Int32(ri) && cellRegion[N] == Int32(qi) { addFace(f, reversed: false, own: local[P], nb: nil) }
                    else if cellRegion[N] == Int32(ri) && cellRegion[P] == Int32(qi) { addFace(f, reversed: true, own: local[N], nb: nil) }
                }
                if owner.count > start {
                    let pname = "\(name)_to_\(other)"
                    zones.append(BoundaryZone(id: zones.count, name: pname, kind: .wall, start: start, count: owner.count - start))
                    interfaces[pname] = (other, "\(other)_to_\(name)")
                }
            }
            // cell zones of this region, renumbered
            var zoneIndex: [Int32: Int32] = [:]
            var czs: [CellZone] = []
            var cz = [Int32](repeating: 0, count: cellMap.count)
            for (i, c) in cellMap.enumerated() {
                let gz = m.cellZone[Int(c)]
                if zoneIndex[gz] == nil {
                    let src = m.cellZones[Int(gz)]
                    zoneIndex[gz] = Int32(czs.count)
                    czs.append(CellZone(id: czs.count, name: src.name, kind: src.kind, cellCount: 0))
                }
                cz[i] = zoneIndex[gz]!
                czs[Int(cz[i])].cellCount += 1
            }
            let sub = Mesh(points: points, faceNodeOffsets: offsets, faceNodes: nodes, owner: owner, neighbour: nei,
                           nCells: cellMap.count, boundaryZones: zones, cellZones: czs, cellZone: cz)
            out.append(MeshRegion(name: name, mesh: sub, cellMap: cellMap, faceMap: faceMap, interfaces: interfaces))
        }
        return out
    }
}
