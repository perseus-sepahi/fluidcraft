import Testing
import Foundation
@testable import FluidCraftMesh
@testable import FluidCraftSolver
@testable import FluidCraftFoam

private func tempDir(_ tag: String) -> URL {
    // no spaces: OpenFOAM refuses them
    URL(fileURLWithPath: "/tmp").appendingPathComponent("fluidcraft-\(tag)-\(UUID().uuidString.prefix(8))")
}

/// Unit cube [0,1]^3 as 12 outward triangles, two regions ("bottom" = z=0 face, "rest").
private func cubeSurface() -> TriSurface {
    let p = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1)]
    let quads: [[Int32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [0, 4, 7, 3], [1, 2, 6, 5]]
    var s = TriSurface(points: p, regionNames: ["bottom", "rest"])
    for (i, q) in quads.enumerated() {
        s.triangles += [q[0], q[1], q[2], q[0], q[2], q[3]]
        s.triRegion += [i == 0 ? 0 : 1, i == 0 ? 0 : 1]
    }
    return s
}

@Suite struct SurfaceImportTests {
    @Test func cubeGeometry() {
        let c = cubeSurface()
        #expect(abs(c.signedVolume - 1) < 1e-12)
        #expect(abs(c.area - 6) < 1e-12)
        #expect(c.openOrNonManifoldEdges == 0)
        #expect(c.contains(Vec3(0.5, 0.4, 0.3)))
        #expect(!c.contains(Vec3(1.5, 0.4, 0.3)))
        #expect(abs(c.distance(to: Vec3(0.5, 0.5, 0.5)) - 0.5) < 1e-12)
    }

    @Test func formatsRoundTrip() throws {
        let c = cubeSurface()
        let dir = tempDir("surf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // ASCII STL with two solids
        try SurfaceWriter.stl(c).write(to: dir.appendingPathComponent("cube.stl"), atomically: true, encoding: .utf8)
        // binary STL
        var bin = Data(count: 80)
        var n = UInt32(c.triangleCount).littleEndian
        withUnsafeBytes(of: &n) { bin.append(contentsOf: $0) }
        for t in 0..<c.triangleCount {
            let (a, b, d) = c.corners(t)
            var vals: [Float32] = [0, 0, 0] + [a, b, d].flatMap { [Float32($0.x), Float32($0.y), Float32($0.z)] }
            vals.withUnsafeBytes { bin.append(contentsOf: $0) }
            bin.append(contentsOf: [0, 0])
        }
        try bin.write(to: dir.appendingPathComponent("cube_bin.stl"))
        // OBJ (quads, v//vn indices), OFF, ASCII PLY
        var obj = "o cube\n"
        for p in c.points { obj += "v \(p.x) \(p.y) \(p.z)\n" }
        for q in [[1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [3, 4, 8, 7], [1, 5, 8, 4], [2, 3, 7, 6]] { obj += "f " + q.map { "\($0)//1" }.joined(separator: " ") + "\n" }
        try obj.write(to: dir.appendingPathComponent("cube.obj"), atomically: true, encoding: .utf8)
        var off = "OFF\n8 12 0\n"
        for p in c.points { off += "\(p.x) \(p.y) \(p.z)\n" }
        for t in 0..<c.triangleCount { off += "3 \(c.triangles[3 * t]) \(c.triangles[3 * t + 1]) \(c.triangles[3 * t + 2])\n" }
        try off.write(to: dir.appendingPathComponent("cube.off"), atomically: true, encoding: .utf8)
        var ply = "ply\nformat ascii 1.0\nelement vertex 8\nproperty float x\nproperty float y\nproperty float z\nelement face 12\nproperty list uchar int vertex_indices\nend_header\n"
        for p in c.points { ply += "\(p.x) \(p.y) \(p.z)\n" }
        for t in 0..<c.triangleCount { ply += "3 \(c.triangles[3 * t]) \(c.triangles[3 * t + 1]) \(c.triangles[3 * t + 2])\n" }
        try ply.write(to: dir.appendingPathComponent("cube.ply"), atomically: true, encoding: .utf8)

        for name in ["cube.stl", "cube_bin.stl", "cube.obj", "cube.off", "cube.ply"] {
            let s = try SurfaceReader.read(url: dir.appendingPathComponent(name))
            #expect(s.triangleCount == 12, "\(name)")
            #expect(s.points.count == 8, "\(name): welded points")
            #expect(abs(s.signedVolume - 1) < 1e-6, "\(name)")
            #expect(s.openOrNonManifoldEdges == 0, "\(name)")
        }
        #expect(try SurfaceReader.read(url: dir.appendingPathComponent("cube.stl")).regionNames == ["bottom", "rest"])
        #expect(try SurfaceReader.read(url: dir.appendingPathComponent("cube.obj")).regionNames == ["cube"])
        // units: millimetres → metres
        let mm = try SurfaceReader.read(url: dir.appendingPathComponent("cube.off"), unit: .millimetre)
        #expect(abs(mm.signedVolume - 1e-9) < 1e-15)
    }

    @Test func insideOutSurfaceIsReoriented() throws {
        var c = cubeSurface()
        for t in 0..<c.triangleCount { c.triangles.swapAt(3 * t + 1, 3 * t + 2) }
        #expect(c.signedVolume < 0)
        let dir = tempDir("flip")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try SurfaceWriter.stl(c).write(to: dir.appendingPathComponent("f.stl"), atomically: true, encoding: .utf8)
        #expect(try SurfaceReader.read(url: dir.appendingPathComponent("f.stl")).signedVolume > 0)
    }

    @Test func internalFlowSplit() {
        let s = cubeSurface().splitForInternalFlow(axis: 0)
        let count = { (n: String) in s.triRegion.filter { s.regionNames[Int($0)] == n }.count }
        #expect(count("inlet") == 2 && count("outlet") == 2 && count("wall") == 8)
    }

    @Test func detectsCADFormats() {
        #expect(CADFormat.detect(URL(fileURLWithPath: "a.STEP")) == .step)
        #expect(CADFormat.detect(URL(fileURLWithPath: "a.igs"))?.isBRep == true)
        #expect(CADFormat.detect(URL(fileURLWithPath: "a.3mf")) == .threeMF)
        #expect(CADFormat.detect(URL(fileURLWithPath: "a.dwg")) == nil)
    }
}

@Suite struct FoamFileTests {
    @Test func asciiFieldFile() throws {
        let text = """
        FoamFile { version 2.0; format ascii; class volVectorField; object U; }
        // comment
        dimensions [0 1 -1 0 0 0 0];
        internalField nonuniform List<vector> 3((1 0 0) (2 0 0) (3 -1e-3 0));
        boundaryField
        {
            inlet { type fixedValue; value uniform (1 0 0); }
            outlet { type zeroGradient; }
            wall { type noSlip; }
            /* block comment */
            side { type calculated; value nonuniform List<vector> 2{(0 0 5)}; }
            frontAndBack { type empty; }
        }
        """
        let f = try FoamFieldReader.parse(Data(text.utf8))
        #expect(f.className == "volVectorField")
        let u = f.internalField?.vectors(count: 3)
        #expect(u?[2] == Vec3(3, -1e-3, 0))
        #expect(f.patchValues["inlet"]?.vectors(count: 4)?[3] == Vec3(1, 0, 0))
        #expect(f.patchValues["side"]?.vectors(count: 2) == [Vec3(0, 0, 5), Vec3(0, 0, 5)])
        #expect(f.patchValues["outlet"] == nil)
        #expect(f.patchTypes["wall"] == "noSlip")
    }

    @Test func binaryFieldFile() throws {
        var d = Data("FoamFile\n{\n    format binary;\n    class volScalarField;\n    arch \"LSB;label=32;scalar=64\";\n}\ninternalField nonuniform List<scalar> 3(".utf8)
        var vals: [Double] = [0.5, -2, 1e-300]
        vals.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(Data(");\nboundaryField\n{\n    a { type fixedValue; value nonuniform List<scalar> 2(".utf8))
        var two: [Double] = [7, 8]
        two.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(Data("); }\n}\n".utf8))
        let f = try FoamFieldReader.parse(d)
        #expect(f.internalField?.scalars(count: 3) == [0.5, -2, 1e-300])
        #expect(f.patchValues["a"]?.scalars(count: 2) == [7, 8])
    }

    @Test func logParser() {
        var p = FoamLogParser()
        var m = FoamRunMetrics()
        let lines = [
            "Time = 12",
            "smoothSolver:  Solving for Ux, Initial residual = 0.25, Final residual = 0.01, No Iterations 3",
            "smoothSolver:  Solving for Ux, Initial residual = 0.1, Final residual = 0.01, No Iterations 3",
            "GAMG:  Solving for p, Initial residual = 1e-3, Final residual = 1e-5, No Iterations 7",
            "forceCoeffs cd write:",
            "    Coefficient\tTotal\tPressure\tViscous\tInternal",
            "    Cd:\t0.4213\t0.3\t0.1213\t0",
            "forces drag write:",
            "    Sum of forces",
            "        Total    : (1.5 -2 0)",
            "        Pressure : (1 0 0)",
            "surfaceFieldValue inletP write:",
            "    areaAverage(inlet) of p = 0.51",
            "    sum(outlet) of phi = -0.02",
            "--> FOAM FATAL ERROR: (openfoam-2606)",
            "cannot find file",
            "FOAM exiting",
        ]
        for l in lines { for e in p.parse(l) { m.apply(e) } }
        #expect(m.currentTime == 12)
        #expect(m.residuals["Ux"]?.count == 1 && m.residuals["Ux"]?.first?.value == 0.25)
        #expect(m.latestResiduals["p"] == 1e-3)
        #expect(m.functionValues["cd/Cd"] == 0.4213)
        #expect(m.functionVectors["drag/force"] == Vec3(1.5, -2, 0))
        #expect(m.functionValues["inletP/areaAverage(p)"] == 0.51)
        #expect(m.functionValues["inletP/sum(phi)"] == -0.02)
        #expect(m.fatal?.contains("cannot find file") == true)
        #expect(FoamRunner.fluidcraftName(forField: "p_rgh") == "continuity")
    }

    @Test func lenientCaseJSON() throws {
        let json = """
        { "general": { "backend": "openfoam" },
          "openfoam": { "cores": 4, "application": "pimpleFoam", "schemes": { "divU": "Gauss linear" },
                        "patchOverrides": [ { "patch": "inlet", "text": "type zeroGradient;" } ],
                        "customStages": [ { "command": "postProcess -func Q" } ] } }
        """
        let s = try CaseSetup.decodeLenient(Data(json.utf8))
        #expect(s.openfoam.cores == 4 && s.openfoam.application == .pimpleFoam)
        #expect(s.openfoam.schemes.divU == "Gauss linear" && s.openfoam.schemes.wallDistance == "meshWave")
        #expect(s.openfoam.patchOverrides.first?.field == "U")
        #expect(s.openfoam.customStages.first?.phase == .afterSolve)
        // old case files without the new keys still decode
        let old = try CaseSetup.decodeLenient(Data("{ \"title\": \"x\" }".utf8))
        #expect(old.openfoam == FoamSettings())
    }
}

@Suite struct FoamCaseWriterTests {
    func read(_ dir: URL, _ path: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    @Test func cavityCase() throws {
        let (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 8)
        let dir = tempDir("cav")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir)
        #expect(r.application == .simpleFoam && r.turbulence == .laminar)
        #expect(read(dir, "system/controlDict").contains("application     simpleFoam;"))
        #expect(read(dir, "system/fvSchemes").contains("div(phi,U)"))
        #expect(read(dir, "system/fvSolution").contains("pRefCell"))   // closed cavity
        #expect(read(dir, "constant/polyMesh/boundary").contains("empty"))
        let u = try FoamFieldReader.read(url: dir.appendingPathComponent("0/U"))
        // the moving lid is the only patch with a nonzero velocity
        #expect(u.patchValues.values.contains { ($0.vectors(count: 1)?.first.map { norm($0) } ?? 0) > 0.5 })
        #expect(u.patchTypes.values.contains("noSlip"))
        let back = try FoamMeshReader.read(url: dir, preserveOrder: true)
        #expect(back.nCells == mesh.nCells && back.nFaces == mesh.nFaces && back.owner == mesh.owner && back.neighbour == mesh.neighbour)
    }

    @Test func applicationSelection() throws {
        var (mesh, s) = try Benchmarks.cavityCase(re: 100, cells: 8)
        s.models.viscous = .kOmegaSST
        #expect(FoamCaseWriter.resolvedApplication(s) == .simpleFoam)
        s.general.time = .transient
        #expect(FoamCaseWriter.resolvedApplication(s) == .pimpleFoam)
        s.models.energy = true
        #expect(FoamCaseWriter.resolvedApplication(s) == .buoyantBoussinesqPimpleFoam)
        let zone = s.cellZones.keys.first!
        var gas = Material(name: "gas"); gas.densityMethod = .idealGas
        s.materials.append(gas); s.cellZones[zone]!.material = "gas"
        #expect(FoamCaseWriter.resolvedApplication(s) == .rhoPimpleFoam)
        s.general.solver = .densityBased
        #expect(FoamCaseWriter.resolvedApplication(s) == .rhoCentralFoam)
        let dir = tempDir("rho")
        defer { try? FileManager.default.removeItem(at: dir) }
        s.general.solver = .pressureBased
        try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        #expect(read(dir, "constant/thermophysicalProperties").contains("hePsiThermo"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("0/alphat").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("0/omega").path))
        _ = mesh
    }

    @Test func boussinesqCase() throws {
        let (mesh, setup, _) = try Benchmarks.naturalConvectionCase(log10Ra: 4, cells: 8)
        let dir = tempDir("nc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir)
        #expect(r.application == .buoyantBoussinesqSimpleFoam)
        let tp = read(dir, "constant/transportProperties")
        #expect(tp.contains("beta") && tp.contains("TRef"))
        #expect(read(dir, "0/p_rgh").contains("fixedFluxPressure"))
        #expect(read(dir, "0/T").contains("uniform 301"))
    }

    @Test func reportsBecomeFunctionObjects() throws {
        var (mesh, s) = try Benchmarks.cavityCase(re: 100, cells: 8)
        var cd = ReportDefinition(name: "drag", kind: .dragCoefficient); cd.zones = [mesh.boundaryZones[0].name]
        var avg = ReportDefinition(name: "p avg", kind: .areaWeightedAverage); avg.zones = [mesh.boundaryZones[1].name]
        s.reports = [cd, avg]
        let dir = tempDir("rep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let cdict = read(dir, "system/controlDict")
        #expect(cdict.contains("type            forceCoeffs;") && cdict.contains("type            surfaceFieldValue;"))
        #expect(r.liveReports.map(\.key) == ["drag/Cd", "p_avg/areaAverage(p)"])
    }

    @Test(.enabled(if: hasOpenFOAM)) func resultsRoundTrip() throws {
        // Fields written by FluidCraft must load back exactly (unit conversions included).
        var (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 8)
        setup.initialization.method = .standard
        setup.initialization.velocity = [.expression("x*y"), .expression("x-y"), 0]
        setup.initialization.gaugePressure = .expression("3*x + y")
        let solver = try Solution(mesh: mesh, setup: setup)
        solver.loadInitialFields()
        let dir = tempDir("res")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir, initial: solver.state)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("0"), to: dir.appendingPathComponent("30"))
        let loaded = try FoamResults.load(caseDirectory: dir, mesh: mesh, setup: setup)
        #expect(loaded.timeName == "30" && loaded.solution.iteration == 30)
        let st = solver.state
        let du = zip(loaded.solution.u, st.u).map { norm($0 - $1) }.max()!
        let dp = zip(loaded.solution.p, st.p).map { abs($0 - $1) }.max()!
        #expect(du < 1e-9 && dp < 1e-9)
        let (s2, _) = try FoamSolve.load(caseDirectory: dir, mesh: mesh, setup: setup)
        #expect(abs(Reports.evaluate(ReportDefinition(name: "a", kind: .volumeAverage), solver: s2)
                    - Reports.evaluate(ReportDefinition(name: "a", kind: .volumeAverage), solver: solver)) < 1e-9)
    }
}

/// Runs only where an OpenFOAM installation is present.
@Suite struct FoamIntegrationTests {
    @Test(.enabled(if: !FoamDiscovery.discover().isEmpty))
    func cavityMatchesGhia() throws {
        var (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 32)
        setup.openfoam.caseDirectory = tempDir("it-cavity").path
        setup.openfoam.initialFields = .uniform
        setup.run.iterations = 2000
        defer { try? FileManager.default.removeItem(atPath: setup.openfoam.caseDirectory) }
        let out = try FoamSolve(mesh: mesh, setup: setup).run(initial: nil, log: { _ in }, progress: { _, _, _, _ in })
        #expect(out.failure == nil)
        let solver = try #require(out.solution)
        #expect(!out.residuals.iterations.isEmpty)
        for c in Benchmarks.compareCavity(solver, re: 100) { #expect(c.maxAbsError < 0.03, "\(c.quantity)") }
        // phi was read back: no net flux through the closed cavity's faces of any cell
        var worst = 0.0
        var net = [Double](repeating: 0, count: mesh.nCells)
        for f in 0..<mesh.nFaces {
            net[Int(mesh.owner[f])] += solver.state.massFlux[f]
            if f < mesh.nInternalFaces { net[Int(mesh.neighbour[f])] -= solver.state.massFlux[f] }
        }
        for c in 0..<mesh.nCells { worst = max(worst, abs(net[c])) }
        #expect(worst < 1e-6)
    }
}

/// Conjugate heat transfer through OpenFOAM's multi-region solver, against exact solutions.
@Suite struct FoamCHTTests {
    /// Two slabs in series between 400 K and 300 K: left k = 1, right k = 4 (exact interface 320 K,
    /// flux 160 W/m²). `leftIsFluid` makes the left slab a stagnant fluid region.
    func slabs(leftIsFluid: Bool) throws -> (Mesh, CaseSetup) {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 40), y: BlockAxis(from: 0, to: 0.1, cells: 1), depth: 0.1,
                                     cellZones: [.init(name: "right", kind: .solid, box: [0.5, -1, -1, 1, 1, 1])]).build()
        if !leftIsFluid { mesh.updateCellZone(0, kind: .solid) }
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        var a = material("k1", rho: 1, mu: 1e-3, cp: 1000, k: 1); a.kind = leftIsFluid ? .fluid : .solid
        var b = material("k4", k: 4); b.kind = .solid
        s.materials += [a, b]
        s.adopt(mesh: mesh)
        s.cellZones["fluid"]!.kind = leftIsFluid ? .fluid : .solid; s.cellZones["fluid"]!.material = "k1"
        s.cellZones["right"]!.material = "k4"
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = 400
        var cold = BoundarySettings(type: .wall); cold.thermalCondition = .temperature; cold.temperature = 300
        s.boundaries["x-min"] = hot; s.boundaries["x-max"] = cold
        s.initialization.method = .standard
        s.initialization.temperature = 350
        s.run.iterations = 400
        s.openfoam.initialFields = .uniform
        s.openfoam.residualEnergy = 1e-10
        s.openfoam.caseDirectory = tempDir("cht").path
        return (mesh, s)
    }

    func check(_ mesh: Mesh, _ s: CaseSetup) throws {
        defer { try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory) }
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { _ in }, progress: { _, _, _, _ in })
        #expect(out.failure == nil, "\(out.failure ?? "")")
        #expect(out.report.isMultiRegion)
        let solver = try #require(out.solution)
        var maxErr = 0.0
        for c in 0..<mesh.nCells {
            let x = mesh.cellCentres[c].x
            let exact = x < 0.5 ? 400 - 160 * x : 320 - 40 * (x - 0.5)
            maxErr = max(maxErr, abs(solver.state.T[c] - exact))
        }
        #expect(maxErr < 0.01, "max |T - exact| = \(maxErr)")
        let f = mesh.zone(named: "x-min")!.start
        #expect(abs(solver.state.bHeatFlux[f - mesh.nInternalFaces] - 160) / 160 < 0.02)
    }

    @Test(.enabled(if: !FoamDiscovery.discover().isEmpty))
    func solidSolidWall() throws {
        let (m, s) = try slabs(leftIsFluid: false)
        #expect(FoamCaseWriter.resolvedApplication(s) == .chtMultiRegionSimpleFoam)
        try check(m, s)
    }

    @Test(.enabled(if: !FoamDiscovery.discover().isEmpty))
    func stagnantFluidSolidWall() throws {
        let (m, s) = try slabs(leftIsFluid: true)
        try check(m, s)
    }

    @Test func regionSplitKeepsFaces() throws {
        let (m, s) = try slabs(leftIsFluid: true)
        let (zones, fluids, solids) = try FoamCHTWriter.regionNames(m, s)
        #expect(fluids == ["fluid"] && solids == ["right"])
        let regions = try MeshRegions.split(m, regionOfZone: zones)
        #expect(regions.map(\.mesh.nCells).reduce(0, +) == m.nCells)
        let a = regions[0], b = regions[1]
        let ia = try #require(a.mesh.zone(named: "fluid_to_right")), ib = try #require(b.mesh.zone(named: "right_to_fluid"))
        #expect(ia.count == ib.count && ia.count == 1)
        // the pair are the same face with opposite orientation
        #expect(norm(a.mesh.faceAreas[ia.start] + b.mesh.faceAreas[ib.start]) < 1e-12)
        #expect(abs(a.mesh.totalVolume + b.mesh.totalVolume - m.totalVolume) < 1e-12)
    }
}

/// Physics paths of the OpenFOAM backend, checked against FluidCraft on the same mesh or against
/// conservation. Each runs only where OpenFOAM is installed.
@Suite struct FoamPhysicsTests {
    static let hasFoam = !FoamDiscovery.discover().isEmpty

    func channel(nx: Int = 60, ny: Int = 15, zones: [BlockMeshSpec.CellZoneRegion] = []) throws -> Mesh {
        try BlockMeshSpec(x: BlockAxis(from: 0, to: 0.4, cells: nx), y: BlockAxis(from: 0, to: 0.1, cells: ny), depth: 0.01, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.1, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.4, 0, -1], boxMax: [0.4, 0.1, 1]),
            PatchRule(name: "walls", kind: .wall, boxMin: [0, 0, -1], boxMax: [0.4, 0, 1]),
            PatchRule(name: "top", kind: .wall, boxMin: [0, 0.1, -1], boxMax: [0.4, 0.1, 1]),
        ], cellZones: zones).build()
    }

    func runFoam(_ mesh: Mesh, _ setup: CaseSetup, tag: String) throws -> (Solution, FoamSolve.Outcome) {
        var s = setup
        s.openfoam.caseDirectory = "/tmp/fluidcraft-test-\(tag)"
        try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory)
        if s.openfoam.initialFields == .fluidcraft { s.openfoam.initialFields = .uniform }
        var lines: [String] = []
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { lines.append($0) }, progress: { _, _, _, _ in })
        #expect(out.failure == nil, "\(tag): \(out.failure ?? "")")
        if out.failure != nil || out.solution == nil { print("LOG \(tag): \(out.failure ?? "")\n" + lines.suffix(25).joined(separator: "\n")) }
        else { try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory) }   // kept for inspection on failure
        return (try #require(out.solution), out)
    }

    func report(_ kind: ReportKind, _ zones: [String], field: String = "pressure", _ s: Solution) -> Double {
        var r = ReportDefinition(name: "r", kind: kind); r.zones = zones; r.field = field
        return Reports.evaluate(r, solver: s)
    }

    func airChannel(_ mesh: Mesh) -> CaseSetup {
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.1; inlet.temperature = 300
        s.boundaries["inlet"] = inlet
        var out = BoundarySettings(type: .pressureOutlet); out.temperature = 300
        s.boundaries["outlet"] = out
        s.initialization.method = .standard
        s.initialization.temperature = 300
        s.initialization.velocity = [0.1, 0, 0]
        s.run.iterations = 1500
        return s
    }

    /// rhoSimpleFoam at Mach 3e-4 must give simpleFoam's pressure drop.
    @Test(.enabled(if: hasFoam)) func rhoSimpleMatchesIncompressible() throws {
        let mesh = try channel()
        let s = airChannel(mesh)
        let (inc, o1) = try runFoam(mesh, s, tag: "inc")
        #expect(o1.report.application == .simpleFoam)
        var c = s
        var gas = Material(name: "air-gas"); gas.densityMethod = .idealGas; gas.viscosity = 1.7894e-5
        c.materials.append(gas)
        for k in c.cellZones.keys { c.cellZones[k]!.material = "air-gas" }
        c.general.operatingPressure = 101325
        let (comp, o2) = try runFoam(mesh, c, tag: "rho")
        #expect(o2.report.application == .rhoSimpleFoam)
        let dpInc = report(.areaWeightedAverage, ["inlet"], inc), dpComp = report(.areaWeightedAverage, ["inlet"], comp)
        #expect(abs(dpComp - dpInc) / dpInc < 0.03, "dp rhoSimpleFoam \(dpComp) vs simpleFoam \(dpInc)")
        // mass conservation through the compressible solver
        #expect(abs(report(.massFlowRate, ["inlet"], comp) + report(.massFlowRate, ["outlet"], comp)) < 1e-3 * abs(report(.massFlowRate, ["inlet"], comp)))
    }

    /// rhoPimpleFoam runs transient and keeps the same mean flow.
    @Test(.enabled(if: hasFoam)) func rhoPimpleRuns() throws {
        let mesh = try channel(nx: 30, ny: 8)
        var s = airChannel(mesh)
        var gas = Material(name: "air-gas"); gas.densityMethod = .idealGas
        s.materials.append(gas)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air-gas" }
        s.general.time = .transient
        s.run.timeStepSize = 0.01; s.run.numberOfTimeSteps = 20
        let (sol, out) = try runFoam(mesh, s, tag: "rhop")
        #expect(out.report.application == .rhoPimpleFoam)
        #expect(abs(sol.state.time - 0.2) < 1e-9)
        #expect(report(.massFlowRate, ["inlet"], sol) < 0)
    }

    /// buoyantSimpleFoam (incompressible ideal gas) heated channel: the heat added at the wall
    /// leaves through the outlet.
    @Test(.enabled(if: hasFoam)) func buoyantSimpleEnergyBalance() throws {
        let mesh = try channel()
        var s = airChannel(mesh)
        s.models.energy = true
        var gas = Material(name: "air-iig"); gas.densityMethod = .incompressibleIdealGas
        s.materials.append(gas)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air-iig" }
        // heated ceiling: stably stratified, so the flow is steady
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .heatFlux; hot.heatFlux = 50
        s.boundaries["top"] = hot
        s.general.gravityEnabled = true; s.general.gravity = [0, -9.81, 0]
        s.run.iterations = 3000
        let (sol, out) = try runFoam(mesh, s, tag: "buoy")
        #expect(out.report.application == .buoyantSimpleFoam)
        let qIn = 50 * 0.4 * 0.01
        let qOut = -report(.heatTransferRate, ["inlet", "outlet"], sol)
        #expect(abs(qOut - qIn) / qIn < 0.03, "heat out \(qOut) vs in \(qIn)")
    }

    /// Taylor–Couette flow (inner cylinder r = 0.5 rotating at 1 rad/s, outer wall r = 2 at rest)
    /// with an MRF zone r < 1 around the rotor: the frame must not change the exact profile
    /// u_θ = A r + B / r, in OpenFOAM or in FluidCraft.
    @Test(.enabled(if: hasFoam)) func mrfTaylorCouette() throws {
        let base = try CylinderOGridSpec(radius: 0.5, outerRadius: 2, radialCells: 40, circumferentialCells: 96, radialGrading: 1).build()
        var b = MeshBuilder()
        b.points = base.points; b.nCells = base.nCells
        let zoneIndex = base.boundaryZones.map { b.addZone($0.name, kind: $0.kind) }
        for f in 0..<base.nFaces {
            let nodes = base.faceNodeRange(f).map { base.faceNodes[$0] }
            if f < base.nInternalFaces { b.addFace(nodes, c0: base.owner[f], c1: base.neighbour[f]) }
            else { b.addFace(nodes, c0: base.owner[f], c1: -1, zone: zoneIndex[base.boundaryZones.firstIndex { $0.faceRange.contains(f) }!]) }
        }
        b.cellZones = [.init(name: "fluid", kind: .fluid), .init(name: "rotor", kind: .fluid)]
        b.cellZoneOfCell = (0..<base.nCells).map { c in let p = base.cellCentres[c]; return hypot(p.x, p.y) < 1 ? 1 : 0 }
        let mesh = try b.build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        var f = Material(name: "oil"); f.density = 1; f.viscosity = 0.01
        s.materials.append(f)
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "oil" }
        s.cellZones["rotor"]!.frameMotion = true
        s.cellZones["rotor"]!.rotationSpeed = 1
        var rotor = BoundarySettings(type: .wall); rotor.wallMotion = .rotating; rotor.rotationSpeed = 1
        s.boundaries["cylinder"] = rotor
        s.boundaries["inlet"] = BoundarySettings(type: .wall)
        s.boundaries["outlet"] = BoundarySettings(type: .wall)
        s.initialization.method = .standard
        s.run.iterations = 2000
        s.residuals.continuity = 1e-9; s.residuals.velocity = 1e-9
        let (foam, out) = try runFoam(mesh, s, tag: "mrf")
        #expect(out.report.files.contains("constant/MRFProperties"))
        let A = -0.25 / 3.75, B = 0.25 * 4 / 3.75
        let z = mesh.bounds.centre.z
        let rs = [0.75, 1.25, 1.6]
        let pts = rs.map { Vec3($0 * cos(0.3), $0 * sin(0.3), z) }
        let uf = foam.sample("velocity-magnitude", at: pts)
        for (i, r) in rs.enumerated() {
            let exact = A * r + B / r
            print(String(format: "MRF r=%.2f exact %.5f OpenFOAM %.5f", r, exact, uf[i]))
            #expect(abs(uf[i] - exact) / exact < 0.03, "OpenFOAM at r = \(r)")
        }
    }

    /// Expression sources (exprField) and a time-dependent inlet (exprFixedValue).
    @Test(.enabled(if: hasFoam)) func expressionsReachOpenFOAM() throws {
        let mesh = try channel(nx: 40, ny: 10, zones: [.init(name: "heater", kind: .fluid, box: [0.1, 0, -1, 0.2, 0.1, 1])])
        var s = airChannel(mesh)
        s.models.energy = true
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air" }
        s.cellZones["heater"]!.energySource = .expression("2e4*(1 + x)")      // W/m3, varies in space
        s.boundaries["inlet"]!.velocityMagnitude = .expression("0.1*(1 + 10*t)")
        s.general.time = .transient
        s.run.timeStepSize = 0.01; s.run.numberOfTimeSteps = 10
        let (sol, out) = try runFoam(mesh, s, tag: "expr")
        #expect(out.report.application == .buoyantBoussinesqPimpleFoam)
        // inlet speed at t = 0.1 is 0.2 m/s
        let mIn = -report(.massFlowRate, ["inlet"], sol)
        #expect(abs(mIn - 1.225 * 0.2 * 0.1 * 0.01) / mIn < 1e-3, "inlet mass flow \(mIn)")
        // the source was applied: the heater zone warmed up
        #expect(report(.volumeMaximum, ["heater"], field: "temperature", sol) > 300.01)
    }

    @Test func expressionTranslation() throws {
        let named = try Expr.compileNamed([("H", "0.41"), ("Um", "0.3")])
        print("EXPR", try Expr("4*Um*y*(H-y)/H^2", named: named).openFOAM(), "|", try Expr("if(t > 1, 2, 0)").openFOAM())
        #expect(try Expr("sin(t)").dependsOnTime && !(try Expr("x^2").dependsOnTime))
        #expect(try Expr("abs(x) + step(y)").openFOAM().contains("mag(pos().x())"))
    }
}

@Suite struct FoamStageSafetyTests {
    func bash(_ script: String, env: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// A stage from a case file may start only programs in the installation's application
    /// directories: not shells, general tools, paths or names with shell syntax.
    @Test func stagesRunOnlyOpenFOAMApplications() throws {
        let appbin = URL(fileURLWithPath: "/tmp").appendingPathComponent("fluidcraft-appbin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: appbin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appbin) }
        let app = appbin.appendingPathComponent("fakeFoam")
        try "#!/bin/sh\necho fake\n".write(to: app, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        let env = ["PATH": appbin.path + ":/usr/bin:/bin", "FOAM_APPBIN": appbin.path]
        #expect(bash(FoamShell.requireApplication("fakeFoam") + "\necho RAN", env: env).1.contains("RAN"))
        for bad in ["sh", "rm", "python3", "/bin/sh", "../fakeFoam", "fakeFoam;touch", "$(touch x)", ""] {
            let (code, out) = bash(FoamShell.requireApplication(bad) + "\necho RAN", env: env)
            #expect(code == 96 && !out.contains("RAN"), "\(bad): \(code) \(out)")
        }
        // no FOAM_APPBIN at all: nothing passes
        #expect(bash(FoamShell.requireApplication("fakeFoam") + "\necho RAN", env: ["PATH": appbin.path + ":/usr/bin:/bin"]).0 == 96)
    }

    @Test func activeContentIsDisclosedInFull() {
        var o = FoamSettings()
        let long = String(repeating: "// padding\n", count: 100) + "x { #codeStream { code #{ system(\"rm -rf ~\"); #}; }; }"
        o.extraFiles = ["system/topoSetDict": long]
        o.customFunctions = "q { type systemCall; executeCalls (\"touch x\"); }"
        o.dictionaryAppends = ["system/fvSchemes": "libs (\"libEvil.dylib\");"]
        let items = o.activeContent
        #expect(items.count == 3)
        #expect(items.contains { $0.contains("⚠️") && $0.contains("#codeStream") && $0.contains("topoSetDict") })
        #expect(items.contains { $0.contains("systemCall") })
        #expect(items.contains { $0.contains("library loading") })
        // the full text includes everything, not a 300-character preview
        #expect(o.activeContentFullText.contains("rm -rf ~") && o.activeContentFullText.contains("replaces the generated file"))
        #expect(FoamSettings.codeConstructs(in: "type fixedValue; value uniform 0;").isEmpty)
    }

    @Test func allrunQuotesCustomStages() throws {
        var (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 4)
        setup.openfoam.customStages = [FoamCustomStage(phase: .afterSolve, command: "postProcess -func vorticity -latestTime"),
                                       FoamCustomStage(phase: .beforeSolve, command: "sh -c 'touch FLUIDCRAFT_PWNED'; touch FLUIDCRAFT_PWNED")]
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("fluidcraft-allrun-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir)
        let allrun = dir.appendingPathComponent("Allrun").path
        #expect(bash("bash -n " + FoamShell.quote(allrun), env: ["PATH": "/usr/bin:/bin"]).0 == 0)
        let text = try String(contentsOfFile: allrun, encoding: .utf8)
        #expect(text.contains("runApplication 'postProcess' '-func' 'vorticity' '-latestTime'"))
        #expect(!text.contains("; touch FLUIDCRAFT_PWNED\n"))
        // and the stage list marks every custom stage as needing an OpenFOAM application
        let stages = FoamRunPlan.stages(report: try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir), setup: setup, freshMesh: true)
        let custom = stages.filter { $0.id.hasPrefix("custom.") }
        #expect(custom.count == 2 && custom.allSatisfy { $0.requiredApplication == $0.command })
        #expect(setup.openfoam.activeContent.count == 2)
    }
}

@Suite struct DictionarySafetyTests {
    @Test func keywordSettingsCannotCarryDirectives() throws {
        let (mesh, base) = try Benchmarks.cavityCase(re: 100, cells: 4)
        let dir = URL(fileURLWithPath: "/tmp/fluidcraft-kw-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        var ok = base
        ok.openfoam.schemes.divU = "bounded Gauss linearUpwind grad(U)"
        ok.openfoam.schemes.laplacian = "Gauss linear limited corrected 0.33"
        _ = try FoamCaseWriter.write(mesh: mesh, setup: ok, to: dir)
        for evil in ["Gauss linear; #codeStream { code #{ system(\"x\"); #}; }", "Gauss linear\n#include \"/etc/x\"", "$foo", "Gauss {linear}"] {
            var s = base; s.openfoam.schemes.divU = evil
            #expect(throws: SolverError.self) { _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir) }
        }
        var s = base; s.openfoam.lesDelta = "cubeRootVol; #codeStream"
        #expect(!s.openfoam.invalidKeywordSettings.isEmpty)
        s = base; s.openfoam.pressureSolver.solver = "GAMG;\n#include \"x\""
        #expect(throws: SolverError.self) { _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir) }
    }

    @Test func gmshLiteralsCannotEnd() {
        #expect(GmshDriver.literal("part\"); SystemCall \"touch x\"; //.step") == "part); SystemCall touch x; //.step")
        #expect(!GmshDriver.literal("a\\\"\nb").contains("\"") && !GmshDriver.literal("a\nb").contains("\n"))
    }
}

@Suite struct CADConverterTests {
    @Test func commandSplitting() {
        #expect(CADConversion.splitCommand("\"/Applications/CAD Exchanger.app/x\" -i {input} -e '{output}'")
                == ["/Applications/CAD Exchanger.app/x", "-i", "{input}", "-e", "{output}"])
        #expect(CADConversion.splitCommand("a\\ b c") == ["a b", "c"])
    }

    /// A file name full of shell syntax is passed as one argument and never executed.
    @Test func hostileFileNameIsInert() throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("fluidcraft-conv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // relative to the working directory, where an injected command would run
        let marker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("FLUIDCRAFT_PWNED")
        try? FileManager.default.removeItem(at: marker)
        let evil = dir.appendingPathComponent("part'; touch FLUIDCRAFT_PWNED; echo '$(touch FLUIDCRAFT_PWNED)`touch FLUIDCRAFT_PWNED`.sldprt")
        try Data("ISO-10303-21;".utf8).write(to: evil)
        let out = try CADConversion.prepare(evil.path, converter: "cp {input} {output}", workDir: dir.appendingPathComponent("work"))
        #expect(FileManager.default.fileExists(atPath: out))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // and converter commands are not part of saved settings
        var ms = MeshingSettings(template: .pipe(length: 1, diameter: 0.1))
        ms.cadConverter = "rm -rf ~"
        let json = String(decoding: try JSONEncoder().encode(ms), as: UTF8.self)
        #expect(!json.contains("rm -rf"))
        let back = try JSONDecoder().decode(MeshingSettings.self, from: Data(#"{"template":{"pipe":{"length":1,"diameter":0.1}},"maxSize":0.05,"wallSize":0.01,"growthDistance":0.5,"blFirstHeight":0,"blGrowth":1.2,"blThickness":0,"blLayers":0,"blZones":[],"quads":true,"depth2D":1,"algorithm2D":6,"algorithm3D":1,"cadUnit":"m","featureAngle":40,"openings":[],"cadConverter":"touch /tmp/x"}"#.utf8))
        #expect(back.cadConverter == "")
    }
}

@Suite struct SolveTrustTests {
    /// The shared solve helper never runs custom OpenFOAM content nobody approved.
    @Test func customContentNeedsApproval() throws {
        let mesh = try GmshReader.build(tetCube(2))
        var s = CaseSetup()
        s.adopt(mesh: mesh)
        let st = FoamCustomStage(phase: .beforeSolve, command: "postProcess -func Q")
        s.openfoam.customStages = [st]
        #expect(!s.openfoam.activeContent.isEmpty)
        #expect(throws: SolverError.self) { _ = try ValidationSuite.solve(mesh, s, iterations: 1) }
    }
}
