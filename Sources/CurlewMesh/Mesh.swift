import Foundation

/// Boundary-condition family a face zone was created with. Importers map the
/// source format's zone type onto this; the case setup may change it later.
public enum ZoneKind: String, Codable, CaseIterable, Sendable {
    case wall
    case velocityInlet = "velocity-inlet"
    case massFlowInlet = "mass-flow-inlet"
    case pressureInlet = "pressure-inlet"
    case pressureOutlet = "pressure-outlet"
    case outflow
    case symmetry
    case pressureFarField = "pressure-far-field"
    /// Front/back planes of a one-cell-thick 2D slab: no flux, no gradient.
    case empty
    /// Faces between two cells that ended up in a boundary group (rare; e.g. baffles).
    case interior

    public var displayName: String {
        switch self {
        case .wall: return "Wall"
        case .velocityInlet: return "Velocity Inlet"
        case .massFlowInlet: return "Mass-Flow Inlet"
        case .pressureInlet: return "Pressure Inlet"
        case .pressureOutlet: return "Pressure Outlet"
        case .outflow: return "Outflow"
        case .symmetry: return "Symmetry"
        case .pressureFarField: return "Pressure Far-Field"
        case .empty: return "2D Plane (empty)"
        case .interior: return "Interior"
        }
    }

    /// Guess a kind from a zone name, used when the source format carries no type.
    public static func guess(fromName name: String) -> ZoneKind {
        let n = name.lowercased()
        if n.contains("frontandback") || n == "front" || n == "back" || n.contains("empty") { return .empty }
        if n.contains("inlet") || n.contains("inflow") { return .velocityInlet }
        if n.contains("outlet") || n.contains("outflow") || n.contains("exit") { return .pressureOutlet }
        if n.contains("symm") { return .symmetry }
        if n.contains("farfield") || n.contains("far-field") || n.contains("far_field") || n.contains("freestream") { return .pressureFarField }
        return .wall
    }
}

public enum CellZoneKind: String, Codable, CaseIterable, Sendable {
    case fluid, solid
}

public struct BoundaryZone: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var kind: ZoneKind
    /// First face index (global face numbering) and number of faces in the zone.
    public var start: Int
    public var count: Int
    public init(id: Int, name: String, kind: ZoneKind, start: Int, count: Int) {
        self.id = id; self.name = name; self.kind = kind; self.start = start; self.count = count
    }
    public var faceRange: Range<Int> { start..<(start + count) }
}

public struct CellZone: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var kind: CellZoneKind
    public var cellCount: Int
    public init(id: Int, name: String, kind: CellZoneKind, cellCount: Int) {
        self.id = id; self.name = name; self.kind = kind; self.cellCount = cellCount
    }
}

/// Face-based unstructured polyhedral mesh.
///
/// Layout invariants (established by `MeshBuilder`):
/// * faces `0..<nInternalFaces` are internal, with `owner < neighbour`, sorted by owner then neighbour;
/// * boundary faces follow, grouped contiguously per `BoundaryZone`;
/// * each face's area vector points from owner to neighbour (outward for boundary faces).
public final class Mesh: @unchecked Sendable {
    public let points: [Vec3]
    public let faceNodeOffsets: [Int32]
    public let faceNodes: [Int32]
    public let owner: [Int32]
    /// Neighbour cell of each internal face (count = nInternalFaces).
    public let neighbour: [Int32]
    public let nCells: Int
    public let nInternalFaces: Int
    public private(set) var boundaryZones: [BoundaryZone]
    public private(set) var cellZones: [CellZone]
    /// Cell zone index (into `cellZones`) of every cell.
    public let cellZone: [Int32]

    // Geometry
    public let faceCentres: [Vec3]
    /// Area-weighted normal: |Sf| is the face area.
    public let faceAreas: [Vec3]
    public let faceAreaMag: [Double]
    public let cellCentres: [Vec3]
    public let cellVolumes: [Double]

    // Cell -> faces connectivity (CSR)
    public let cellFaceOffsets: [Int32]
    public let cellFaces: [Int32]

    public var nFaces: Int { owner.count }
    public var nBoundaryFaces: Int { nFaces - nInternalFaces }
    public var nPoints: Int { points.count }
    public let bounds: BoundingBox

    /// For one-cell-thick slabs: index of the axis the empty planes are normal to.
    public let twoDimensionalAxis: Int?
    public var isTwoDimensional: Bool { twoDimensionalAxis != nil }

    public init(points: [Vec3], faceNodeOffsets: [Int32], faceNodes: [Int32],
                owner: [Int32], neighbour: [Int32], nCells: Int,
                boundaryZones: [BoundaryZone], cellZones: [CellZone], cellZone: [Int32]) {
        self.points = points
        self.faceNodeOffsets = faceNodeOffsets
        self.faceNodes = faceNodes
        self.owner = owner
        self.neighbour = neighbour
        self.nCells = nCells
        self.nInternalFaces = neighbour.count
        self.boundaryZones = boundaryZones
        self.cellZones = cellZones
        self.cellZone = cellZone
        self.bounds = BoundingBox(points: points)

        let nF = owner.count
        var fc = [Vec3](repeating: .zero, count: nF)
        var fa = [Vec3](repeating: .zero, count: nF)
        var fm = [Double](repeating: 0, count: nF)
        Mesh.computeFaceGeometry(points: points, offsets: faceNodeOffsets, nodes: faceNodes,
                                 centres: &fc, areas: &fa, mags: &fm)
        self.faceCentres = fc
        self.faceAreas = fa
        self.faceAreaMag = fm

        // Cell -> faces
        var counts = [Int32](repeating: 0, count: nCells + 1)
        for f in 0..<nF { counts[Int(owner[f]) + 1] += 1 }
        for f in 0..<neighbour.count { counts[Int(neighbour[f]) + 1] += 1 }
        for c in 0..<nCells { counts[c + 1] += counts[c] }
        var fill = counts
        var cf = [Int32](repeating: 0, count: Int(counts[nCells]))
        for f in 0..<nF {
            let o = Int(owner[f]); cf[Int(fill[o])] = Int32(f); fill[o] += 1
            if f < neighbour.count {
                let n = Int(neighbour[f]); cf[Int(fill[n])] = Int32(f); fill[n] += 1
            }
        }
        self.cellFaceOffsets = counts
        self.cellFaces = cf

        var cc = [Vec3](repeating: .zero, count: nCells)
        var cv = [Double](repeating: 0, count: nCells)
        Mesh.computeCellGeometry(nCells: nCells, nInternal: neighbour.count, owner: owner,
                                 cellFaceOffsets: counts, cellFaces: cf,
                                 faceCentres: fc, faceAreas: fa, centres: &cc, volumes: &cv)
        self.cellCentres = cc
        self.cellVolumes = cv

        // 2D detection: every empty zone face normal is aligned with one axis.
        var axis: Int? = nil
        let emptyZones = boundaryZones.filter { $0.kind == .empty && $0.count > 0 }
        if !emptyZones.isEmpty {
            var accum = Vec3.zero
            var aligned = true
            outer: for z in emptyZones {
                for f in z.faceRange {
                    let n = normalized(fa[f])
                    accum += Vec3(abs(n.x), abs(n.y), abs(n.z))
                    if max(abs(n.x), abs(n.y), abs(n.z)) < 0.999 { aligned = false; break outer }
                }
            }
            if aligned {
                if accum.z >= accum.x && accum.z >= accum.y { axis = 2 }
                else if accum.y >= accum.x { axis = 1 } else { axis = 0 }
            }
        }
        self.twoDimensionalAxis = axis
    }

    // MARK: Geometry kernels (OpenFOAM-style triangle decomposition)

    static func computeFaceGeometry(points: [Vec3], offsets: [Int32], nodes: [Int32],
                                    centres: inout [Vec3], areas: inout [Vec3], mags: inout [Double]) {
        let nF = offsets.count - 1
        points.withUnsafeBufferPointer { P in
            for f in 0..<nF {
                let s = Int(offsets[f]), e = Int(offsets[f + 1])
                let n = e - s
                if n == 3 {
                    let a = P[Int(nodes[s])], b = P[Int(nodes[s + 1])], c = P[Int(nodes[s + 2])]
                    let sf = 0.5 * cross(b - a, c - a)
                    centres[f] = (a + b + c) / 3
                    areas[f] = sf
                    mags[f] = norm(sf)
                    continue
                }
                var est = Vec3.zero
                for k in s..<e { est += P[Int(nodes[k])] }
                est /= Double(n)
                var sumN = Vec3.zero, sumA = 0.0, sumAc = Vec3.zero
                for k in 0..<n {
                    let p = P[Int(nodes[s + k])]
                    let q = P[Int(nodes[s + (k + 1) % n])]
                    sumN += cross(q - p, est - p)
                }
                let nHat = normalized(sumN)
                for k in 0..<n {
                    let p = P[Int(nodes[s + k])]
                    let q = P[Int(nodes[s + (k + 1) % n])]
                    let c = p + q + est
                    let tn = cross(q - p, est - p)
                    let a = dot(tn, nHat)
                    sumA += a
                    sumAc += a * c
                }
                centres[f] = sumA > 1e-300 ? sumAc / (3 * sumA) : est
                areas[f] = 0.5 * sumN
                mags[f] = norm(areas[f])
            }
        }
    }

    static func computeCellGeometry(nCells: Int, nInternal: Int, owner: [Int32],
                                    cellFaceOffsets: [Int32], cellFaces: [Int32],
                                    faceCentres: [Vec3], faceAreas: [Vec3],
                                    centres: inout [Vec3], volumes: inout [Double]) {
        for c in 0..<nCells {
            let s = Int(cellFaceOffsets[c]), e = Int(cellFaceOffsets[c + 1])
            var est = Vec3.zero
            for k in s..<e { est += faceCentres[Int(cellFaces[k])] }
            est /= Double(max(e - s, 1))
            var vol = 0.0, vc = Vec3.zero
            for k in s..<e {
                let f = Int(cellFaces[k])
                var sf = faceAreas[f]
                if Int(owner[f]) != c { sf = -sf }
                let pv = max(dot(sf, faceCentres[f] - est), 1e-300) / 3
                vol += pv
                vc += pv * (0.75 * faceCentres[f] + 0.25 * est)
            }
            volumes[c] = vol
            centres[c] = vol > 1e-300 ? vc / vol : est
        }
    }

    // MARK: Convenience

    @inline(__always) public func faceNodeRange(_ f: Int) -> Range<Int> {
        Int(faceNodeOffsets[f])..<Int(faceNodeOffsets[f + 1])
    }
    @inline(__always) public func cellFaceRange(_ c: Int) -> Range<Int> {
        Int(cellFaceOffsets[c])..<Int(cellFaceOffsets[c + 1])
    }
    public func zone(named name: String) -> BoundaryZone? { boundaryZones.first { $0.name == name } }
    /// Boundary zone containing global face `f`, or nil for internal faces.
    public func zoneIndex(ofFace f: Int) -> Int? {
        guard f >= nInternalFaces else { return nil }
        for (i, z) in boundaryZones.enumerated() where z.faceRange.contains(f) { return i }
        return nil
    }
    public var totalVolume: Double { cellVolumes.reduce(0, +) }

    /// Rename or retype zones without touching topology.
    public func updateBoundaryZone(_ index: Int, name: String? = nil, kind: ZoneKind? = nil) {
        if let name { boundaryZones[index].name = name }
        if let kind { boundaryZones[index].kind = kind }
    }
    public func updateCellZone(_ index: Int, name: String? = nil, kind: CellZoneKind? = nil) {
        if let name { cellZones[index].name = name }
        if let kind { cellZones[index].kind = kind }
    }

    public var summary: String {
        var s = "\(nCells) cells, \(nFaces) faces (\(nInternalFaces) interior), \(nPoints) nodes"
        if let a = twoDimensionalAxis { s += ", 2D (normal to \(["x", "y", "z"][a]))" }
        return s
    }

    /// Count cells by shape (number of faces; 2D slabs count in-plane faces).
    public func cellShapeHistogram() -> [String: Int] {
        var h: [String: Int] = [:]
        for c in 0..<nCells {
            var nf = 0, nTri = 0, nQuad = 0
            for k in cellFaceRange(c) {
                let f = Int(cellFaces[k])
                let nn = faceNodeRange(f).count
                nf += 1
                if nn == 3 { nTri += 1 } else if nn == 4 { nQuad += 1 }
            }
            let name: String
            switch (nf, nTri, nQuad) {
            case (4, 4, 0): name = "tetrahedra"
            case (6, 0, 6): name = "hexahedra"
            case (5, 2, 3): name = "wedges"
            case (5, 4, 1): name = "pyramids"
            default: name = "polyhedra"
            }
            h[name, default: 0] += 1
        }
        return h
    }
}
