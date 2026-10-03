import Foundation

public enum MeshError: Error, LocalizedError, CustomStringConvertible {
    case parse(String)
    case topology(String)
    case io(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .parse(let m): return "Mesh parse error: \(m)"
        case .topology(let m): return "Mesh topology error: \(m)"
        case .io(let m): return "Mesh I/O error: \(m)"
        case .unsupported(let m): return "Unsupported mesh feature: \(m)"
        }
    }
    public var errorDescription: String? { description }
}

/// Collects faces in arbitrary order and orientation and produces a `Mesh` that
/// satisfies the canonical layout (internal faces first, owner<neighbour, outward normals).
public struct MeshBuilder {
    public struct RawFace {
        public var nodes: [Int32]
        public var c0: Int32
        public var c1: Int32       // -1 for boundary
        public var zone: Int32     // boundary zone index for boundary faces, ignored otherwise
    }
    public struct ZoneSpec { public var name: String; public var kind: ZoneKind
        public init(name: String, kind: ZoneKind) { self.name = name; self.kind = kind } }
    public struct CellZoneSpec { public var name: String; public var kind: CellZoneKind
        public init(name: String, kind: CellZoneKind) { self.name = name; self.kind = kind } }

    public var points: [Vec3] = []
    public var faces: [RawFace] = []
    public var nCells: Int = 0
    public var zones: [ZoneSpec] = []
    public var cellZones: [CellZoneSpec] = [CellZoneSpec(name: "fluid", kind: .fluid)]
    /// Cell zone of each cell; defaults to zone 0.
    public var cellZoneOfCell: [Int32] = []
    /// Reverse Cuthill-McKee renumbering for matrix bandwidth / cache locality.
    public var renumber = true

    public init() {}

    public mutating func addZone(_ name: String, kind: ZoneKind) -> Int32 {
        if let i = zones.firstIndex(where: { $0.name == name }) { return Int32(i) }
        zones.append(ZoneSpec(name: name, kind: kind))
        return Int32(zones.count - 1)
    }

    public mutating func addFace(_ nodes: [Int32], c0: Int32, c1: Int32, zone: Int32 = -1) {
        faces.append(RawFace(nodes: nodes, c0: c0, c1: c1, zone: zone))
    }

    public func build() throws -> Mesh {
        guard nCells > 0 else { throw MeshError.topology("mesh has no cells") }
        let nPts = points.count
        for f in faces {
            guard f.nodes.count >= 3 else { throw MeshError.topology("face with \(f.nodes.count) nodes") }
            guard f.c0 >= 0 && Int(f.c0) < nCells && Int(f.c1) < nCells else {
                throw MeshError.topology("face references cell out of range")
            }
            for n in f.nodes where n < 0 || Int(n) >= nPts { throw MeshError.topology("face node \(n) out of range (\(nPts) points)") }
        }

        // Approximate cell centres (average of face-node averages) for orientation.
        var cellSum = [Vec3](repeating: .zero, count: nCells)
        var cellCnt = [Double](repeating: 0, count: nCells)
        var faceAvg = [Vec3](repeating: .zero, count: faces.count)
        for (i, f) in faces.enumerated() {
            var a = Vec3.zero
            for n in f.nodes { a += points[Int(n)] }
            a /= Double(f.nodes.count)
            faceAvg[i] = a
            cellSum[Int(f.c0)] += a; cellCnt[Int(f.c0)] += 1
            if f.c1 >= 0 { cellSum[Int(f.c1)] += a; cellCnt[Int(f.c1)] += 1 }
        }
        for c in 0..<nCells {
            guard cellCnt[c] > 0 else { throw MeshError.topology("cell \(c) has no faces") }
            cellSum[c] /= cellCnt[c]
        }

        // Renumbering (RCM) on the cell adjacency graph.
        var newID = Array(0..<Int32(nCells))
        if renumber && nCells > 2 {
            newID = MeshBuilder.reverseCuthillMcKee(nCells: nCells, faces: faces)
        }

        struct Oriented { var nodes: [Int32]; var own: Int32; var nei: Int32; var zone: Int32 }
        var inner: [Oriented] = []
        var boundary: [Oriented] = []
        inner.reserveCapacity(faces.count)
        for (i, f) in faces.enumerated() {
            var nodes = f.nodes
            let sf = MeshBuilder.areaVector(nodes, points)
            if f.c1 >= 0 {
                // Orient from c0 to c1 geometrically, then make owner the lower new id.
                let d = cellSum[Int(f.c1)] - cellSum[Int(f.c0)]
                var from = f.c0, to = f.c1
                if dot(sf, d) < 0 { nodes.reverse() }
                if newID[Int(from)] > newID[Int(to)] { swap(&from, &to); nodes.reverse() }
                inner.append(Oriented(nodes: nodes, own: newID[Int(from)], nei: newID[Int(to)], zone: -1))
            } else {
                let d = faceAvg[i] - cellSum[Int(f.c0)]
                if dot(sf, d) < 0 { nodes.reverse() }
                boundary.append(Oriented(nodes: nodes, own: newID[Int(f.c0)], nei: -1, zone: f.zone))
            }
        }
        inner.sort { $0.own != $1.own ? $0.own < $1.own : $0.nei < $1.nei }
        // Detect duplicated internal faces (same owner/neighbour pair is legal for
        // non-conformal polyhedra, but identical node sets are not).
        boundary.sort { $0.zone != $1.zone ? $0.zone < $1.zone : $0.own < $1.own }

        var offsets: [Int32] = [0]
        var nodes: [Int32] = []
        var owner: [Int32] = []
        var nei: [Int32] = []
        offsets.reserveCapacity(faces.count + 1)
        owner.reserveCapacity(faces.count)
        nei.reserveCapacity(inner.count)
        for f in inner {
            nodes.append(contentsOf: f.nodes); offsets.append(Int32(nodes.count))
            owner.append(f.own); nei.append(f.nei)
        }
        var bz: [BoundaryZone] = []
        var start = inner.count
        for (zi, z) in zones.enumerated() {
            var count = 0
            for f in boundary where f.zone == Int32(zi) {
                nodes.append(contentsOf: f.nodes); offsets.append(Int32(nodes.count))
                owner.append(f.own); count += 1
            }
            if count > 0 {
                bz.append(BoundaryZone(id: bz.count, name: z.name, kind: z.kind, start: start, count: count))
                start += count
            }
        }
        let orphan = boundary.filter { $0.zone < 0 || Int($0.zone) >= zones.count }
        if !orphan.isEmpty {
            for f in orphan { nodes.append(contentsOf: f.nodes); offsets.append(Int32(nodes.count)); owner.append(f.own) }
            bz.append(BoundaryZone(id: bz.count, name: "default-wall", kind: .wall, start: start, count: orphan.count))
        }

        var cz = [Int32](repeating: 0, count: nCells)
        if cellZoneOfCell.count == nCells {
            for c in 0..<nCells { cz[Int(newID[c])] = cellZoneOfCell[c] }
        }
        var zoneCounts = [Int](repeating: 0, count: max(cellZones.count, 1))
        for z in cz { zoneCounts[Int(z)] += 1 }
        var czOut: [CellZone] = []
        var remap = [Int32](repeating: 0, count: max(cellZones.count, 1))
        for (i, spec) in cellZones.enumerated() where zoneCounts[i] > 0 {
            remap[i] = Int32(czOut.count)
            czOut.append(CellZone(id: czOut.count, name: spec.name, kind: spec.kind, cellCount: zoneCounts[i]))
        }
        for c in 0..<nCells { cz[c] = remap[Int(cz[c])] }

        return Mesh(points: points, faceNodeOffsets: offsets, faceNodes: nodes,
                    owner: owner, neighbour: nei, nCells: nCells,
                    boundaryZones: bz, cellZones: czOut, cellZone: cz)
    }

    static func areaVector(_ nodes: [Int32], _ points: [Vec3]) -> Vec3 {
        var c = Vec3.zero
        for n in nodes { c += points[Int(n)] }
        c /= Double(nodes.count)
        var s = Vec3.zero
        for k in 0..<nodes.count {
            let p = points[Int(nodes[k])], q = points[Int(nodes[(k + 1) % nodes.count])]
            s += cross(q - p, c - p)
        }
        return 0.5 * s
    }

    /// Returns new cell id for each old cell id.
    static func reverseCuthillMcKee(nCells: Int, faces: [RawFace]) -> [Int32] {
        var deg = [Int32](repeating: 0, count: nCells + 1)
        for f in faces where f.c1 >= 0 { deg[Int(f.c0) + 1] += 1; deg[Int(f.c1) + 1] += 1 }
        for c in 0..<nCells { deg[c + 1] += deg[c] }
        var fill = deg
        var adj = [Int32](repeating: 0, count: Int(deg[nCells]))
        for f in faces where f.c1 >= 0 {
            adj[Int(fill[Int(f.c0)])] = f.c1; fill[Int(f.c0)] += 1
            adj[Int(fill[Int(f.c1)])] = f.c0; fill[Int(f.c1)] += 1
        }
        @inline(__always) func degree(_ c: Int) -> Int32 { deg[c + 1] - deg[c] }
        var order: [Int32] = []
        order.reserveCapacity(nCells)
        var visited = [Bool](repeating: false, count: nCells)
        var nbrs: [Int32] = []
        // Process every connected component, starting from a minimum-degree cell.
        var byDegree = Array(0..<nCells)
        byDegree.sort { degree($0) < degree($1) }
        var head = 0
        for seed in byDegree where !visited[seed] {
            visited[seed] = true
            order.append(Int32(seed))
            while head < order.count {
                let c = Int(order[head]); head += 1
                nbrs.removeAll(keepingCapacity: true)
                for k in Int(deg[c])..<Int(deg[c + 1]) {
                    let n = Int(adj[k])
                    if !visited[n] { visited[n] = true; nbrs.append(Int32(n)) }
                }
                nbrs.sort { degree(Int($0)) < degree(Int($1)) }
                order.append(contentsOf: nbrs)
            }
        }
        var newID = [Int32](repeating: 0, count: nCells)
        for (i, c) in order.reversed().enumerated() { newID[Int(c)] = Int32(i) }
        return newID
    }
}
