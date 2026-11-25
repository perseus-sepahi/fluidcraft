import Foundation
import CurlewMesh
import CurlewSolver

/// Solves the published benchmarks with OpenFOAM and compares Curlew's measurements of the
/// results with the reference values. This checks the whole chain: mesh generation, case
/// writing, the OpenFOAM run and reading the fields back.
public enum ValidationSuite {
    public struct Row: Sendable, Codable {
        public var benchmark: String
        public var quantity: String
        public var reference: String
        public var computed: String
        public var passed: Bool
        public var seconds: Double
    }

    public enum Case: String, CaseIterable, Sendable {
        case cavity100 = "Lid-driven cavity Re=100 (Ghia 1982)"
        case cavity1000 = "Lid-driven cavity Re=1000 (Ghia 1982)"
        case naturalConvection = "Natural convection Ra=1e5 (de Vahl Davis 1983)"
        case flatPlateSST = "Flat plate k-ω SST (Kármán-Schoenherr)"
        case flatPlateSA = "Flat plate Spalart-Allmaras (Kármán-Schoenherr)"
        case schaferTurek = "Cylinder in channel Re=20 (Schäfer-Turek 2D-1)"
        case cylinder100 = "Cylinder wake Re=100 (Williamson 1996)"
        case sod = "Sod shock tube (exact Riemann solution)"
        case ramp = "Mach 2.5 flow over a 15° ramp (oblique-shock theory)"

        public var needsGmsh: Bool { self == .schaferTurek }
        /// Name on the command line (`curlew-cli validate <name>`).
        public var cliName: String {
            switch self {
            case .cavity100: return "cavity"
            case .cavity1000: return "cavity-1000"
            case .naturalConvection: return "natural-convection"
            case .flatPlateSST: return "flat-plate"
            case .flatPlateSA: return "flat-plate-sa"
            case .schaferTurek: return "schafer-turek"
            case .cylinder100: return "cylinder"
            case .sod: return "sod"
            case .ramp: return "ramp"
            }
        }
        public var estimate: String {
            switch self {
            case .cavity100: return "~10 s"
            case .cavity1000: return "~1 min"
            case .naturalConvection: return "~20 s"
            case .flatPlateSST, .flatPlateSA: return "~1 min"
            case .schaferTurek: return "~30 s"
            case .cylinder100: return "~5 min"
            case .sod: return "~10 s"
            case .ramp: return "~1 min"
            }
        }
    }

    static func fmt(_ v: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", v) }

    /// Solve with OpenFOAM in `directory` (a fresh temporary case when nil) and read the
    /// results back. Throws when the run fails. Custom OpenFOAM content (stages, raw dictionary
    /// text, extra files, coded conditions) can run programs, so a setup carrying any is refused
    /// unless the caller has had it approved (`allowCustomContent`).
    public static func solve(_ mesh: Mesh, _ setup: CaseSetup, iterations: Int? = nil, cores: Int = 1,
                             directory: URL? = nil, allowCustomContent: Bool = false,
                             log: @escaping (String) -> Void = { _ in }) throws -> Solution {
        guard allowCustomContent || setup.openfoam.activeContent.isEmpty else {
            throw SolverError("this case adds custom OpenFOAM content that can run programs; it must be reviewed and approved before it is solved")
        }
        var s = setup
        if let iterations { s.run.iterations = iterations }
        s.openfoam.cores = max(1, cores)
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("curlew-validate-\(UUID().uuidString.prefix(8))")
        s.openfoam.caseDirectory = dir.path
        s.openfoam.loadResults = true
        s.openfoam.continueFromLatestTime = false
        let initial = try FoamSolve.initialFields(mesh: mesh, setup: s)
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: initial, log: log, progress: { _, _, _, _ in })
        if directory == nil { try? FileManager.default.removeItem(at: dir) }
        if let f = out.failure { throw SolverError(f) }
        guard let sol = out.solution else { throw SolverError("OpenFOAM results could not be loaded") }
        return sol
    }

    public static func run(_ c: Case, cores: Int = 1, log: @escaping (String) -> Void = { _ in }) throws -> [Row] {
        let t0 = Date()
        var rows: [Row] = []
        func add(_ q: String, _ ref: String, _ comp: String, _ ok: Bool) {
            rows.append(Row(benchmark: c.rawValue, quantity: q, reference: ref, computed: comp, passed: ok, seconds: Date().timeIntervalSince(t0)))
        }
        func progress(_ line: String) { if line.hasPrefix("iter ") || line.hasPrefix("t = ") || line.hasPrefix("—") { log(line) } }
        switch c {
        case .cavity100, .cavity1000:
            let re = c == .cavity100 ? 100 : 1000
            let (m, s) = try Benchmarks.cavityCase(re: re, cells: re == 100 ? 64 : 128)
            let sol = try solve(m, s, iterations: 8000, cores: cores, log: progress)
            for cmp in Benchmarks.compareCavity(sol, re: re) {
                add("max |error| \(cmp.quantity)", "≤ 0.015", fmt(cmp.maxAbsError), cmp.maxAbsError <= 0.015)
            }
        case .naturalConvection:
            let (m, s, alpha) = try Benchmarks.naturalConvectionCase(log10Ra: 5, cells: 64)
            let sol = try solve(m, s, iterations: 6000, cores: cores, log: progress)
            let (nu, um, _, vm, _) = Benchmarks.measureNaturalConvection(sol, alpha: alpha)
            let ref = Benchmarks.deVahlDavis[5]!
            add("Nusselt number", "4.519 ±1%", fmt(nu), abs(nu - ref.nusselt) / ref.nusselt < 0.01)
            add("u_max L/α", "34.73 ±2%", fmt(um, 3), abs(um - ref.uMax) / ref.uMax < 0.02)
            add("v_max L/α", "68.59 ±2%", fmt(vm, 3), abs(vm - ref.vMax) / ref.vMax < 0.02)
        case .flatPlateSST, .flatPlateSA:
            let model: ViscousModel = c == .flatPlateSST ? .kOmegaSST : .spalartAllmaras
            let (m, s) = try Benchmarks.flatPlateCase(model: model)
            let sol = try solve(m, s, iterations: 5000, cores: cores, log: progress)
            let (cf, _) = Benchmarks.flatPlateSkinFriction(sol, x: 0.97)
            let rt = Benchmarks.flatPlateReTheta(sol, x: 0.97)
            let ks = Benchmarks.karmanSchoenherr(reTheta: rt)
            // SST sits ~5-7 % below the correlation on this case (a property of the model)
            let tol = c == .flatPlateSST ? 0.08 : 0.05
            add("Cf at x=0.97 (Re_θ = \(Int(rt)))", String(format: "%.5f ±%.0f%%", ks, tol * 100), String(format: "%.5f", cf), abs(cf - ks) / ks < tol)
        case .schaferTurek:
            var ms = MeshingSettings(template: .channelCylinder(length: 2.2, height: 0.41, cx: 0.2, cy: 0.2, radius: 0.05))
            ms.maxSize = 0.008; ms.wallSize = 0.001; ms.growthDistance = 0.3
            ms.blFirstHeight = 0.0003; ms.blGrowth = 1.15; ms.blThickness = 0.01
            let m = try GmshDriver.generate(ms).mesh
            let sol = try solve(m, Benchmarks.schaferTurekSetup(mesh: m), iterations: 4000, cores: cores, log: progress)
            let cd = Reports.evaluate(sol.setup.reports[0], solver: sol)
            let cl = Reports.evaluate(sol.setup.reports[1], solver: sol)
            let zc = m.bounds.centre.z
            let p = sol.sample("pressure", at: [Vec3(0.15, 0.2, zc), Vec3(0.25, 0.2, zc)])
            add("Drag coefficient", "5.57 – 5.59", fmt(cd), cd > 5.55 && cd < 5.60)
            // The lift (1/500 of the drag) is not mesh-converged on unstructured meshes: OpenFOAM gives
            // 0.0085 – 0.0138 on Gmsh meshes of 35k – 114k cells while the drag stays within 0.05 %.
            // The check only guards against gross errors.
            add("Lift coefficient (mesh-sensitive, ±30%)", "0.0104 – 0.0110", String(format: "%.5f", cl), abs(cl - 0.0107) < 0.3 * 0.0107)
            add("Δp front-back", "0.1172 – 0.1176", String(format: "%.5f", p[0] - p[1]), abs((p[0] - p[1]) - 0.1174) < 0.0006)
        case .sod:
            let (m, s, endT) = try Benchmarks.sodCase(cells: 400)
            let sol = try solve(m, s, cores: cores, log: progress)
            let (l1, _) = Benchmarks.sodError(sol, endTime: endT)
            // rhoCentralFoam (Kurganov–Tadmor central scheme) smears the contact more than an upwind Roe scheme
            add("L1 density error at t = 0.2 (400 cells)", "≤ 0.015", String(format: "%.4f", l1), l1 <= 0.015)
        case .ramp:
            let (m, s) = try Benchmarks.rampCase()
            let sol = try solve(m, s, iterations: 4000, cores: cores, log: progress)
            let beta = Benchmarks.obliqueShockAngle(mach: 2.5, deflection: 15 * .pi / 180)
            let mn = 2.5 * sin(beta)
            let p21 = 1 + 2 * 1.4 / 2.4 * (mn * mn - 1)
            var pr = 0.0, a = 0.0
            if let z = m.zone(named: "ramp") {
                for f in z.faceRange where m.faceCentres[f].x > 0.8 && m.faceCentres[f].x < 1.3 {
                    pr += (sol.state.bP[f - m.nInternalFaces] + s.general.operatingPressure) * m.faceAreaMag[f]; a += m.faceAreaMag[f]
                }
            }
            let ratio = pr / a / 1e5
            add("Pressure ratio across the shock", String(format: "%.4f ±1%%", p21), String(format: "%.4f", ratio), abs(ratio - p21) / p21 < 0.01)
        case .cylinder100:
            let (m, s) = try Benchmarks.cylinderCase(dt: 0.05, endTime: 200)
            let sol = try solve(m, s, cores: cores, log: progress)
            if let r = Benchmarks.analyseShedding(sol.reportHistory, settle: 100) {
                add("Strouhal number", "0.164 – 0.166 (±3%)", fmt(r.strouhal), abs(r.strouhal - 0.165) / 0.165 < 0.03)
                add("Mean drag coefficient", "1.33 – 1.35 (±3%)", fmt(r.cdMean), abs(r.cdMean - 1.34) / 1.34 < 0.03)
                add("Lift amplitude", "0.32 – 0.34 (±10%)", fmt(r.clAmplitude), abs(r.clAmplitude - 0.33) / 0.33 < 0.10)
            } else {
                add("Periodic shedding", "present", "not detected", false)
            }
        }
        return rows
    }
}
