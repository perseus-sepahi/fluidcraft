import Foundation

/// Reader for Gmsh ASCII mesh files, format 2.2 and 4.1.
///
/// Volume elements (or surface elements for 2D meshes, which are extruded into a
/// one-cell slab) become cells; physical groups on the boundary become face zones;
/// physical volume (2D: surface) groups become cell zones.
public enum GmshReader {
    public static func read(url: URL, depth2D: Double = 1) throws -> Mesh {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw MeshError.io("cannot read \(url.path): \(error.localizedDescription)") }
        return try read(data: data, depth2D: depth2D)
    }

    /// One Gmsh element reduced to its corner nodes. `type` is the linear base type
    /// (1 line, 2 tri, 3 quad, 4 tet, 5 hex, 6 prism, 7 pyramid).
    public struct Element: Sendable {
        public var type: Int
        public var nodes: [Int32]
        public var physical: Int
        public var dim: Int
        public init(type: Int, nodes: [Int32], physical: Int, dim: Int) {
            self.type = type; self.nodes = nodes; self.physical = physical; self.dim = dim
        }
    }

    /// Element-level content of a Gmsh file, before faces are assembled.
    public struct Parsed: Sendable {
        public var points: [Vec3]
        public var elements: [Element]
        /// dim -> physical tag -> name
        public var physicalNames: [Int: [Int: String]]
    }

    public static func read(data: Data, depth2D: Double = 1) throws -> Mesh {
        let p = try parse(data: data)
        return try assemble(points: p.points, elements: p.elements, physicalNames: p.physicalNames, depth: depth2D)
    }

    public static func build(_ p: Parsed, depth2D: Double = 1) throws -> Mesh {
        try assemble(points: p.points, elements: p.elements, physicalNames: p.physicalNames, depth: depth2D)
    }

    /// Corner-node count and dimension per Gmsh element type (higher-order types keep corners).
    static func info(_ type: Int) -> (dim: Int, corners: Int, base: Int, total: Int)? {
        switch type {
        case 1: return (1, 2, 1, 2)
        case 2: return (2, 3, 2, 3)
        case 3: return (2, 4, 3, 4)
        case 4: return (3, 4, 4, 4)
        case 5: return (3, 8, 5, 8)
        case 6: return (3, 6, 6, 6)
        case 7: return (3, 5, 7, 5)
        case 8: return (1, 2, 1, 3)
        case 9: return (2, 3, 2, 6)
        case 10: return (2, 4, 3, 9)
        case 11: return (3, 4, 4, 10)
        case 12: return (3, 8, 5, 27)
        case 13: return (3, 6, 6, 18)
        case 14: return (3, 5, 7, 14)
        case 15: return (0, 1, 15, 1)
        case 16: return (2, 4, 3, 8)
        case 17: return (3, 8, 5, 20)
        case 18: return (3, 6, 6, 15)
        case 19: return (3, 5, 7, 13)
        default: return nil
        }
    }

    public static func cellFaces(base: Int, _ n: [Int32]) -> [[Int32]] {
        switch base {
        case 4: return [[n[0], n[2], n[1]], [n[0], n[1], n[3]], [n[0], n[3], n[2]], [n[1], n[2], n[3]]]
        case 5: return [[n[0], n[3], n[2], n[1]], [n[4], n[5], n[6], n[7]], [n[0], n[1], n[5], n[4]],
                        [n[1], n[2], n[6], n[5]], [n[2], n[3], n[7], n[6]], [n[3], n[0], n[4], n[7]]]
        case 6: return [[n[0], n[2], n[1]], [n[3], n[4], n[5]], [n[0], n[1], n[4], n[3]],
                        [n[1], n[2], n[5], n[4]], [n[2], n[0], n[3], n[5]]]
        case 7: return [[n[0], n[3], n[2], n[1]], [n[0], n[1], n[4]], [n[1], n[2], n[4]], [n[2], n[3], n[4]], [n[3], n[0], n[4]]]
        default: return []
        }
    }

    public static func parse(data: Data) throws -> Parsed {
        var p = ByteParser(data: data)
        guard p.seek("$MeshFormat") else { throw MeshError.parse("not a Gmsh file ($MeshFormat missing)") }
        let version = try p.double()
        let fileType = try p.int()
        _ = try p.int()
        guard fileType == 0 else { throw MeshError.unsupported("binary Gmsh files; re-export as ASCII (-format msh41)") }

        var physicalNames: [Int: [Int: String]] = [:] // dim -> tag -> name
        var save = p.pos
        if p.seek("$PhysicalNames") {
            let n = try p.int()
            for _ in 0..<n {
                let dim = try p.int(), tag = try p.int()
                var name = p.line()
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                physicalNames[dim, default: [:]][tag] = name
            }
        } else { p.pos = save }

        var points: [Vec3] = []
        var nodeIndex: [Int: Int32] = [:]
        var elements: [Element] = []

        if version >= 4 {
            // Entities -> physical tags
            var entityPhysical: [Int: [Int: Int]] = [:] // dim -> entity tag -> first physical
            save = p.pos
            if p.seek("$Entities") {
                let counts = [try p.int(), try p.int(), try p.int(), try p.int()]
                for dim in 0..<4 {
                    for _ in 0..<counts[dim] {
                        let tag = try p.int()
                        let nCoord = dim == 0 ? 3 : 6
                        for _ in 0..<nCoord { _ = try p.double() }
                        let np = try p.int()
                        var first = 0
                        for k in 0..<np { let t = try p.int(); if k == 0 { first = abs(t) } }
                        if first != 0 { entityPhysical[dim, default: [:]][tag] = first }
                        if dim > 0 { let nb = try p.int(); for _ in 0..<nb { _ = try p.int() } }
                    }
                }
            } else { p.pos = save }

            guard p.seek("$Nodes") else { throw MeshError.parse("$Nodes missing") }
            let nBlocks = try p.int(), nNodes = try p.int()
            _ = try p.int(); _ = try p.int()
            points.reserveCapacity(nNodes)
            for _ in 0..<nBlocks {
                _ = try p.int(); _ = try p.int()
                let parametric = try p.int()
                let n = try p.int()
                var tags = [Int](repeating: 0, count: n)
                for i in 0..<n { tags[i] = try p.int() }
                for i in 0..<n {
                    let x = try p.double(), y = try p.double(), z = try p.double()
                    if parametric != 0 { p.skipSpace(); _ = p.line() }
                    nodeIndex[tags[i]] = Int32(points.count)
                    points.append(Vec3(x, y, z))
                }
            }
            guard p.seek("$Elements") else { throw MeshError.parse("$Elements missing") }
            let nEB = try p.int()
            _ = try p.int(); _ = try p.int(); _ = try p.int()
            for _ in 0..<nEB {
                let dim = try p.int(), etag = try p.int(), type = try p.int(), n = try p.int()
                guard let inf = info(type) else { throw MeshError.unsupported("Gmsh element type \(type)") }
                let phys = entityPhysical[dim]?[etag] ?? 0
                for _ in 0..<n {
                    _ = try p.int()
                    var nodes = [Int32](repeating: 0, count: inf.corners)
                    for k in 0..<inf.total {
                        let t = try p.int()
                        if k < inf.corners {
                            guard let idx = nodeIndex[t] else { throw MeshError.parse("element references unknown node \(t)") }
                            nodes[k] = idx
                        }
                    }
                    elements.append(Element(type: inf.base, nodes: nodes, physical: phys, dim: dim))
                }
            }
        } else {
            guard p.seek("$Nodes") else { throw MeshError.parse("$Nodes missing") }
            let n = try p.int()
            points.reserveCapacity(n)
            for _ in 0..<n {
                let tag = try p.int()
                let x = try p.double(), y = try p.double(), z = try p.double()
                nodeIndex[tag] = Int32(points.count)
                points.append(Vec3(x, y, z))
            }
            guard p.seek("$Elements") else { throw MeshError.parse("$Elements missing") }
            let ne = try p.int()
            for _ in 0..<ne {
                _ = try p.int()
                let type = try p.int()
                let ntags = try p.int()
                var phys = 0
                for k in 0..<ntags { let t = try p.int(); if k == 0 { phys = t } }
                guard let inf = info(type) else { throw MeshError.unsupported("Gmsh element type \(type)") }
                var nodes = [Int32](repeating: 0, count: inf.corners)
                for k in 0..<inf.total {
                    let t = try p.int()
                    if k < inf.corners {
                        guard let idx = nodeIndex[t] else { throw MeshError.parse("element references unknown node \(t)") }
                        nodes[k] = idx
                    }
                }
                elements.append(Element(type: inf.base, nodes: nodes, physical: phys, dim: inf.dim))
            }
        }
        return Parsed(points: points, elements: elements, physicalNames: physicalNames)
    }

    public struct FaceKey: Hashable {
        var a: Int32, b: Int32, c: Int32, d: Int32
        public init(_ nodes: [Int32]) {
            var s = nodes.sorted()
            while s.count < 4 { s.append(-1) }
            // keep -1 padding at the end so triangles and quads cannot collide
            if nodes.count == 3 { a = s[0]; b = s[1]; c = s[2]; d = -1 }
            else if nodes.count == 2 { a = s[0]; b = s[1]; c = -1; d = -1 }
            else { a = s[0]; b = s[1]; c = s[2]; d = s[3] }
        }
    }

    static func assemble(points: [Vec3], elements: [Element], physicalNames: [Int: [Int: String]], depth: Double) throws -> Mesh {
        let has3D = elements.contains { $0.dim == 3 }
        let cellDim = has3D ? 3 : 2
        guard elements.contains(where: { $0.dim == cellDim }) else { throw MeshError.parse("no cells found") }
        var b = MeshBuilder()

        // Cell zones from physical groups of cell-dimension elements
        var zoneOfPhys: [Int: Int32] = [:]
        b.cellZones = []
        var cz: [Int32] = []
        var cellsEl: [Element] = []
        for e in elements where e.dim == cellDim {
            if zoneOfPhys[e.physical] == nil {
                let name = physicalNames[cellDim]?[e.physical] ?? (e.physical == 0 ? "fluid" : "volume-\(e.physical)")
                let kind: CellZoneKind = name.lowercased().contains("solid") ? .solid : .fluid
                b.cellZones.append(MeshBuilder.CellZoneSpec(name: name, kind: kind))
                zoneOfPhys[e.physical] = Int32(b.cellZones.count - 1)
            }
            cz.append(zoneOfPhys[e.physical]!)
            cellsEl.append(e)
        }
        b.cellZoneOfCell = cz
        b.nCells = cellsEl.count

        // Boundary elements by key -> zone
        var boundaryZoneOfKey: [FaceKey: Int32] = [:]
        let bdim = cellDim - 1
        for e in elements where e.dim == bdim {
            let name = physicalNames[bdim]?[e.physical] ?? (e.physical == 0 ? "default-wall" : "boundary-\(e.physical)")
            let z = b.addZone(name, kind: ZoneKind.guess(fromName: name))
            boundaryZoneOfKey[FaceKey(e.nodes)] = z
        }

        if cellDim == 3 {
            b.points = points
            var open: [FaceKey: (nodes: [Int32], cell: Int32)] = [:]
            open.reserveCapacity(cellsEl.count * 2)
            for (ci, e) in cellsEl.enumerated() {
                for f in cellFaces(base: e.type, e.nodes) {
                    let k = FaceKey(f)
                    if let other = open.removeValue(forKey: k) {
                        b.addFace(other.nodes, c0: other.cell, c1: Int32(ci))
                    } else {
                        open[k] = (f, Int32(ci))
                    }
                }
            }
            let fallback = b.addZone("default-wall", kind: .wall)
            for (k, v) in open {
                b.addFace(v.nodes, c0: v.cell, c1: -1, zone: boundaryZoneOfKey[k] ?? fallback)
            }
            return try b.build()
        }

        // 2D: extrude
        let nN = Int32(points.count)
        b.points = points.map { Vec3($0.x, $0.y, 0) } + points.map { Vec3($0.x, $0.y, depth) }
        var open: [FaceKey: (a: Int32, b: Int32, cell: Int32)] = [:]
        let fb = b.addZone("frontAndBack", kind: .empty)
        for (ci, e) in cellsEl.enumerated() {
            let n = e.nodes
            for k in 0..<n.count {
                let a = n[k], c = n[(k + 1) % n.count]
                let key = FaceKey([a, c])
                if let other = open.removeValue(forKey: key) {
                    b.addFace([other.a, other.b, other.b + nN, other.a + nN], c0: other.cell, c1: Int32(ci))
                } else { open[key] = (a, c, Int32(ci)) }
            }
            b.addFace(n, c0: Int32(ci), c1: -1, zone: fb)
            b.addFace(n.reversed().map { $0 + nN }, c0: Int32(ci), c1: -1, zone: fb)
        }
        let fallback = b.addZone("default-wall", kind: .wall)
        for (k, v) in open {
            b.addFace([v.a, v.b, v.b + nN, v.a + nN], c0: v.cell, c1: -1, zone: boundaryZoneOfKey[k] ?? fallback)
        }
        return try b.build()
    }
}
