import Foundation

/// Mesh exporters: OpenFOAM polyMesh and Fluent ASCII (.msh).
public enum MeshWriters {
    // MARK: OpenFOAM

    static func foamHeader(_ cls: String, _ object: String, note: String = "") -> String {
        """
        FoamFile
        {
            version     2.0;
            format      ascii;
            arch        "LSB;label=32;scalar=64";
            class       \(cls);
            location    "constant/polyMesh";
            object      \(object);\(note.isEmpty ? "" : "\n    note        \"\(note)\";")
        }

        """
    }

    public static func foamPatchType(_ k: ZoneKind) -> String {
        switch k {
        case .wall: return "wall"
        case .empty: return "empty"
        // generic constraint type: also valid for non-planar (snapped, curved) patches
        case .symmetry: return "symmetry"
        default: return "patch"
        }
    }

    /// Writes `constant/polyMesh` under `caseDir`. `kindOverride` replaces a zone's kind
    /// (by name) when the case setup retyped it, so patch and field types agree.
    /// `region` writes `constant/<region>/polyMesh` (multi-region cases); `patchEntries`
    /// replaces the generated `type …;` line of a patch with the given entries (e.g. a
    /// `mappedWall` with its sample region and patch).
    public static func writeFoamPolyMesh(_ m: Mesh, caseDir: URL, kindOverride: [String: ZoneKind] = [:],
                                         region: String? = nil, patchEntries: [String: String] = [:]) throws {
        let dir = caseDir.appendingPathComponent(region.map { "constant/\($0)/polyMesh" } ?? "constant/polyMesh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = foamHeader("vectorField", "points")
        s += "\(m.nPoints)\n(\n"
        for p in m.points { s += "(\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z)))\n" }
        s += ")\n"
        try s.write(to: dir.appendingPathComponent("points"), atomically: true, encoding: .utf8)

        s = foamHeader("faceList", "faces")
        s += "\(m.nFaces)\n(\n"
        for f in 0..<m.nFaces {
            let r = m.faceNodeRange(f)
            s += "\(r.count)(" + r.map { String(m.faceNodes[$0]) }.joined(separator: " ") + ")\n"
        }
        s += ")\n"
        try s.write(to: dir.appendingPathComponent("faces"), atomically: true, encoding: .utf8)

        let note = "nPoints:\(m.nPoints)  nCells:\(m.nCells)  nFaces:\(m.nFaces)  nInternalFaces:\(m.nInternalFaces)"
        s = foamHeader("labelList", "owner", note: note)
        s += "\(m.nFaces)\n(\n" + m.owner.map { String($0) }.joined(separator: "\n") + "\n)\n"
        try s.write(to: dir.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
        s = foamHeader("labelList", "neighbour", note: note)
        s += "\(m.nInternalFaces)\n(\n" + m.neighbour.map { String($0) }.joined(separator: "\n") + "\n)\n"
        try s.write(to: dir.appendingPathComponent("neighbour"), atomically: true, encoding: .utf8)

        s = foamHeader("polyBoundaryMesh", "boundary")
        s += "\(m.boundaryZones.count)\n(\n"
        for z in m.boundaryZones {
            let t = foamPatchType(z.kind == .empty ? .empty : (kindOverride[z.name] ?? z.kind))
            s += "    \(foamName(z.name))\n    {\n"
            if let extra = patchEntries[z.name] {
                s += extra.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n"
            } else {
                s += "        type            \(t);\n"
                if t == "wall" { s += "        inGroups        1(wall);\n" }
            }
            s += "        nFaces          \(z.count);\n        startFace       \(z.start);\n    }\n"
        }
        s += ")\n"
        try s.write(to: dir.appendingPathComponent("boundary"), atomically: true, encoding: .utf8)

        // Cell zones: needed by fvOptions/MRF/porosity selections (selectionMode cellZone).
        s = foamHeader("regIOobject", "cellZones")
        s += "\(m.cellZones.count)\n(\n"
        var members = [[Int32]](repeating: [], count: m.cellZones.count)
        for c in 0..<m.nCells { members[Int(m.cellZone[c])].append(Int32(c)) }
        for (i, z) in m.cellZones.enumerated() {
            s += "\(foamName(z.name))\n{\n    type cellZone;\ncellLabels      List<label> \(members[i].count)\n(\n"
            s += members[i].map { String($0) }.joined(separator: "\n")
            s += "\n)\n;\n}\n"
        }
        s += ")\n"
        try s.write(to: dir.appendingPathComponent("cellZones"), atomically: true, encoding: .utf8)
    }

    /// OpenFOAM patch names must be valid words.
    public static func foamName(_ n: String) -> String {
        String(n.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." ? $0 : "_" })
    }

    static func fmt(_ v: Double) -> String { String(format: "%.12g", v) }

    // MARK: Fluent ASCII

    static func hex(_ v: Int) -> String { String(v, radix: 16) }

    public static func fluentBCType(_ k: ZoneKind) -> (Int, String) {
        switch k {
        case .wall: return (3, "wall")
        case .pressureInlet: return (4, "pressure-inlet")
        case .pressureOutlet: return (5, "pressure-outlet")
        case .symmetry: return (7, "symmetry")
        case .pressureFarField: return (9, "pressure-far-field")
        case .velocityInlet: return (10, "velocity-inlet")
        case .massFlowInlet: return (20, "mass-flow-inlet")
        case .outflow: return (36, "outflow")
        case .interior: return (2, "interior")
        case .empty: return (3, "wall")
        }
    }

    /// Fluent 3D ASCII mesh. (2D slabs are written as 3D; Fluent reads them as a one-cell-thick 3D mesh.)
    public static func fluentMesh(_ m: Mesh) -> String {
        var s = "(0 \"Curlew mesh export\")\n(2 3)\n"
        s += "(10 (0 1 \(hex(m.nPoints)) 0 3))\n"
        s += "(12 (0 1 \(hex(m.nCells)) 0))\n"
        s += "(13 (0 1 \(hex(m.nFaces)) 0))\n"
        s += "(10 (1 1 \(hex(m.nPoints)) 1 3)(\n"
        for p in m.points { s += "\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n" }
        s += "))\n"
        // cell zones: Fluent wants contiguous ranges; our cells are already grouped only if single zone.
        var zoneID = 2
        var cellZoneIDs: [Int] = []
        if m.cellZones.count <= 1 {
            s += "(12 (\(hex(zoneID)) 1 \(hex(m.nCells)) 1 0))\n"
            cellZoneIDs.append(zoneID); zoneID += 1
        } else {
            // emit one section per contiguous run, all mapped to their zone id
            var start = 0
            let ids = m.cellZones.indices.map { _ -> Int in defer { zoneID += 1 }; return zoneID }
            cellZoneIDs = ids
            while start < m.nCells {
                var end = start
                while end + 1 < m.nCells && m.cellZone[end + 1] == m.cellZone[start] { end += 1 }
                s += "(12 (\(hex(ids[Int(m.cellZone[start])])) \(hex(start + 1)) \(hex(end + 1)) 1 0))\n"
                start = end + 1
            }
        }
        // faces: interior then each boundary zone; c0 is the cell the right-hand-rule normal points away from
        func faceLines(_ range: Range<Int>) -> String {
            var t = ""
            for f in range {
                let r = m.faceNodeRange(f)
                // Fluent convention: normal (right-hand rule) points from c1 to c0, so reverse our owner->neighbour order
                let nodes = r.reversed().map { hex(Int(m.faceNodes[$0]) + 1) }
                let c0 = Int(m.owner[f]) + 1
                let c1 = f < m.nInternalFaces ? Int(m.neighbour[f]) + 1 : 0
                t += "\(hex(r.count)) " + nodes.joined(separator: " ") + " \(hex(c0)) \(hex(c1))\n"
            }
            return t
        }
        let interiorID = zoneID; zoneID += 1
        if m.nInternalFaces > 0 {
            s += "(13 (\(hex(interiorID)) 1 \(hex(m.nInternalFaces)) 2 0)(\n" + faceLines(0..<m.nInternalFaces) + "))\n"
        }
        var zoneNames: [(Int, String, String)] = []
        for z in m.boundaryZones {
            let (bc, name) = fluentBCType(z.kind)
            s += "(13 (\(hex(zoneID)) \(hex(z.start + 1)) \(hex(z.start + z.count)) \(hex(bc)) 0)(\n" + faceLines(z.faceRange) + "))\n"
            zoneNames.append((zoneID, name, z.name))
            zoneID += 1
        }
        for (i, z) in m.cellZones.enumerated() {
            s += "(45 (\(cellZoneIDs[min(i, cellZoneIDs.count - 1)]) \(z.kind == .solid ? "solid" : "fluid") \(z.name))())\n"
        }
        s += "(45 (\(interiorID) interior interior-\(m.cellZones.first?.name ?? "fluid"))())\n"
        for (id, t, n) in zoneNames { s += "(45 (\(id) \(t) \(n))())\n" }
        return s
    }
}
