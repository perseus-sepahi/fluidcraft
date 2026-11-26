import Foundation
import FluidCraftMesh
import FluidCraftSolver

/// Mesh generation done by OpenFOAM's own utilities: blockMesh for structured block and
/// O-grid meshes, snappyHexMesh (layer addition only) for prism layers on Gmsh meshes.
/// FluidCraft writes the dictionaries and reads the polyMesh back.
public enum FoamMeshTools {
    static let lock = NSLock()
    nonisolated(unsafe) static var cached: FoamEnvironment?

    /// The first installed OpenFOAM, activated once per process.
    public static func environment() throws -> FoamEnvironment {
        lock.lock(); defer { lock.unlock() }
        if let e = cached { return e }
        guard let inst = FoamDiscovery.discover().first else {
            throw MeshError.unsupported("OpenFOAM is not installed: FluidCraft meshes block and O-grid geometries with OpenFOAM's blockMesh (install it from Settings › Tools, or: brew install gerlero/openfoam/openfoam)")
        }
        let e = try inst.resolve()
        cached = e
        return e
    }

    /// A fresh case folder without spaces (OpenFOAM's scripts need that).
    static func scratchCase(_ prefix: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("system"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("constant"), withIntermediateDirectories: true)
        try (FoamFile.header("dictionary", "controlDict", location: "system") +
             "application blockMesh;\nstartFrom startTime;\nstartTime 0;\nstopAt endTime;\nendTime 1;\ndeltaT 1;\nwriteControl timeStep;\nwriteInterval 1;\nwriteFormat ascii;\nwritePrecision 15;\nwriteCompression off;\ntimeFormat general;\nrunTimeModifiable false;\n")
            .write(to: d.appendingPathComponent("system/controlDict"), atomically: true, encoding: .utf8)
        try (FoamFile.header("dictionary", "fvSchemes", location: "system") +
             "ddtSchemes { default steadyState; }\ngradSchemes { default Gauss linear; }\ndivSchemes { default none; }\nlaplacianSchemes { default Gauss linear corrected; }\ninterpolationSchemes { default linear; }\nsnGradSchemes { default corrected; }\n")
            .write(to: d.appendingPathComponent("system/fvSchemes"), atomically: true, encoding: .utf8)
        try (FoamFile.header("dictionary", "fvSolution", location: "system") + "solvers {}\n")
            .write(to: d.appendingPathComponent("system/fvSolution"), atomically: true, encoding: .utf8)
        return d
    }

    /// Run stages in `dir`; throws with the reason when one fails.
    static func run(_ stages: [FoamStage], in dir: URL, environment env: FoamEnvironment, log: ((String) -> Void)? = nil) throws -> FoamRunMetrics {
        let report = FoamCaseReport(application: .simpleFoam, turbulence: .laminar, cores: 1, runsPotentialFoam: false,
                                    kinematicPressure: true, density: 1, operatingPressure: 0)
        let runner = FoamRunner(environment: env, caseDirectory: dir, report: report)
        var tail: [String] = []
        let failure = runner.run(stages) { e in
            if case .line(let l) = e {
                tail.append(l); if tail.count > 12 { tail.removeFirst() }
                if let log, l.contains("FOAM FATAL") || l.hasPrefix("Layer mesh") || l.hasPrefix("Mesh OK") || l.contains("Failed") { log(l) }
            }
        }
        if let failure { throw MeshError.io("\(failure)\n" + tail.suffix(6).joined(separator: "\n")) }
        return runner.metrics
    }

    static func stage(_ command: String, _ args: [String] = []) -> FoamStage {
        FoamStage(id: command, title: command, command: command, arguments: args, parallel: false, logName: command)
    }

    static func patchType(_ k: ZoneKind) -> String {
        switch k {
        case .wall: return "wall"
        case .empty: return "empty"
        case .symmetry: return "symmetry"
        default: return "patch"
        }
    }

    /// Read the generated polyMesh and give zones their FluidCraft names and kinds.
    static func readBack(_ dir: URL, names: [String: String], kinds: [String: ZoneKind], cellKinds: [String: CellZoneKind]) throws -> Mesh {
        let m = try FoamMeshReader.read(url: dir)
        for (i, z) in m.boundaryZones.enumerated() {
            let name = names[z.name] ?? z.name
            m.updateBoundaryZone(i, name: name, kind: kinds[name] ?? z.kind)
        }
        for (i, z) in m.cellZones.enumerated() {
            let name = names[z.name] ?? z.name
            m.updateCellZone(i, name: name, kind: cellKinds[name] ?? .fluid)
        }
        return m
    }
}

// MARK: - blockMesh

public enum FoamBlockMesh {
    public struct Dictionary: Sendable {
        public var text: String
        public var blocks: Int
        /// foam patch/zone name → FluidCraft name
        public var names: [String: String]
        public var kinds: [String: ZoneKind]
        public var cellKinds: [String: CellZoneKind]
    }

    /// Hex vertex order (blockMesh): x0y0z0 x1y0z0 x1y1z0 x0y1z0, then the same at z1.
    /// Faces in outward order: -x +x -y +y -z +z.
    static let hexFaces: [[Int]] = [[0, 4, 7, 3], [1, 2, 6, 5], [0, 1, 5, 4], [3, 7, 6, 2], [0, 3, 2, 1], [4, 5, 6, 7]]

    /// The blockMeshDict for a Cartesian block spec. The axes are cut into blocks wherever a
    /// segment ends or an obstacle, cell-zone box or patch rule changes, so every block is
    /// uniform in what it is, and each block edge reproduces the spec's graded spacing exactly.
    public static func dictionary(_ spec: BlockMeshSpec) throws -> Dictionary {
        let twoD = spec.z == nil
        let axes: [[Double]] = [spec.x.nodes(), spec.y.nodes(), spec.z?.nodes() ?? [0, spec.depth]]
        let n = axes.map { $0.count - 1 }
        guard n.allSatisfy({ $0 > 0 }) else { throw MeshError.topology("block axis without cells") }
        func centre(_ a: Int, _ i: Int) -> Double { 0.5 * (axes[a][i] + axes[a][i + 1]) }

        // Breakpoints (node indices) per axis
        var bp: [Set<Int>] = [[0, n[0]], [0, n[1]], [0, n[2]]]
        for (a, ax) in [spec.x, spec.y, spec.z].enumerated() {
            guard let ax else { continue }
            var c = 0
            for s in ax.segments { c += max(s.cells, 1); bp[a].insert(min(c, n[a])) }
        }
        /// node breakpoints bounding the cells whose centres lie in (lo, hi) (strict) or [lo, hi] (inclusive)
        func cellRange(_ a: Int, _ lo: Double, _ hi: Double, inclusive: Bool) {
            let eps = inclusive ? 1e-9 : 0
            let inside = (0..<n[a]).filter { i in
                let c = centre(a, i)
                return inclusive ? (c >= lo - eps && c <= hi + eps) : (c > lo && c < hi)
            }
            guard let f = inside.first, let l = inside.last else { return }
            bp[a].insert(f); bp[a].insert(l + 1)
        }
        for o in spec.obstacles where o.count == 6 { for a in 0..<(twoD ? 2 : 3) { cellRange(a, o[a], o[a + 3], inclusive: false) } }
        for r in spec.cellZones where r.box.count == 6 { for a in 0..<(twoD ? 2 : 3) { cellRange(a, r.box[a], r.box[a + 3], inclusive: false) } }
        for r in spec.patches where r.boxMin.count == 3 && r.boxMax.count == 3 {
            for a in 0..<3 { cellRange(a, r.boxMin[a], r.boxMax[a], inclusive: true) }
        }
        let B = bp.map { $0.sorted() }
        let nb = B.map { $0.count - 1 }

        func inBox(_ c: Vec3, _ o: [Double]) -> Bool {
            c.x > o[0] && c.x < o[3] && c.y > o[1] && c.y < o[4] && (twoD || (c.z > o[2] && c.z < o[5]))
        }
        /// representative cell centre of block (I, J, K)
        func rep(_ I: Int, _ J: Int, _ K: Int) -> Vec3 { Vec3(centre(0, B[0][I]), centre(1, B[1][J]), centre(2, B[2][K])) }
        func active(_ I: Int, _ J: Int, _ K: Int) -> Bool {
            guard I >= 0, J >= 0, K >= 0, I < nb[0], J < nb[1], K < nb[2] else { return false }
            let c = rep(I, J, K)
            return !spec.obstacles.contains { $0.count == 6 && inBox(c, $0) }
        }

        // Cell zones: boxes with the same name form one zone; later boxes win (as before).
        var zoneNames: [String] = [], cellKinds: [String: CellZoneKind] = [:]
        for r in spec.cellZones where !zoneNames.contains(r.name) { zoneNames.append(r.name); cellKinds[r.name] = r.kind }
        func zoneOf(_ c: Vec3) -> String? {
            var z: String? = nil
            for r in spec.cellZones where r.box.count == 6 && inBox(c, r.box) { z = r.name }
            return z
        }

        // Vertices on the breakpoint grid, numbered as they are first used.
        var vid: [Int: Int] = [:]
        var verts: [Vec3] = []
        func v(_ i: Int, _ j: Int, _ k: Int) -> Int {
            let key = (k * (nb[1] + 1) + j) * (nb[0] + 1) + i
            if let id = vid[key] { return id }
            vid[key] = verts.count
            verts.append(Vec3(axes[0][B[0][i]], axes[1][B[1][j]], axes[2][B[2][k]]))
            return verts.count - 1
        }
        func grading(_ a: Int, _ I: Int) -> Double {
            let lo = B[a][I], hi = B[a][I + 1]
            guard hi - lo > 1 else { return 1 }
            let x = axes[a]
            return (x[hi] - x[hi - 1]) / (x[lo + 1] - x[lo])
        }

        var names: [String: String] = [:], kinds: [String: ZoneKind] = [:]
        var patchFaces: [(String, [[Int]])] = []
        func addFace(_ name: String, _ kind: ZoneKind, _ f: [Int]) {
            let fn = MeshWriters.foamName(name)
            names[fn] = name
            if kinds[name] == nil { kinds[name] = kind }
            if let i = patchFaces.firstIndex(where: { $0.0 == fn }) { patchFaces[i].1.append(f) } else { patchFaces.append((fn, [f])) }
        }
        let sideNames = ["x-min", "x-max", "y-min", "y-max", "z-min", "z-max"]

        var blocks: [String] = []
        for K in 0..<nb[2] { for J in 0..<nb[1] { for I in 0..<nb[0] where active(I, J, K) {
            let h = [v(I, J, K), v(I + 1, J, K), v(I + 1, J + 1, K), v(I, J + 1, K),
                     v(I, J, K + 1), v(I + 1, J, K + 1), v(I + 1, J + 1, K + 1), v(I, J + 1, K + 1)]
            let cells = (0..<3).map { a in B[a][[I, J, K][a] + 1] - B[a][[I, J, K][a]] }
            let zone = spec.cellZones.isEmpty ? "" : MeshWriters.foamName(zoneOf(rep(I, J, K)) ?? "fluid") + " "
            blocks.append("    hex (\(h.map(String.init).joined(separator: " "))) \(zone)(\(cells[0]) \(cells[1]) \(cells[2])) simpleGrading (\(FoamNum.s(grading(0, I))) \(FoamNum.s(grading(1, J))) \(FoamNum.s(grading(2, K))))")
            // boundary faces
            let idx = [I, J, K]
            for (fi, face) in hexFaces.enumerated() {
                let a = fi / 2, plus = fi % 2 == 1
                var nbIdx = idx; nbIdx[a] += plus ? 1 : -1
                if active(nbIdx[0], nbIdx[1], nbIdx[2]) { continue }
                let verts = face.map { h[$0] }
                if twoD && a == 2 { addFace("frontAndBack", .empty, verts); continue }
                // face centre: first cell face of the block face
                var c = rep(I, J, K)
                let node = plus ? B[a][idx[a] + 1] : B[a][idx[a]]
                c[a] = axes[a][node]
                var normal = Vec3.zero; normal[a] = plus ? 1 : -1
                if let r = spec.patches.first(where: { $0.matches(centre: c, normal: normal) }) { addFace(r.name, r.kind, verts); continue }
                let atSide = node == 0 || node == n[a]
                if atSide {
                    let name = sideNames[2 * a + (plus ? 1 : 0)]
                    addFace(name, spec.sideKinds[name] ?? .wall, verts)
                } else {
                    addFace("obstacle", spec.sideKinds["obstacle"] ?? .wall, verts)
                }
            }
        }}}
        guard !blocks.isEmpty else { throw MeshError.topology("obstacles removed every cell") }
        if !spec.cellZones.isEmpty {
            names["fluid"] = "fluid"
            for z in zoneNames { names[MeshWriters.foamName(z)] = z }
        }
        var t = FoamFile.header("dictionary", "blockMeshDict", location: "system")
        t += "scale 1;\n\nvertices\n(\n" + verts.map { "    " + FoamNum.vec($0) }.joined(separator: "\n") + "\n);\n\n"
        t += "blocks\n(\n" + blocks.joined(separator: "\n") + "\n);\n\nedges ();\n\nboundary\n(\n"
        for (name, faces) in patchFaces {
            let kind = kinds[names[name] ?? name] ?? .wall
            t += "    \(name)\n    {\n        type \(FoamMeshTools.patchType(kind));\n        faces\n        (\n"
            t += faces.map { "            (\($0.map(String.init).joined(separator: " ")))" }.joined(separator: "\n") + "\n        );\n    }\n"
        }
        t += ");\n\nmergePatchPairs ();\n"
        return Dictionary(text: t, blocks: blocks.count, names: names, kinds: kinds, cellKinds: cellKinds)
    }

    /// The blockMeshDict for an O-grid: 8 (or 4) curved blocks around the cylinder.
    public static func dictionary(_ s: CylinderOGridSpec) throws -> Dictionary {
        let nr = s.radialCells, nt = s.circumferentialCells
        guard nr > 0, nt >= 8, s.outerRadius > s.radius else { throw MeshError.topology("invalid O-grid parameters") }
        let nb = nt % 8 == 0 ? 8 : (nt % 4 == 0 ? 4 : 0)
        guard nb > 0 else { throw MeshError.topology("the circumferential cell count must be a multiple of 4") }
        func pt(_ r: Double, _ th: Double, _ z: Double) -> Vec3 { Vec3(r * cos(th), r * sin(th), z) }
        func th(_ m: Int) -> Double { 2 * Double.pi * Double(m % nb) / Double(nb) }
        var verts: [Vec3] = []
        for z in [0, s.depth] { for r in [s.radius, s.outerRadius] { for m in 0..<nb { verts.append(pt(r, th(m), z)) } } }
        // index: z0 inner m, z0 outer nb+m, z1 inner 2nb+m, z1 outer 3nb+m
        func inner(_ m: Int, _ z: Int) -> Int { 2 * nb * z + (m % nb) }
        func outer(_ m: Int, _ z: Int) -> Int { 2 * nb * z + nb + (m % nb) }
        var blocks: [String] = [], edges: [String] = []
        var wall: [[Int]] = [], inlet: [[Int]] = [], outlet: [[Int]] = [], fb: [[Int]] = []
        for m in 0..<nb {
            let h = [inner(m, 0), outer(m, 0), outer(m + 1, 0), inner(m + 1, 0), inner(m, 1), outer(m, 1), outer(m + 1, 1), inner(m + 1, 1)]
            blocks.append("    hex (\(h.map(String.init).joined(separator: " "))) (\(nr) \(nt / nb) 1) simpleGrading (\(FoamNum.s(s.radialGrading)) 1 1)")
            let mid = th(m) + Double.pi / Double(nb)
            for (z, zc) in [(0, 0.0), (1, s.depth)] {
                edges.append("    arc \(inner(m, z)) \(inner(m + 1, z)) \(FoamNum.vec(pt(s.radius, mid, zc)))")
                edges.append("    arc \(outer(m, z)) \(outer(m + 1, z)) \(FoamNum.vec(pt(s.outerRadius, mid, zc)))")
            }
            wall.append(hexFaces[0].map { h[$0] })
            if cos(mid) < 0 { inlet.append(hexFaces[1].map { h[$0] }) } else { outlet.append(hexFaces[1].map { h[$0] }) }
            fb.append(hexFaces[4].map { h[$0] }); fb.append(hexFaces[5].map { h[$0] })
        }
        var t = FoamFile.header("dictionary", "blockMeshDict", location: "system")
        t += "scale 1;\n\nvertices\n(\n" + verts.map { "    " + FoamNum.vec($0) }.joined(separator: "\n") + "\n);\n\n"
        t += "blocks\n(\n" + blocks.joined(separator: "\n") + "\n);\n\nedges\n(\n" + edges.joined(separator: "\n") + "\n);\n\nboundary\n(\n"
        for (name, type, faces) in [("cylinder", "wall", wall), ("inlet", "patch", inlet), ("outlet", "patch", outlet), ("frontAndBack", "empty", fb)] {
            t += "    \(name)\n    {\n        type \(type);\n        faces\n        (\n"
            t += faces.map { "            (\($0.map(String.init).joined(separator: " ")))" }.joined(separator: "\n") + "\n        );\n    }\n"
        }
        t += ");\n\nmergePatchPairs ();\n"
        let kinds: [String: ZoneKind] = ["cylinder": .wall, "inlet": .velocityInlet, "outlet": .pressureOutlet, "frontAndBack": .empty]
        return Dictionary(text: t, blocks: nb, names: [:], kinds: kinds, cellKinds: [:])
    }

    /// Write the dictionary, run blockMesh, read the mesh back.
    public static func build(_ d: Dictionary, environment: FoamEnvironment? = nil, keepCase: Bool = false) throws -> Mesh {
        let env = try environment ?? FoamMeshTools.environment()
        let dir = try FoamMeshTools.scratchCase("blockMesh")
        defer { if !keepCase { try? FileManager.default.removeItem(at: dir) } }
        try d.text.write(to: dir.appendingPathComponent("system/blockMeshDict"), atomically: true, encoding: .utf8)
        _ = try FoamMeshTools.run([FoamMeshTools.stage("blockMesh")], in: dir, environment: env)
        return try FoamMeshTools.readBack(dir, names: d.names, kinds: d.kinds, cellKinds: d.cellKinds)
    }
}

public extension BlockMeshSpec {
    /// Generate the mesh with OpenFOAM's blockMesh.
    func build() throws -> Mesh { try FoamBlockMesh.build(try FoamBlockMesh.dictionary(self)) }
}

public extension CylinderOGridSpec {
    /// Generate the mesh with OpenFOAM's blockMesh.
    func build() throws -> Mesh { try FoamBlockMesh.build(try FoamBlockMesh.dictionary(self)) }
}

// MARK: - Prism layers (snappyHexMesh layer addition)

public enum FoamLayers {
    public struct Result: Sendable {
        public var mesh: Mesh
        public var summary: String
        /// Percentage of the requested layer thickness reached, per wall patch.
        public var coverage: [String: Double]
    }

    /// The snappyHexMeshDict that only adds layers (no castellation or snapping).
    static func dictionary(patches: [String], settings s: InflationSettings) -> String {
        var t = FoamFile.header("dictionary", "snappyHexMeshDict", location: "system")
        t += """
        castellatedMesh false;
        snap            false;
        addLayers       true;

        geometry {}

        castellatedMeshControls
        {
            maxLocalCells       2000000;
            maxGlobalCells      40000000;
            minRefinementCells  10;
            nCellsBetweenLevels 3;
            features            ();
            refinementSurfaces  {}
            resolveFeatureAngle 30;
            refinementRegions   {}
            locationInMesh      (0 0 0);
            allowFreeStandingZoneFaces true;
        }

        snapControls
        {
            nSmoothPatch 3;
            tolerance    2.0;
            nSolveIter   30;
            nRelaxIter   5;
        }

        addLayersControls
        {
            relativeSizes       false;
            firstLayerThickness \(FoamNum.s(s.firstHeight));
            expansionRatio      \(FoamNum.s(s.growth));
            minThickness        \(FoamNum.s(0.1 * s.firstHeight));
            layers
            {
                "(\(patches.joined(separator: "|")))" { nSurfaceLayers \(s.layers); }
            }
            nGrow                   0;
            featureAngle            130;
            slipFeatureAngle        30;
            nRelaxIter              5;
            nSmoothSurfaceNormals   1;
            nSmoothNormals          3;
            nSmoothThickness        10;
            maxFaceThicknessRatio   0.5;
            maxThicknessToMedialRatio 0.3;
            minMedialAxisAngle      90;
            nBufferCellsNoExtrude   0;
            nLayerIter              50;
            nRelaxedIter            20;
        }

        meshQualityControls
        {
            #includeEtc "caseDicts/meshQualityDict"
            minFaceWeight   0.02;
            minVolRatio     0.01;
            nSmoothScale    4;
            errorReduction  0.75;
            relaxed { maxNonOrtho 75; }
        }

        mergeTolerance 1e-6;

        """
        return t
    }

    /// Add prism layers on the wall patches of `mesh` with snappyHexMesh.
    public static func add(to mesh: Mesh, settings s: InflationSettings, environment: FoamEnvironment? = nil,
                           log: ((String) -> Void)? = nil) throws -> Result {
        let walls = mesh.boundaryZones.filter { s.zones.isEmpty ? $0.kind == .wall : s.zones.contains($0.name) }.map(\.name)
        guard !walls.isEmpty else { throw MeshError.topology("no wall patches to add layers to") }
        let env = try environment ?? FoamMeshTools.environment()
        let dir = try FoamMeshTools.scratchCase("layers")
        defer { try? FileManager.default.removeItem(at: dir) }
        try MeshWriters.writeFoamPolyMesh(mesh, caseDir: dir)
        let foamWalls = walls.map(MeshWriters.foamName)
        try dictionary(patches: foamWalls, settings: s).write(to: dir.appendingPathComponent("system/snappyHexMeshDict"), atomically: true, encoding: .utf8)
        log?("Adding \(s.layers) prism layers on \(walls.joined(separator: ", ")) with snappyHexMesh…")
        let metrics = try FoamMeshTools.run([FoamMeshTools.stage("snappyHexMesh", ["-overwrite"])], in: dir, environment: env, log: log)
        var names: [String: String] = [:], kinds: [String: ZoneKind] = [:], cellKinds: [String: CellZoneKind] = [:]
        for z in mesh.boundaryZones { names[MeshWriters.foamName(z.name)] = z.name; kinds[z.name] = z.kind }
        for z in mesh.cellZones { names[MeshWriters.foamName(z.name)] = z.name; cellKinds[z.name] = z.kind }
        let out = try FoamMeshTools.readBack(dir, names: names, kinds: kinds, cellKinds: cellKinds)
        var coverage: [String: Double] = [:]
        for (k, v) in metrics.layerCoverage { coverage[names[k] ?? k] = v }
        let added = out.nCells - mesh.nCells
        var summary = "snappyHexMesh layers: \(s.layers) requested (first \(FoamNum.s(s.firstHeight)) m, ratio \(FoamNum.s(s.growth))), \(added) cells added"
        if !coverage.isEmpty {
            summary += "; thickness reached " + coverage.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f%%", $0.key as NSString, $0.value) }.joined(separator: ", ")
        }
        return Result(mesh: out, summary: summary, coverage: coverage)
    }
}

/// Gmsh meshing; 3D meshes become OpenFOAM meshes through gmshToFoam, and get prism layers
/// from snappyHexMesh when the settings ask for them.
public enum FoamGmsh {
    public static func generate(_ s: MeshingSettings, environment: FoamEnvironment? = nil, workDir: URL? = nil,
                                log: ((String) -> Void)? = nil) throws -> GmshDriver.Result {
        var r = try GmshDriver.generate(s, workDir: workDir, log: log, reader: FoamMeshImport.gmshReader(environment: environment))
        guard let layers = s.inflation3D else { return r }
        let added = try FoamLayers.add(to: r.mesh, settings: layers, environment: environment, log: log)
        r.mesh = added.mesh
        r.layers = added.summary
        r.log += "\n" + added.summary
        return r
    }
}
