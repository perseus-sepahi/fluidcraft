import Testing
import Foundation
@testable import FluidCraftMesh
@testable import FluidCraftSolver
@testable import FluidCraftFoam

private func scratch(_ tag: String) -> URL {
    URL(fileURLWithPath: "/tmp").appendingPathComponent("fluidcraft-\(tag)-\(UUID().uuidString.prefix(8))")
}
private func text(_ dir: URL, _ path: String) -> String {
    (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

@Suite struct ModuleTests {
    @Test func catalogue() {
        for c in ModuleCategory.allCases { #expect(!c.modules.isEmpty, "\(c.title)") }
        #expect(Set(ModuleCategory.allCases.flatMap(\.modules)) == Set(AppModule.allCases))
        #expect(AppModule.allCases.filter(\.buildsCase).count == 4)
    }

    @Test func everyModuleIsListedOnce() throws {
        let listed = ModuleCategory.allCases.flatMap(\.modules)
        #expect(listed.count == Set(listed).count && Set(listed) == Set(AppModule.allCases))
        #expect(!ModuleCategory.allCases.contains { $0.modules.count < 2 })
        // the three CAD modules of earlier versions open the merged one
        for old in ["cadExternal", "cadInternal", "cadConjugate"] {
            #expect(try JSONDecoder().decode(AppModule.self, from: Data("\"\(old)\"".utf8)) == .cadAnalysis)
        }
        // the engineering cases are modules, not also tutorials
        let core = Set(TutorialCatalog.core.map(\.id))
        #expect(core.isDisjoint(with: ["wind-farm", "wind-turbine", "chip-air", "chip-liquid"]))
    }

    @Test func pytorchEnvironmentCheck() {
        #expect(!PINNJob.checkEnvironment(python: "/nonexistent/python").ok)
        let py = PINNJob.environmentDirectory.appendingPathComponent("bin/python").path
        if FileManager.default.isExecutableFile(atPath: py) {
            let st = PINNJob.checkEnvironment(python: py)
            #expect(st.ok && st.text.contains("PyTorch"), "\(st.text)")
        }
    }

    @Test func windFarmLayout() throws {
        var w = WindFarmModule()
        w.rows = 2; w.columns = 2; w.cellsPerDiameter = 6
        let (mesh, s) = try w.build()
        #expect(s.cellZones.values.filter { $0.actuatorDisk != nil }.count == 4)
        #expect(s.reports.count == 4)
        for i in 1...4 { #expect((mesh.cellZones.first { $0.name == "turbine\(i)" }?.cellCount ?? 0) > 0) }
        // the second row sits lateralSpacing diameters beside the first
        #expect(abs(w.positions[2].y - w.positions[0].y - 5 * w.diameter) < 1e-9)
    }

    /// The chip's heat source integrates to the module's power for any design.
    func chipPower(_ mesh: Mesh, _ s: CaseSetup) -> Double {
        let zi = mesh.cellZones.firstIndex { $0.name == "chip" }!
        let q = s.cellZones["chip"]!.energySource.constantValue ?? 0
        return (0..<mesh.nCells).filter { Int(mesh.cellZone[$0]) == zi }.reduce(0.0) { $0 + q * mesh.cellVolumes[$1] }
    }

    @Test func coolingModulesAreParametric() throws {
        var a = AirCooledHeatSinkModule()
        a.finCount = 5; a.power = 25; a.heatSinkMaterial = "copper"; a.cellSize = 0.0025
        let (ma, sa) = try a.build()
        #expect(abs(chipPower(ma, sa) - 25) < 1e-9)
        #expect(sa.cellZones["heatsink"]?.material == "copper" && sa.material(named: "copper") != nil)
        var l = LiquidColdPlateModule()
        l.channelCount = 3; l.power = 60; l.cellSize = 0.001
        let (ml, sl) = try l.build()
        #expect(abs(chipPower(ml, sl) - 60) < 1e-9)
        #expect(sl.cellZones["coolant"]?.kind == .fluid)
        // a design that does not fit is refused with a reason
        a.finCount = 40; a.finThickness = 0.001
        #expect(throws: SolverError.self) { _ = try a.build() }
    }

    @Test func moduleParametersRoundTrip() throws {
        var p = ModuleParameters()
        p.windFarm.columns = 5; p.pinn.neurons = 128; p.liquidCooling.coolant = "water-liquid"
        let back = try JSONDecoder().decode(ModuleParameters.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        // missing sections fall back to defaults
        let partial = try JSONDecoder().decode(ModuleParameters.self, from: Data(#"{"pinn":{"bad":1}}"#.utf8))
        #expect(partial.windFarm == WindFarmModule())
    }

    @Test func pinnProblemFiles() throws {
        let (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 8)
        let dir = scratch("pinn")
        defer { try? FileManager.default.removeItem(at: dir) }
        var ps = PINNSettings(); ps.hiddenLayers = 3
        let job = PINNJob(mesh: mesh, setup: setup, settings: ps)
        let sum = try job.prepare(in: dir, solution: nil)
        #expect(sum.interiorPoints == mesh.nCells && sum.dimensions == 2)
        #expect(abs(sum.reynolds - 50) < 1)          // Re 100 on the lid length; FluidCraft uses the half-size
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("config.json"))) as! [String: Any]
        #expect(cfg["hidden_layers"] as? Int == 3 && (cfg["axes"] as? [Int])?.count == 2)
        let rows = text(dir, "boundary.csv").split(separator: "\n").count - 1
        #expect(rows == mesh.boundaryZones.filter { $0.kind != .empty }.reduce(0) { $0 + $1.count })
        // the moving lid is a velocity-given wall (type 2) with u = 1
        #expect(text(dir, "boundary.csv").split(separator: "\n").contains { $0.split(separator: ",").count > 7 && $0.split(separator: ",")[6] == "2" && $0.split(separator: ",")[7] == "1" })
        #expect(text(dir, "train.py").contains("def pde_loss"))
        // hybrid needs a solution
        var hs = ps; hs.mode = .hybrid
        #expect(throws: PINNError.self) { try PINNJob(mesh: mesh, setup: setup, settings: hs).prepare(in: dir, solution: nil) }
        // the script is valid Python (when a python3 is around)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", dir.appendingPathComponent("train.py").path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
    }

    @Test func pinnPredictionLoads() throws {
        let (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 6)
        let dir = scratch("pinnload")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var csv = "u,v,w,p,T\n"
        for c in 0..<mesh.nCells { csv += "\(mesh.cellCentres[c].y),0,0,\(mesh.cellCentres[c].x),300\n" }
        try csv.write(to: dir.appendingPathComponent("prediction.csv"), atomically: true, encoding: .utf8)
        let s = try PINNJob.load(from: dir, mesh: mesh, setup: setup)
        #expect(abs(s.state.u[5].x - mesh.cellCentres[5].y) < 1e-12 && abs(s.state.p[7] - mesh.cellCentres[7].x) < 1e-12)
    }

    @Test func assistantContext() throws {
        let (mesh, setup) = try Benchmarks.cavityCase(re: 100, cells: 4)
        let t = AIAssistant.caseContext(mesh: mesh, setup: setup, quality: MeshQuality.report(mesh), residuals: ["continuity": 1e-3],
                                        reports: ["cd": 1.2], recentLog: ["boom"])
        for z in mesh.boundaryZones where z.kind != .empty { #expect(t.contains(z.name)) }
        #expect(t.contains("continuity 1.00e-03") && t.contains("cd = 1.2") && t.contains("boom") && t.contains("Mesh quality"))
        #expect(AISettings().model == "claude-opus-5-5" && AISettings().provider == .anthropic)
    }

    @Test func caseWriterExtras() throws {
        var (mesh, s) = try Benchmarks.cavityCase(re: 100, cells: 6)
        s.openfoam.courantNumber = true
        s.openfoam.lambda2 = true
        s.openfoam.limitVelocity = 5
        s.openfoam.stopAt = "writeNow"
        s.openfoam.cuttingPlanes = [FoamCuttingPlane(name: "mid", point: [0.5, 0.5, 0], normal: [0, 0, 1])]
        s.openfoam.fileOverrides = ["system/fvSchemes": "// mine\n", "../escape": "x"]
        var r = ReportDefinition(name: "u-avg", kind: .volumeAverage); r.field = "pressure"
        s.reports = [r]
        s.openfoam.runTimeStopReport = "u-avg"
        let dir = scratch("extras")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let cd = text(dir, "system/controlDict")
        #expect(cd.contains("CourantNo") && cd.contains("Lambda2") && cd.contains("cuttingPlane") && cd.contains("solverInfo"))
        #expect(cd.contains("stopAt          writeNow;"))
        #expect(cd.contains("runTimeControl"))
        #expect((text(dir, "constant/fvOptions") + text(dir, "system/fvOptions")).contains("limitVelocity"))
        #expect(text(dir, "system/fvSchemes") == "// mine\n")
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape").path))
        #expect(s.openfoam.activeContent.contains { $0.hasPrefix("Replaced file system/fvSchemes") })
    }
}
