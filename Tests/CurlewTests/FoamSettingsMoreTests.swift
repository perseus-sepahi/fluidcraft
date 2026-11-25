import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewSolver
@testable import CurlewFoam

/// The OpenFOAM settings added on top of the core set: more turbulence models and their
/// coefficients, per-patch OpenFOAM conditions, thermophysical models, fvOptions, run control,
/// function objects, adaptive refinement. Each is written by Curlew and run by OpenFOAM.
@Suite(.serialized) struct FoamSettingsMoreTests {
    static let hasFoam = !FoamDiscovery.discover().isEmpty

    func channel(nx: Int = 40, ny: Int = 16, nz: Int? = nil, zones: [BlockMeshSpec.CellZoneRegion] = []) throws -> Mesh {
        try BlockMeshSpec(x: BlockAxis(from: 0, to: 0.4, cells: nx), y: BlockAxis(from: 0, to: 0.1, cells: ny),
                          z: nz.map { BlockAxis(from: 0, to: 0.05, cells: $0) }, depth: 0.01, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.1, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.4, 0, -1], boxMax: [0.4, 0.1, 1]),
            PatchRule(name: "bottom", kind: .wall, boxMin: [0, 0, -1], boxMax: [0.4, 0, 1]),
            PatchRule(name: "top", kind: .wall, boxMin: [0, 0.1, -1], boxMax: [0.4, 0.1, 1]),
        ], sideKinds: ["z-min": .symmetry, "z-max": .symmetry], cellZones: zones).build()
    }

    func duct(_ mesh: Mesh, speed: Double = 2, viscous: ViscousModel = .kOmegaSST) -> CaseSetup {
        var s = CaseSetup()
        s.models.viscous = viscous
        s.adopt(mesh: mesh)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(speed)
        s.boundaries["inlet"] = inlet
        s.boundaries["outlet"] = BoundarySettings(type: .pressureOutlet)
        s.initialization.method = .standard
        s.initialization.velocity = [.constant(speed), 0, 0]
        s.run.iterations = 60
        s.general.backend = .openfoam
        s.openfoam.initialFields = .uniform
        s.openfoam.checkMesh = false
        return s
    }

    @discardableResult
    func run(_ mesh: Mesh, _ setup: CaseSetup, _ tag: String, keep: Bool = false) throws -> (PressureBasedSolver?, FoamSolve.Outcome, URL) {
        var s = setup
        s.openfoam.caseDirectory = "/tmp/curlew-more-\(tag)"
        try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory)
        var lines: [String] = []
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { lines.append($0) }, progress: { _, _, _, _ in })
        if out.failure != nil { print("LOG \(tag): \(out.failure!)\n" + lines.suffix(40).joined(separator: "\n")) }
        #expect(out.failure == nil, "\(tag): \(out.failure ?? "")")
        return (out.solver, out, URL(fileURLWithPath: s.openfoam.caseDirectory))
    }

    func text(_ dir: URL, _ path: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    func massFlow(_ s: PressureBasedSolver, _ patch: String) -> Double {
        var r = ReportDefinition(name: "m", kind: .massFlowRate); r.zones = [patch]
        return Reports.evaluate(r, solver: s)
    }

    // MARK: Dictionaries (no OpenFOAM needed)

    @Test func dictionariesAreWritten() throws {
        let mesh = try channel(zones: [.init(name: "hot", kind: .fluid, box: [0.1, 0, -1, 0.2, 0.1, 1])])
        var s = duct(mesh)
        s.openfoam.turbulence = .kOmegaSSTLM
        s.openfoam.turbulenceCoefficients = ["betaStar": 0.09, "bad name": 1]
        s.openfoam.patchOptions["inlet"] = { var p = FoamPatchOptions(condition: .volumetricFlowRate); p.volumetricFlowRate = 1e-3; return p }()
        s.openfoam.patchOptions["bottom"] = { var p = FoamPatchOptions(condition: .roughWall); p.roughnessHeight = 1e-4; return p }()
        s.openfoam.writeControl = .runTime; s.openfoam.writeEvery = 20
        s.openfoam.pressureSolver.nPostSweeps = 3; s.openfoam.velocitySolver.nSweeps = 2; s.openfoam.velocitySolver.minIter = 1
        s.openfoam.fvOptions = [{ var f = FoamFvOption(name: "damp", kind: .velocityDamping); f.maximumVelocity = 50; return f }()]
        s.openfoam.postProcessing.expressionFields = [FoamExpressionField(name: "pTotal", expression: "p + 0.5*magSqr(U)")]
        s.openfoam.postProcessing.histograms = [FoamHistogram(field: "p", bins: 12)]
        let dir = URL(fileURLWithPath: "/tmp/curlew-more-dict-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        // a coefficient name that is not an OpenFOAM word is refused before anything is written
        #expect(throws: SolverError.self) { _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir) }
        s.openfoam.turbulenceCoefficients = ["betaStar": 0.09]
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        #expect(text(dir, "constant/turbulenceProperties").contains("kOmegaSSTLMCoeffs") && text(dir, "constant/turbulenceProperties").contains("betaStar        0.09"))
        #expect(text(dir, "0/ReThetat").contains("fixedValue") && text(dir, "0/gammaInt").contains("zeroGradient"))
        #expect(text(dir, "0/U").contains("volumetricFlowRate 0.001"))
        #expect(text(dir, "0/nut").contains("nutkRoughWallFunction") && text(dir, "0/nut").contains("Ks              uniform 0.0001"))
        let cd = text(dir, "system/controlDict")
        #expect(cd.contains("writeControl    runTime;") && cd.contains("writeInterval   20;"))
        let sol = text(dir, "system/fvSolution")
        #expect(sol.contains("nPostSweeps     3;") && sol.contains("nSweeps         2;") && sol.contains("minIter         1;"))
        #expect(text(dir, "constant/fvOptions").contains("velocityDampingConstraint"))
        let pp = text(dir, "system/curlewPostProcess")
        #expect(pp.contains("expression      \"p + 0.5*magSqr(U)\";") && pp.contains("readFields      (p U);") && pp.contains("nBins           12;"))

        // expressions that could end the quoted string are refused
        s.openfoam.postProcessing.expressionFields = [FoamExpressionField(name: "x", expression: "p\"; #codeStream {")]
        #expect(throws: SolverError.self) { _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir) }
        // scripts are always shown for approval
        s.openfoam.postProcessing.expressionFields = []
        s.openfoam.postProcessing.scripts = [FoamPostScript(name: "a", code: "print(1)")]
        #expect(s.openfoam.activeContent.contains { $0.contains("runs Python code") })
    }

    @Test func expressionFieldReads() {
        #expect(FoamExpressionField(name: "a", expression: "mag(U) + 2*pos().x() - 1e-5*T").referencedFields == ["U", "T"])
        #expect(FoamExpressionField(name: "a", expression: "p + 0.5*magSqr(U)").referencedFields == ["p", "U"])
    }

    @Test func thermoCombinationIsChecked() throws {
        let mesh = try channel(nx: 10, ny: 4)
        var s = duct(mesh, speed: 10)
        s.models.energy = true
        s.openfoam.application = .rhoSimpleFoam
        s.openfoam.thermo.transport = .polynomial
        s.openfoam.thermo.thermo = .hConst
        s.openfoam.thermo.equationOfState = .perfectGas
        let dir = URL(fileURLWithPath: "/tmp/curlew-more-thermo-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SolverError.self) { _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir) }
        s.openfoam.thermo.thermo = .hPolynomial
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        #expect(text(dir, "constant/thermophysicalProperties").contains("CpCoeffs<8>"))
    }

    @Test func oldCaseFilesStillLoad() throws {
        // settings written before these options existed decode with defaults
        let json = #"{"solver":"GAMG","smoother":"GaussSeidel","preconditioner":"DIC","tolerance":1e-6,"relTol":0.05,"maxIter":100,"nCellsInCoarsestLevel":10}"#
        let l = try JSONDecoder().decode(FoamLinearSolver.self, from: Data(json.utf8))
        #expect(l.nPostSweeps == 2 && l.cacheAgglomeration && l.relTol == 0.05)
        let pp = try JSONDecoder().decode(FoamPostProcessing.self, from: Data(#"{"functions":["Q"]}"#.utf8))
        #expect(pp.functions == ["Q"] && pp.scripts.isEmpty && pp.afterSolve)
        var o = FoamSettings(); o.patchOptions["inlet"] = FoamPatchOptions(condition: .fanCurve)
        let back = try JSONDecoder().decode(FoamSettings.self, from: JSONEncoder().encode(o))
        #expect(back == o)
    }

    // MARK: OpenFOAM runs

    @Test(.enabled(if: hasFoam)) func newTurbulenceModelsRun() throws {
        let mesh = try channel(nx: 30, ny: 12)
        for model: FoamTurbulenceModel in [.kOmegaSSTSAS, .kOmegaSSTLM, .GEKO, .LRR, .SSG] {
            var s = duct(mesh)
            s.openfoam.turbulence = model
            s.run.iterations = 40
            let (sol, _, dir) = try run(mesh, s, "turb-\(model.rawValue)")
            #expect(sol != nil, "\(model.rawValue)")
            if sol != nil { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// Volumetric inlet, sand-grain rough wall, model coefficients, runTime writes and the solver extras.
    @Test(.enabled(if: hasFoam)) func inletRoughWallAndRunControl() throws {
        let mesh = try channel()
        var s = duct(mesh)
        let q = 2e-4          // m³/s through a 0.1 m × 0.01 m inlet → 0.2 m/s
        s.openfoam.patchOptions["inlet"] = { var p = FoamPatchOptions(condition: .volumetricFlowRate); p.volumetricFlowRate = q; return p }()
        s.openfoam.patchOptions["bottom"] = { var p = FoamPatchOptions(condition: .roughWall); p.roughnessHeight = 5e-4; return p }()
        s.openfoam.turbulenceCoefficients = ["betaStar": 0.09]
        s.openfoam.writeControl = .runTime; s.openfoam.writeEvery = 25
        s.openfoam.pressureSolver.nPostSweeps = 3; s.openfoam.velocitySolver.nSweeps = 2
        s.run.iterations = 100
        let (sol, _, dir) = try run(mesh, s, "inlet-rough", keep: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let solver = try #require(sol)
        let rho = solver.setup.material(named: solver.setup.cellZones.values.first?.material ?? "air")?.density ?? 1.225
        #expect(abs(-massFlow(solver, "inlet") / rho - q) < 0.02 * q, "inlet volume flow \(-massFlow(solver, "inlet") / rho)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("25").path) && FileManager.default.fileExists(atPath: dir.appendingPathComponent("50").path))
        #expect(text(dir, "0/nut").contains("nutkRoughWallFunction"))
    }

    /// Profile from a CSV file mapped onto the inlet (timeVaryingMappedFixedValue).
    @Test(.enabled(if: hasFoam)) func inletProfileFromFile() throws {
        let mesh = try channel(nx: 20, ny: 10)
        var s = duct(mesh, viscous: .laminar)
        let csv = URL(fileURLWithPath: "/tmp/curlew-more-profile.csv")
        var rows = "x,y,z,Ux,Uy,Uz\n"
        for j in 0...20 { let y = 0.1 * Double(j) / 20; for z in [0.0, 0.01] { rows += "0,\(y),\(z),\(6 * 0.3 * y * (0.1 - y) / 0.01),0,0\n" } }
        try rows.write(to: csv, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: csv) }
        s.openfoam.patchOptions["inlet"] = { var p = FoamPatchOptions(condition: .profileFromFile); p.profileFile = csv.path; return p }()
        let (sol, _, dir) = try run(mesh, s, "profile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let solver = try #require(sol)
        // a parabola of mean 0.3 m/s: peak 0.45 m/s at mid height
        let u = solver.sample("x-velocity", at: [Vec3(0.002, 0.05, 0.005)])[0]
        #expect(abs(u - 0.45) < 0.03, "inlet centre speed \(u)")
    }

    /// LES inflow from synthetic eddies, a non-reflecting outlet, time averaging with a start
    /// time, an expression field during the run and velocity damping.
    @Test(.enabled(if: hasFoam)) func transientInflowOutletAndAveraging() throws {
        let mesh = try channel(nx: 24, ny: 12, nz: 6)
        var s = duct(mesh, speed: 1)
        s.general.time = .transient
        s.run.timeStepSize = 2e-3; s.run.numberOfTimeSteps = 30
        s.openfoam.application = .pimpleFoam
        s.openfoam.turbulence = .sigma
        s.openfoam.patchOptions["inlet"] = { var p = FoamPatchOptions(condition: .syntheticTurbulence); p.turbulenceIntensity = 0.1; p.lengthScale = 0.01; p.delta = 0.05; return p }()
        s.openfoam.patchOptions["outlet"] = { var p = FoamPatchOptions(condition: .nonReflecting); p.farFieldDistance = 0.4; return p }()
        s.openfoam.fieldAverage.enabled = true; s.openfoam.fieldAverage.fields = "U p"; s.openfoam.fieldAverage.startTime = 0.02
        s.openfoam.postProcessing.expressionFields = [{ var e = FoamExpressionField(name: "magU", expression: "mag(U)"); e.duringRun = true; return e }()]
        s.openfoam.fvOptions = [{ var f = FoamFvOption(name: "damp", kind: .velocityDamping); f.maximumVelocity = 5; return f }()]
        let (_, out, dir) = try run(mesh, s, "les-inflow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try #require(out.loadedTime)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(t)/UMean").path) && fm.fileExists(atPath: dir.appendingPathComponent("\(t)/magU").path))
        // the inflow fluctuates: the inlet velocity is not uniform
        let u = try FoamFieldReader.read(url: dir.appendingPathComponent("\(t)/U"))
        if case .list(let v, _)? = u.patchValues["inlet"] { #expect(Set(v.map { ($0 * 1e4).rounded() }).count > 10) } else { Issue.record("inlet U is uniform") }
    }

    /// Temperature-dependent properties and a real-gas equation of state.
    @Test(.enabled(if: hasFoam)) func thermophysicalModelsRun() throws {
        let mesh = try channel(nx: 20, ny: 8)
        struct Combo { let app: FoamApplication; let tr: FoamThermoSettings.Transport; let th: FoamThermoSettings.Thermo; let eos: FoamThermoSettings.EquationOfState }
        for c in [Combo(app: .rhoSimpleFoam, tr: .sutherland, th: .janaf, eos: .perfectGas),
                  Combo(app: .rhoSimpleFoam, tr: .sutherland, th: .janaf, eos: .PengRobinsonGas),
                  Combo(app: .buoyantSimpleFoam, tr: .polynomial, th: .hPolynomial, eos: .icoPolynomial)] {
            var s = duct(mesh, speed: 5, viscous: .laminar)
            s.models.energy = true
            s.openfoam.application = c.app
            s.openfoam.thermo.transport = c.tr; s.openfoam.thermo.thermo = c.th; s.openfoam.thermo.equationOfState = c.eos
            if c.eos == .icoPolynomial { s.openfoam.thermo.rhoCoeffs = [1.2, 0, 0, 0, 0, 0, 0, 0] }
            s.run.iterations = 30
            let tag = "thermo-\(c.th.rawValue)-\(c.eos.rawValue)"
            let (_, _, dir) = try run(mesh, s, tag)
            #expect(text(dir, "constant/thermophysicalProperties").contains("equationOfState \(c.eos.rawValue);"))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// A blade-element rotor and a fixed-temperature zone.
    @Test(.enabled(if: hasFoam)) func rotorDiskAndFixedTemperature() throws {
        let mesh = try channel(nx: 40, ny: 16, nz: 8, zones: [.init(name: "rotor", kind: .fluid, box: [0.15, 0.02, 0.0, 0.17, 0.08, 0.05])])
        var s = duct(mesh, speed: 2)
        var r = FoamFvOption(name: "rotor1", kind: .rotorDisk); r.zone = "rotor"
        r.rotor.origin = [0.16, 0.05, 0.025]; r.rotor.axis = [1, 0, 0]; r.rotor.referenceDirection = [0, 1, 0]
        r.rotor.rpm = 600; r.rotor.sections = [[0.005, 10, 0.01], [0.03, 2, 0.008]]
        s.openfoam.fvOptions = [r]
        s.run.iterations = 40
        let (sol, _, dir) = try run(mesh, s, "rotor")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sol != nil)
        #expect(text(dir, "log.simpleFoam").contains("rotorDisk") || text(dir, "log.simpleFoam").contains("rotor1"))

        var h = duct(mesh, speed: 2, viscous: .laminar)
        h.models.energy = true
        h.openfoam.application = .buoyantSimpleFoam
        var ft = FoamFvOption(name: "hot", kind: .fixedTemperature); ft.zone = "rotor"; ft.temperature = 350
        h.openfoam.fvOptions = [ft]
        h.run.iterations = 30
        let (hs, _, hdir) = try run(mesh, h, "fixedT")
        let T = try #require(hs).sample("temperature", at: [Vec3(0.155, 0.046875, 0.021875)])[0]    // a cell centre in the zone
        #expect(abs(T - 350) < 0.5, "zone temperature \(T)")
        if abs(T - 350) < 0.5 { try? FileManager.default.removeItem(at: hdir) }
    }

    /// Adaptive refinement driven by an expression (3D hexahedra: hexRef8 splits in all directions).
    @Test(.enabled(if: hasFoam)) func adaptiveRefinementRefines() throws {
        let mesh = try channel(nx: 16, ny: 8, nz: 4)
        var s = duct(mesh, speed: 1, viscous: .laminar)
        s.general.time = .transient
        s.openfoam.application = .pimpleFoam
        s.run.timeStepSize = 0.005; s.run.numberOfTimeSteps = 8
        s.openfoam.adaptiveRefinement.enabled = true
        s.openfoam.adaptiveRefinement.field = "mag(U)"
        s.openfoam.adaptiveRefinement.lowerLevel = 0.5; s.openfoam.adaptiveRefinement.upperLevel = 10
        s.openfoam.adaptiveRefinement.refineInterval = 2; s.openfoam.adaptiveRefinement.maxRefinement = 1
        s.openfoam.adaptiveRefinement.maxCells = 20000
        s.openfoam.loadResults = false
        let (_, out, dir) = try run(mesh, s, "amr", keep: true)
        let log = text(dir, "log.pimpleFoam")
        #expect(log.contains("Refined from \(mesh.nCells)"), "\(log.suffix(1500))")
        if out.failure == nil { try? FileManager.default.removeItem(at: dir) }
    }

    /// Expression fields, histograms, the heat-transfer coefficient and the added function
    /// objects, run by OpenFOAM after a heated-channel solve.
    @Test(.enabled(if: hasFoam)) func postProcessingAdditionsRun() throws {
        let mesh = try channel(nx: 24, ny: 10)
        var s = duct(mesh, speed: 0.5, viscous: .laminar)
        s.models.energy = true
        s.openfoam.application = .buoyantSimpleFoam
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = .constant(330)
        s.boundaries["bottom"] = hot
        s.run.iterations = 150
        var pp = FoamPostProcessing()
        pp.functions = ["age", "LambVector", "continuityError", "comfort"]
        pp.expressionFields = [FoamExpressionField(name: "magU", expression: "mag(U)"), FoamExpressionField(name: "dT", expression: "T - 300")]
        pp.histograms = [FoamHistogram(field: "T", bins: 8)]
        pp.heatTransferCoeff.enabled = true; pp.heatTransferCoeff.patches = ["bottom"]; pp.heatTransferCoeff.referenceTemperature = 300
        s.openfoam.postProcessing = pp
        let (_, out, dir) = try run(mesh, s, "post-more", keep: true)
        let t = try #require(out.loadedTime)
        let fm = FileManager.default
        var complete = true
        for f in ["magU", "dT", "age", "LambVector", "heatTransferCoeff(T)"] {
            let ok = fm.fileExists(atPath: dir.appendingPathComponent("\(t)/\(f)").path)
            #expect(ok, "missing \(t)/\(f)")
            complete = complete && ok
        }
        let hist = (try? fm.subpathsOfDirectory(atPath: dir.appendingPathComponent("postProcessing").path)) ?? []
        #expect(hist.contains { $0.contains("histogram") }, "\(hist)")
        if out.failure == nil && !hist.isEmpty && complete { try? fm.removeItem(at: dir) }
    }
}
