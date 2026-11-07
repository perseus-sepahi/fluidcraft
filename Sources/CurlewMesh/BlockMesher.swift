import Foundation

/// One graded segment of a block-mesh axis.
public struct AxisSegment: Codable, Sendable, Equatable {
    /// Coordinate where the segment ends (it starts where the previous one ended).
    public var end: Double
    public var cells: Int
    /// Ratio of last to first cell size within the segment (1 = uniform).
    public var grading: Double
    public init(end: Double, cells: Int, grading: Double = 1) {
        self.end = end; self.cells = cells; self.grading = grading
    }
}

public struct BlockAxis: Codable, Sendable, Equatable {
    public var start: Double
    public var segments: [AxisSegment]
    public init(start: Double, segments: [AxisSegment]) { self.start = start; self.segments = segments }
    public init(from a: Double, to b: Double, cells: Int, grading: Double = 1) {
        self.init(start: a, segments: [AxisSegment(end: b, cells: cells, grading: grading)])
    }
    /// Node coordinates along the axis.
    public func nodes() -> [Double] {
        var out = [start]
        var x0 = start
        for s in segments {
            let n = max(s.cells, 1)
            let L = s.end - x0
            if abs(s.grading - 1) < 1e-12 || n == 1 {
                for i in 1...n { out.append(x0 + L * Double(i) / Double(n)) }
            } else {
                let q = pow(s.grading, 1 / Double(n - 1))
                let h0 = L * (q - 1) / (pow(q, Double(n)) - 1)
                var x = x0, h = h0
                for i in 1...n {
                    x += h; h *= q
                    out.append(i == n ? s.end : x)
                }
            }
            x0 = s.end
        }
        return out
    }
}

/// Rule that renames/retypes boundary faces whose centres fall inside a box,
/// optionally only those facing a given direction.
public struct PatchRule: Codable, Sendable, Equatable {
    public var name: String
    public var kind: ZoneKind
    public var boxMin: [Double]
    public var boxMax: [Double]
    /// Optional outward normal direction (e.g. [0,1,0]); faces must align within ~25°.
    public var normal: [Double]?
    public init(name: String, kind: ZoneKind, boxMin: [Double], boxMax: [Double], normal: [Double]? = nil) {
        self.name = name; self.kind = kind; self.boxMin = boxMin; self.boxMax = boxMax; self.normal = normal
    }
    func matches(centre c: Vec3, normal n: Vec3) -> Bool {
        let eps = 1e-9
        for a in 0..<3 where c[a] < boxMin[a] - eps || c[a] > boxMax[a] + eps { return false }
        if let d = normal, d.count == 3 {
            let dv = normalized(Vec3(d[0], d[1], d[2]))
            if dot(normalized(n), dv) < 0.9 { return false }
        }
        return true
    }
}

/// Structured multi-block Cartesian mesher with rectangular obstacle masks.
///
/// Domain sides are named `x-min`, `x-max`, `y-min`, `y-max`, `z-min`, `z-max`
/// (2D slabs call the z sides `frontAndBack`), masked regions produce `obstacle`
/// walls, and `PatchRule`s override names and types afterwards.
public struct BlockMeshSpec: Codable, Sendable, Equatable {
    public var x: BlockAxis
    public var y: BlockAxis
    /// nil makes a 2D one-cell slab of thickness `depth`.
    public var z: BlockAxis?
    public var depth: Double
    /// Boxes [xmin,ymin,zmin,xmax,ymax,zmax] removed from the domain.
    public var obstacles: [[Double]]
    public var patches: [PatchRule]
    public var sideKinds: [String: ZoneKind]
    /// Extra cell zones: cells whose centres fall in `box` [xmin,ymin,zmin,xmax,ymax,zmax] join the zone.
    public var cellZones: [CellZoneRegion]

    public struct CellZoneRegion: Codable, Sendable, Equatable {
        public var name: String
        public var kind: CellZoneKind
        public var box: [Double]
        public init(name: String, kind: CellZoneKind, box: [Double]) { self.name = name; self.kind = kind; self.box = box }
    }

    public init(x: BlockAxis, y: BlockAxis, z: BlockAxis? = nil, depth: Double = 1,
                obstacles: [[Double]] = [], patches: [PatchRule] = [], sideKinds: [String: ZoneKind] = [:],
                cellZones: [CellZoneRegion] = []) {
        self.x = x; self.y = y; self.z = z; self.depth = depth
        self.obstacles = obstacles; self.patches = patches; self.sideKinds = sideKinds
        self.cellZones = cellZones
    }

    public func build() throws -> Mesh {
        let xs = x.nodes(), ys = y.nodes()
        let zs = z?.nodes() ?? [0, depth]
        let twoD = z == nil
        let nx = xs.count - 1, ny = ys.count - 1, nz = zs.count - 1
        guard nx > 0, ny > 0, nz > 0 else { throw MeshError.topology("block axis without cells") }

        // Cell mask
        var cellID = [Int32](repeating: -1, count: nx * ny * nz)
        @inline(__always) func ci(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        var nCells: Int32 = 0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let c = Vec3(0.5 * (xs[i] + xs[i + 1]), 0.5 * (ys[j] + ys[j + 1]), 0.5 * (zs[k] + zs[k + 1]))
            var blocked = false
            for o in obstacles where o.count == 6 {
                if c.x > o[0] && c.x < o[3] && c.y > o[1] && c.y < o[4] && (twoD || (c.z > o[2] && c.z < o[5])) {
                    blocked = true; break
                }
            }
            if !blocked { cellID[ci(i, j, k)] = nCells; nCells += 1 }
        }}}
        guard nCells > 0 else { throw MeshError.topology("obstacles removed every cell") }
        var zoneOfCell = [Int32](repeating: 0, count: Int(nCells))
        // boxes with the same name form one zone (e.g. the base and fins of a heat sink)
        var zoneNames: [String] = [], zoneKinds: [CellZoneKind] = []
        let boxZone = cellZones.map { r -> Int32 in
            if let i = zoneNames.firstIndex(of: r.name) { return Int32(i + 1) }
            zoneNames.append(r.name); zoneKinds.append(r.kind)
            return Int32(zoneNames.count)
        }
        if !cellZones.isEmpty {
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
                let id = cellID[ci(i, j, k)]
                guard id >= 0 else { continue }
                let c = Vec3(0.5 * (xs[i] + xs[i + 1]), 0.5 * (ys[j] + ys[j + 1]), 0.5 * (zs[k] + zs[k + 1]))
                for (zi, r) in cellZones.enumerated() where r.box.count == 6 {
                    if c.x > r.box[0] && c.x < r.box[3] && c.y > r.box[1] && c.y < r.box[4] && (twoD || (c.z > r.box[2] && c.z < r.box[5])) {
                        zoneOfCell[Int(id)] = boxZone[zi]
                    }
                }
            }}}
        }

        // Nodes (only those used)
        let NX = nx + 1, NY = ny + 1, NZ = nz + 1
        var nodeID = [Int32](repeating: -1, count: NX * NY * NZ)
        @inline(__always) func ni(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * NY + j) * NX + i }
        var b = MeshBuilder()
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where cellID[ci(i, j, k)] >= 0 {
            for dk in 0...1 { for dj in 0...1 { for di in 0...1 {
                let id = ni(i + di, j + dj, k + dk)
                if nodeID[id] < 0 {
                    nodeID[id] = Int32(b.points.count)
                    b.points.append(Vec3(xs[i + di], ys[j + dj], zs[k + dk]))
                }
            }}}
        }}}
        b.nCells = Int(nCells)
        if !cellZones.isEmpty {
            b.cellZones = [MeshBuilder.CellZoneSpec(name: "fluid", kind: .fluid)] + zip(zoneNames, zoneKinds).map { MeshBuilder.CellZoneSpec(name: $0.0, kind: $0.1) }
            b.cellZoneOfCell = zoneOfCell
        }

        let sideNames = ["x-min", "x-max", "y-min", "y-max", twoD ? "frontAndBack" : "z-min", twoD ? "frontAndBack" : "z-max"]
        func zoneFor(side: Int?, centre: Vec3, normal: Vec3) -> Int32 {
            for r in patches where r.matches(centre: centre, normal: normal) {
                return b.addZone(r.name, kind: r.kind)
            }
            if let s = side {
                let name = sideNames[s]
                let kind: ZoneKind = (twoD && s >= 4) ? .empty : (sideKinds[name] ?? .wall)
                return b.addZone(name, kind: kind)
            }
            return b.addZone("obstacle", kind: sideKinds["obstacle"] ?? .wall)
        }

        // Faces normal to each axis: loop over node-plane positions.
        func quad(_ a: Int, _ c: Int, _ d: Int, _ e: Int) -> [Int32] { [nodeID[a], nodeID[c], nodeID[d], nodeID[e]] }
        // x-faces
        for k in 0..<nz { for j in 0..<ny { for i in 0...nx {
            let left = i > 0 ? cellID[ci(i - 1, j, k)] : -1
            let right = i < nx ? cellID[ci(i, j, k)] : -1
            if left < 0 && right < 0 { continue }
            let nodes = quad(ni(i, j, k), ni(i, j + 1, k), ni(i, j + 1, k + 1), ni(i, j, k + 1))
            if left >= 0 && right >= 0 { b.addFace(nodes, c0: left, c1: right); continue }
            let cen = Vec3(xs[i], 0.5 * (ys[j] + ys[j + 1]), 0.5 * (zs[k] + zs[k + 1]))
            let side: Int? = (i == 0) ? 0 : (i == nx ? 1 : nil)
            let n = left >= 0 ? Vec3(1, 0, 0) : Vec3(-1, 0, 0)
            b.addFace(nodes, c0: max(left, right), c1: -1, zone: zoneFor(side: side, centre: cen, normal: n))
        }}}
        // y-faces
        for k in 0..<nz { for j in 0...ny { for i in 0..<nx {
            let below = j > 0 ? cellID[ci(i, j - 1, k)] : -1
            let above = j < ny ? cellID[ci(i, j, k)] : -1
            if below < 0 && above < 0 { continue }
            let nodes = quad(ni(i, j, k), ni(i, j, k + 1), ni(i + 1, j, k + 1), ni(i + 1, j, k))
            if below >= 0 && above >= 0 { b.addFace(nodes, c0: below, c1: above); continue }
            let cen = Vec3(0.5 * (xs[i] + xs[i + 1]), ys[j], 0.5 * (zs[k] + zs[k + 1]))
            let side: Int? = (j == 0) ? 2 : (j == ny ? 3 : nil)
            let n = below >= 0 ? Vec3(0, 1, 0) : Vec3(0, -1, 0)
            b.addFace(nodes, c0: max(below, above), c1: -1, zone: zoneFor(side: side, centre: cen, normal: n))
        }}}
        // z-faces
        for k in 0...nz { for j in 0..<ny { for i in 0..<nx {
            let back = k > 0 ? cellID[ci(i, j, k - 1)] : -1
            let front = k < nz ? cellID[ci(i, j, k)] : -1
            if back < 0 && front < 0 { continue }
            let nodes = quad(ni(i, j, k), ni(i + 1, j, k), ni(i + 1, j + 1, k), ni(i, j + 1, k))
            if back >= 0 && front >= 0 { b.addFace(nodes, c0: back, c1: front); continue }
            let cen = Vec3(0.5 * (xs[i] + xs[i + 1]), 0.5 * (ys[j] + ys[j + 1]), zs[k])
            let side: Int? = (k == 0) ? 4 : (k == nz ? 5 : nil)
            let n = back >= 0 ? Vec3(0, 0, 1) : Vec3(0, 0, -1)
            // 2D slabs: front/back are always empty regardless of rules.
            let zone = twoD ? b.addZone("frontAndBack", kind: .empty) : zoneFor(side: side, centre: cen, normal: n)
            b.addFace(nodes, c0: max(back, front), c1: -1, zone: zone)
        }}}
        return try b.build()
    }
}

/// 2D O-grid around a circular cylinder: radial lines graded from the wall,
/// outer circle split into an upstream inlet and downstream outlet.
public struct CylinderOGridSpec: Codable, Sendable, Equatable {
    public var radius: Double
    public var outerRadius: Double
    public var radialCells: Int
    public var circumferentialCells: Int
    /// Ratio of outermost to wall-adjacent radial cell size.
    public var radialGrading: Double
    public var depth: Double
    public init(radius: Double = 0.5, outerRadius: Double = 20, radialCells: Int = 80,
                circumferentialCells: Int = 128, radialGrading: Double = 60, depth: Double = 1) {
        self.radius = radius; self.outerRadius = outerRadius; self.radialCells = radialCells
        self.circumferentialCells = circumferentialCells; self.radialGrading = radialGrading; self.depth = depth
    }

    public func build() throws -> Mesh {
        let nr = radialCells, nt = circumferentialCells
        guard nr > 0, nt >= 8, outerRadius > radius else { throw MeshError.topology("invalid O-grid parameters") }
        let rs = BlockAxis(from: radius, to: outerRadius, cells: nr, grading: radialGrading).nodes()
        var b = MeshBuilder()
        // nodes: (it, ir, k)
        func nid(_ it: Int, _ ir: Int, _ k: Int) -> Int32 { Int32((k * (nr + 1) + ir) * nt + (it % nt)) }
        for k in 0...1 {
            for ir in 0...nr {
                for it in 0..<nt {
                    let th = 2 * Double.pi * Double(it) / Double(nt)
                    b.points.append(Vec3(rs[ir] * cos(th), rs[ir] * sin(th), Double(k) * depth))
                }
            }
        }
        func cid(_ it: Int, _ ir: Int) -> Int32 { Int32(ir * nt + (it % nt)) }
        b.nCells = nr * nt
        let wall = b.addZone("cylinder", kind: .wall)
        let inlet = b.addZone("inlet", kind: .velocityInlet)
        let outlet = b.addZone("outlet", kind: .pressureOutlet)
        let fb = b.addZone("frontAndBack", kind: .empty)
        for ir in 0...nr {
            for it in 0..<nt {
                // radial-normal face at radius rs[ir], spanning it..it+1
                let nodes = [nid(it, ir, 0), nid(it + 1, ir, 0), nid(it + 1, ir, 1), nid(it, ir, 1)]
                if ir == 0 { b.addFace(nodes, c0: cid(it, 0), c1: -1, zone: wall) }
                else if ir == nr {
                    let th = 2 * Double.pi * (Double(it) + 0.5) / Double(nt)
                    b.addFace(nodes, c0: cid(it, nr - 1), c1: -1, zone: cos(th) < 0 ? inlet : outlet)
                } else { b.addFace(nodes, c0: cid(it, ir - 1), c1: cid(it, ir)) }
            }
        }
        for ir in 0..<nr {
            for it in 0..<nt {
                // circumferential-normal face at angle it, spanning ir..ir+1
                let nodes = [nid(it, ir, 0), nid(it, ir, 1), nid(it, ir + 1, 1), nid(it, ir + 1, 0)]
                b.addFace(nodes, c0: cid(it - 1 + nt, ir), c1: cid(it, ir))
                // front/back
                b.addFace([nid(it, ir, 0), nid(it, ir + 1, 0), nid(it + 1, ir + 1, 0), nid(it + 1, ir, 0)], c0: cid(it, ir), c1: -1, zone: fb)
                b.addFace([nid(it, ir, 1), nid(it + 1, ir, 1), nid(it + 1, ir + 1, 1), nid(it, ir + 1, 1)], c0: cid(it, ir), c1: -1, zone: fb)
            }
        }
        return try b.build()
    }
}
