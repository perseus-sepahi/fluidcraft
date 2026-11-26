import Foundation
import FluidCraftMesh
import FluidCraftSolver

/// snappyHexMesh settings for meshing a CAD body (hex-dominant cells snapped to the surface,
/// with prism layers). Sizes are in metres after unit conversion.
public struct SnappySettings: Codable, Sendable, Equatable {
    public var path = ""
    public var unit: CADUnit = .metre
    /// External flow around the body (box domain) or internal flow (the body is the fluid).
    public var external = true
    public var flowAxis = 0
    /// Domain padding in body lengths: -x, +x, -y, +y, -z, +z (external flow).
    public var padding: [Double] = [3, 8, 3, 3, 3, 3]
    /// Background (level 0) cell size; 0 = automatic from the body size.
    public var baseCellSize = 0.0
    public var surfaceLevelMin = 3
    public var surfaceLevelMax = 4
    public var featureLevel = 4
    /// Facets meeting at less than this angle [deg] form a feature edge (surfaceFeatureExtract).
    public var includedAngle = 150.0
    public var resolveFeatureAngle = 30.0
    public var nCellsBetweenLevels = 3
    /// Refinement box around the body and its wake (external flow).
    public var refinementBox = true
    /// The refinement box's corners [xmin, ymin, zmin, xmax, ymax, zmax] (metres); nil = around the body and wake.
    public var customRefinementBox: [Double]? = nil
    public var refinementBoxLevel = 2
    /// Box size in body lengths around the body; the wake extends `wakeLength` downstream.
    public var refinementBoxPadding = 0.5
    public var wakeLength = 2.0
    // Prism layers
    public var layers = 3
    public var expansionRatio = 1.2
    /// relativeSizes: thickness of the last layer as a fraction of the local cell size.
    public var finalLayerThickness = 0.5
    public var minThickness = 0.1
    /// Absolute first-layer height [m] instead of relative sizes (0 = relative).
    public var firstLayerThickness = 0.0
    // Quality
    public var maxNonOrtho = 65.0
    public var maxInternalSkewness = 4.0
    public var maxBoundarySkewness = 20.0
    public var cores = 1
    /// Explicit locationInMesh (empty = automatic).
    public var locationInMesh: [Double] = []
    /// Converter command for native CAD formats (`{input}`, `{output}`); empty = Settings/env.
    /// Never encoded or decoded: a command line must come from the user, not from a file.
    public var converter: String = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case path, unit, external, flowAxis, padding, baseCellSize, surfaceLevelMin, surfaceLevelMax, featureLevel
        case includedAngle, resolveFeatureAngle, nCellsBetweenLevels, refinementBox, refinementBoxLevel
        case refinementBoxPadding, wakeLength, layers, expansionRatio, finalLayerThickness, minThickness
        case firstLayerThickness, maxNonOrtho, maxInternalSkewness, maxBoundarySkewness, cores, locationInMesh
    }
}

public struct SnappyResult: Sendable {
    public var mesh: Mesh
    public var caseDirectory: URL
    public var summary: String
}

public enum SnappyMesher {

    /// Mesh a CAD file with snappyHexMesh in `workDir` (must not contain spaces).
    public static func mesh(_ s: SnappySettings, workDir: URL, environment env: FoamEnvironment,
                            log: @escaping (String) -> Void, cancel: (() -> Bool)? = nil) throws -> SnappyResult {
        try FoamLocations.validate(workDir)
        guard let fmt = CADFormat.detect(URL(fileURLWithPath: s.path)) else {
            throw MeshError.unsupported("unknown CAD format '\((s.path as NSString).pathExtension)'")
        }
        // 1. Surface
        var surf: TriSurface
        var probe: TriSurface
        // FreeCAD and native formats → B-rep
        var s = s
        s.path = try CADConversion.prepare(s.path, converter: s.converter.isEmpty ? CADConversion.defaultConverter : s.converter, workDir: workDir)
        if fmt.isBRep {
            // rough size first, to choose the tessellation size
            log("Tessellating \(fmt.displayName) with Gmsh…\n")
            probe = try GmshDriver.tessellate(path: s.path, unit: s.unit, minSize: 1e-9, maxSize: 1e9, workDir: workDir.appendingPathComponent("tessellate"))
        } else {
            probe = try SurfaceReader.read(url: URL(fileURLWithPath: s.path), unit: s.unit)
        }
        let (lo0, hi0) = probe.bounds
        let L = max((hi0 - lo0).x, (hi0 - lo0).y, (hi0 - lo0).z)
        guard L > 0 else { throw MeshError.topology("CAD body has zero size") }
        let base = s.baseCellSize > 0 ? s.baseCellSize : (s.external ? L / 6 : L / 25)
        let finest = base / pow(2, Double(max(s.surfaceLevelMax, s.featureLevel)))
        if fmt.isBRep {
            surf = try GmshDriver.tessellate(path: s.path, unit: s.unit, minSize: finest / 8, maxSize: finest, workDir: workDir.appendingPathComponent("tessellate"))
        } else {
            surf = probe
        }
        if !s.external { surf = surf.splitForInternalFlow(axis: s.flowAxis) }
        let open = surf.openOrNonManifoldEdges
        if open > 0 {
            log("Warning: the surface has \(open) open or non-manifold edges; snappyHexMesh needs a closed surface to separate inside from outside.\n")
        }
        // Region names must not clash with the background-block patches.
        let reserved: Set<String> = s.external ? ["inlet", "outlet", "farfield"] : []
        surf.regionNames = surf.regionNames.map { reserved.contains($0) ? "body_" + $0 : $0 }
        surf.sanitizeRegionNames()

        // 2. Domain
        let (lo, hi) = surf.bounds
        var dmin = lo, dmax = hi
        if s.external {
            let p = s.padding.count == 6 ? s.padding : [3, 8, 3, 3, 3, 3]
            for a in 0..<3 { dmin[a] = lo[a] - p[2 * a] * L; dmax[a] = hi[a] + p[2 * a + 1] * L }
        } else {
            for a in 0..<3 { dmin[a] = lo[a] - 0.02 * L - 0.5 * base; dmax[a] = hi[a] + 0.02 * L + 0.5 * base }
        }
        let size = dmax - dmin
        let n = (0..<3).map { max(1, Int((size[$0] / base).rounded(.up))) }
        let backgroundCells = n[0] * n[1] * n[2]
        guard backgroundCells < 30_000_000 else { throw MeshError.unsupported("background mesh would have \(backgroundCells) cells; increase the base cell size") }

        // 3. locationInMesh
        let loc: Vec3
        if s.locationInMesh.count == 3 {
            loc = Vec3(s.locationInMesh[0], s.locationInMesh[1], s.locationInMesh[2])
        } else {
            loc = try locationInMesh(surf, external: s.external, axis: s.flowAxis, domainMin: dmin, domainMax: dmax, cell: base)
        }
        log(String(format: "Background mesh %d × %d × %d (cell %.4g m); locationInMesh (%.5g %.5g %.5g)\n", n[0], n[1], n[2], base, loc.x, loc.y, loc.z))

        // 4. Case files
        let fm = FileManager.default
        try? fm.removeItem(at: workDir.appendingPathComponent("constant"))
        for d in ["constant/triSurface", "system"] { try fm.createDirectory(at: workDir.appendingPathComponent(d), withIntermediateDirectories: true) }
        try SurfaceWriter.stl(surf).write(to: workDir.appendingPathComponent("constant/triSurface/body.stl"), atomically: true, encoding: .utf8)
        try writeDicts(s, surf: surf, workDir: workDir, dmin: dmin, dmax: dmax, n: n, loc: loc, L: L, lo: lo, hi: hi)

        // 5. Run
        let par = s.cores > 1
        var stages: [FoamStage] = [
            FoamStage(id: "surfaceFeatureExtract", title: "Feature edges", command: "surfaceFeatureExtract", arguments: [], parallel: false, logName: "surfaceFeatureExtract"),
            FoamStage(id: "blockMesh", title: "Background mesh", command: "blockMesh", arguments: [], parallel: false, logName: "blockMesh"),
        ]
        if par {
            stages.append(FoamStage(id: "decomposePar", title: "Decompose", command: "decomposePar", arguments: ["-force"], parallel: false, logName: "decomposePar"))
            stages.append(FoamStage(id: "snappyHexMesh", title: "snappyHexMesh", command: "snappyHexMesh", arguments: ["-overwrite"], parallel: true, logName: "snappyHexMesh"))
            stages.append(FoamStage(id: "reconstructParMesh", title: "Reconstruct mesh", command: "reconstructParMesh", arguments: ["-constant"], parallel: false, logName: "reconstructParMesh"))
        } else {
            stages.append(FoamStage(id: "snappyHexMesh", title: "snappyHexMesh", command: "snappyHexMesh", arguments: ["-overwrite"], parallel: false, logName: "snappyHexMesh"))
        }
        stages.append(FoamStage(id: "checkMesh", title: "Check mesh", command: "checkMesh", arguments: ["-constant"], parallel: false, logName: "checkMesh"))
        for item in (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? [] where item.hasPrefix("processor") || item.hasPrefix("log.") {
            try? fm.removeItem(at: workDir.appendingPathComponent(item))
        }
        let report = FoamCaseReport(application: .simpleFoam, turbulence: .laminar, cores: max(1, s.cores), runsPotentialFoam: false,
                                    kinematicPressure: true, density: 1, operatingPressure: 0)
        let runner = FoamRunner(environment: env, caseDirectory: workDir, report: report)
        var lastStage = ""
        let failure = runner.run(stages) { e in
            switch e {
            case .stage(let st): lastStage = st.title; log("— \(st.title)\n")
            case .line(let l):
                if l.contains("FOAM FATAL") || l.hasPrefix("Layer mesh") || l.contains("Finished meshing") || l.hasPrefix("Mesh OK")
                    || l.contains("Failed") || l.hasPrefix("    cells:") || l.hasPrefix("Snapped mesh") || l.hasPrefix("Castellated mesh") {
                    log(l + "\n")
                }
            case .stageFinished(let st, _, let sec): log(String(format: "  %@ done (%.1f s)\n", st.title as NSString, sec))
            case .step: break
            }
            if cancel?() == true { runner.cancel() }
        }
        let m = runner.metrics
        if let failure {
            // checkMesh failing is reported but a snapped mesh is still usable
            if lastStage != "Check mesh" { throw SolverError(failure) }
            log("checkMesh: \(m.failedChecks) failed check(s) — the mesh may still run; see log.checkMesh.\n")
        }
        // 6. Read back
        let mesh = try FoamMeshReader.read(url: workDir)
        for (i, z) in mesh.boundaryZones.enumerated() where z.kind != .wall {
            mesh.updateBoundaryZone(i, kind: ZoneKind.guess(fromName: z.name))
        }
        var summary = "snappyHexMesh: \(mesh.nCells) cells"
        if let ok = m.checkMeshOK { summary += ok ? ", checkMesh OK" : ", checkMesh: \(m.failedChecks) failed check(s)" }
        if let no = m.maxNonOrthogonality { summary += String(format: ", max non-orthogonality %.1f°", no) }
        if !m.layerCoverage.isEmpty {
            summary += ", layer coverage " + m.layerCoverage.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f%%", $0.key as NSString, $0.value) }.joined(separator: ", ")
        }
        return SnappyResult(mesh: mesh, caseDirectory: workDir, summary: summary)
    }

    /// A point inside the fluid, off any background-cell face.
    static func locationInMesh(_ surf: TriSurface, external: Bool, axis: Int, domainMin: Vec3, domainMax: Vec3, cell: Double) throws -> Vec3 {
        let jitter = Vec3(0.01371, 0.02193, 0.03117) * cell
        let (lo, hi) = surf.bounds
        if external {
            var p = 0.5 * (lo + hi) + jitter
            p[axis] = 0.5 * (domainMin[axis] + lo[axis]) + jitter[axis]
            if !surf.contains(p) { return p }
            let q = domainMin + 0.23 * (domainMax - domainMin) + jitter
            if !surf.contains(q) { return q }
            throw MeshError.topology("could not find a point outside the body for locationInMesh")
        }
        var best: Vec3? = nil, bestD = 0.0
        let k = 7
        for i in 1...k { for j in 1...k { for l in 1...k {
            let t = Vec3(Double(i), Double(j), Double(l)) / Double(k + 1)
            let p = lo + t * (hi - lo) + jitter
            guard surf.contains(p) else { continue }
            let d = surf.distance(to: p)
            if d > bestD { bestD = d; best = p }
        } } }
        guard let b = best else { throw MeshError.topology("could not find a point inside the body for locationInMesh (is the surface closed?)") }
        return b
    }

    static func writeDicts(_ s: SnappySettings, surf: TriSurface, workDir: URL, dmin: Vec3, dmax: Vec3, n: [Int], loc: Vec3,
                           L: Double, lo: Vec3, hi: Vec3) throws {
        func put(_ path: String, _ text: String) throws {
            try text.write(to: workDir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let v: (Vec3) -> String = { FoamNum.vec($0) }
        // blockMeshDict
        let c = [Vec3(dmin.x, dmin.y, dmin.z), Vec3(dmax.x, dmin.y, dmin.z), Vec3(dmax.x, dmax.y, dmin.z), Vec3(dmin.x, dmax.y, dmin.z),
                 Vec3(dmin.x, dmin.y, dmax.z), Vec3(dmax.x, dmin.y, dmax.z), Vec3(dmax.x, dmax.y, dmax.z), Vec3(dmin.x, dmax.y, dmax.z)]
        let faces: [[Int]] = [[0, 4, 7, 3], [2, 6, 5, 1], [1, 5, 4, 0], [3, 7, 6, 2], [0, 3, 2, 1], [4, 5, 6, 7]]  // -x +x -y +y -z +z
        var patches: [(String, String, [[Int]])] = []
        if s.external {
            let a = max(0, min(2, s.flowAxis))
            patches.append(("inlet", "patch", [faces[2 * a]]))
            patches.append(("outlet", "patch", [faces[2 * a + 1]]))
            patches.append(("farfield", "patch", (0..<6).filter { $0 / 2 != a }.map { faces[$0] }))
        } else {
            patches.append(("background", "patch", faces))
        }
        var bm = FoamFile.header("dictionary", "blockMeshDict", location: "system")
        bm += "scale 1;\n\nvertices\n(\n" + c.map { "    " + v($0) }.joined(separator: "\n") + "\n);\n\n"
        bm += "blocks\n(\n    hex (0 1 2 3 4 5 6 7) (\(n[0]) \(n[1]) \(n[2])) simpleGrading (1 1 1)\n);\n\nedges ();\n\nboundary\n(\n"
        for (name, type, fs) in patches {
            bm += "    \(name)\n    {\n        type \(type);\n        faces\n        (\n" + fs.map { "            (\($0.map(String.init).joined(separator: " ")))" }.joined(separator: "\n") + "\n        );\n    }\n"
        }
        bm += ");\n\nmergePatchPairs ();\n"
        try put("system/blockMeshDict", bm)

        try put("system/controlDict", FoamFile.header("dictionary", "controlDict", location: "system") +
                "application snappyHexMesh;\nstartFrom startTime;\nstartTime 0;\nstopAt endTime;\nendTime 1;\ndeltaT 1;\nwriteControl timeStep;\nwriteInterval 1;\nwriteFormat binary;\nwritePrecision 12;\nwriteCompression off;\ntimeFormat general;\nrunTimeModifiable false;\n")
        try put("system/fvSchemes", FoamFile.header("dictionary", "fvSchemes", location: "system") +
                "ddtSchemes { default steadyState; }\ngradSchemes { default Gauss linear; }\ndivSchemes { default none; }\nlaplacianSchemes { default Gauss linear corrected; }\ninterpolationSchemes { default linear; }\nsnGradSchemes { default corrected; }\n")
        try put("system/fvSolution", FoamFile.header("dictionary", "fvSolution", location: "system") + "solvers {}\n")
        let split = Writerless.factor(max(1, s.cores), size: dmax - dmin)
        try put("system/decomposeParDict", FoamFile.header("dictionary", "decomposeParDict", location: "system") +
                "numberOfSubdomains \(max(1, s.cores));\nmethod scotch;\ncoeffs { n (\(split.0) \(split.1) \(split.2)); }\n")
        try put("system/surfaceFeatureExtractDict", FoamFile.header("dictionary", "surfaceFeatureExtractDict", location: "system") + """
        body.stl
        {
            extractionMethod    extractFromSurface;
            includedAngle       \(FoamNum.s(s.includedAngle));
            subsetFeatures
            {
                nonManifoldEdges    no;
                openEdges           yes;
            }
            writeObj            no;
        }

        """)

        // snappyHexMeshDict
        let regionRename = surf.regionNames.map { "                \($0) { name \($0); }" }.joined(separator: "\n")
        func patchType(_ r: String) -> String {
            if s.external { return "wall" }
            let l = r.lowercased()
            return l.contains("inlet") || l.contains("outlet") || l.contains("symm") ? "patch" : "wall"
        }
        let refinementRegions = surf.regionNames.map { r in
            let lv = patchType(r) == "wall" ? "(\(s.surfaceLevelMin) \(s.surfaceLevelMax))" : "(\(s.surfaceLevelMin) \(s.surfaceLevelMin))"
            return "                \(r) { level \(lv); patchInfo { type \(patchType(r)); } }"
        }.joined(separator: "\n")
        let wallRegions = surf.regionNames.filter { patchType($0) == "wall" }
        var boxMin = lo, boxMax = hi
        if s.external {
            for a in 0..<3 { boxMin[a] = max(dmin[a], lo[a] - s.refinementBoxPadding * L); boxMax[a] = min(dmax[a], hi[a] + s.refinementBoxPadding * L) }
            boxMax[s.flowAxis] = min(dmax[s.flowAxis], hi[s.flowAxis] + s.wakeLength * L)
        }
        if let cb = s.customRefinementBox, cb.count == 6 {
            boxMin = Vec3(cb[0], cb[1], cb[2]); boxMax = Vec3(cb[3], cb[4], cb[5])
        }
        let useBox = (s.external && s.refinementBox) || s.customRefinementBox?.count == 6
        let layersOn = s.layers > 0 && !wallRegions.isEmpty
        let layerThickness = s.firstLayerThickness > 0
            ? "relativeSizes   false;\n    firstLayerThickness \(FoamNum.s(s.firstLayerThickness));\n    minThickness    \(FoamNum.s(s.firstLayerThickness * 0.1));"
            : "relativeSizes   true;\n    finalLayerThickness \(FoamNum.s(s.finalLayerThickness));\n    minThickness    \(FoamNum.s(s.minThickness));"
        var sh = FoamFile.header("dictionary", "snappyHexMeshDict", location: "system")
        sh += """
        castellatedMesh true;
        snap            true;
        addLayers       \(layersOn ? "true" : "false");

        geometry
        {
            body.stl
            {
                type    triSurfaceMesh;
                name    body;
                regions
                {
        \(regionRename)
                }
            }
        \(useBox ? "    refinementBox\n    {\n        type searchableBox;\n        min \(v(boxMin));\n        max \(v(boxMax));\n    }\n" : "")}

        castellatedMeshControls
        {
            maxLocalCells       2000000;
            maxGlobalCells      40000000;
            minRefinementCells  10;
            maxLoadUnbalance    0.10;
            nCellsBetweenLevels \(s.nCellsBetweenLevels);

            features
            (
                { file "body.eMesh"; level \(s.featureLevel); }
            );

            refinementSurfaces
            {
                body
                {
                    level (\(s.surfaceLevelMin) \(s.surfaceLevelMax));
                    patchInfo { type wall; }
                    regions
                    {
        \(refinementRegions)
                    }
                }
            }

            resolveFeatureAngle \(FoamNum.s(s.resolveFeatureAngle));

            refinementRegions
            {
        \(useBox ? "        refinementBox { mode inside; levels ((1e15 \(s.refinementBoxLevel))); }" : "")
            }

            locationInMesh \(v(loc));
            allowFreeStandingZoneFaces true;
        }

        snapControls
        {
            nSmoothPatch            3;
            tolerance               2.0;
            nSolveIter              50;
            nRelaxIter              5;
            nFeatureSnapIter        10;
            implicitFeatureSnap     false;
            explicitFeatureSnap     true;
            multiRegionFeatureSnap  \(surf.regionNames.count > 1 ? "true" : "false");
        }

        addLayersControls
        {
            \(layerThickness)
            layers
            {
                "(\(wallRegions.joined(separator: "|")))" { nSurfaceLayers \(s.layers); }
            }
            expansionRatio          \(FoamNum.s(s.expansionRatio));
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
        }

        meshQualityControls
        {
            #includeEtc "caseDicts/meshQualityDict"
            maxNonOrtho             \(FoamNum.s(s.maxNonOrtho));
            maxBoundarySkewness     \(FoamNum.s(s.maxBoundarySkewness));
            maxInternalSkewness     \(FoamNum.s(s.maxInternalSkewness));
            minFaceWeight           0.02;
            minVolRatio             0.01;
            nSmoothScale            4;
            errorReduction          0.75;
        }

        mergeTolerance 1e-6;

        """
        try put("system/snappyHexMeshDict", sh)
    }
}

/// Shared helper (decomposition split) without the case writer's state.
enum Writerless {
    static func factor(_ n: Int, size: Vec3) -> (Int, Int, Int) {
        var c = [1, 1, 1]
        var rem = n, f = 2
        while rem > 1 {
            while rem % f != 0 { f += 1 }
            let l = [size.x / Double(c[0]), size.y / Double(c[1]), size.z / Double(c[2])]
            let i = l.firstIndex(of: l.max()!)!
            c[i] *= f
            rem /= f
        }
        return (c[0], c[1], c[2])
    }
}
