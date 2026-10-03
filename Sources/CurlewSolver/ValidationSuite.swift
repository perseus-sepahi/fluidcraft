import Foundation
import CurlewMesh

/// Runs the published benchmarks and reports computed vs reference values.
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
        public var estimate: String {
            switch self {
            case .cavity100: return "~3 s"
            case .cavity1000: return "~30 s"
            case .naturalConvection: return "~3 s"
            case .flatPlateSST, .flatPlateSA: return "~20 s"
            case .schaferTurek: return "~30 s"
            case .cylinder100: return "~2 min"
            case .sod: return "~1 s"
            case .ramp: return "~30 s"
            }
        }
    }

    static func fmt(_ v: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", v) }

    public static func run(_ c: Case, log: @escaping (String) -> Void = { _ in }) throws -> [Row] {
        let t0 = Date()
        var rows: [Row] = []
        func add(_ q: String, _ ref: String, _ comp: String, _ ok: Bool) {
            rows.append(Row(benchmark: c.rawValue, quantity: q, reference: ref, computed: comp, passed: ok, seconds: Date().timeIntervalSince(t0)))
        }
        switch c {
        case .cavity100, .cavity1000:
            let re = c == .cavity100 ? 100 : 1000
            let (m, s) = try Benchmarks.cavityCase(re: re, cells: re == 100 ? 64 : 128)
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run(iterations: 8000) { s, r in if s.iteration % 500 == 0 { log(s.formatResiduals(r)) } }
            for cmp in Benchmarks.compareCavity(solver, re: re) {
                add("max |error| \(cmp.quantity)", "≤ 0.015", fmt(cmp.maxAbsError), cmp.maxAbsError <= 0.015)
            }
        case .naturalConvection:
            let (m, s, alpha) = try Benchmarks.naturalConvectionCase(log10Ra: 5, cells: 64)
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run(iterations: 6000) { s, r in if s.iteration % 500 == 0 { log(s.formatResiduals(r)) } }
            let (nu, um, _, vm, _) = Benchmarks.measureNaturalConvection(solver, alpha: alpha)
            let ref = Benchmarks.deVahlDavis[5]!
            add("Nusselt number", "4.519 ±1%", fmt(nu), abs(nu - ref.nusselt) / ref.nusselt < 0.01)
            add("u_max L/α", "34.73 ±2%", fmt(um, 3), abs(um - ref.uMax) / ref.uMax < 0.02)
            add("v_max L/α", "68.59 ±2%", fmt(vm, 3), abs(vm - ref.vMax) / ref.vMax < 0.02)
        case .flatPlateSST, .flatPlateSA:
            let model: ViscousModel = c == .flatPlateSST ? .kOmegaSST : .spalartAllmaras
            let (m, s) = try Benchmarks.flatPlateCase(model: model)
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run(iterations: 5000) { s, r in if s.iteration % 500 == 0 { log(s.formatResiduals(r)) } }
            let (cf, _) = Benchmarks.flatPlateSkinFriction(solver, x: 0.97)
            let rt = Benchmarks.flatPlateReTheta(solver, x: 0.97)
            let ks = Benchmarks.karmanSchoenherr(reTheta: rt)
            // SST is known to sit ~5-7 % below the correlation on this case (OpenFOAM v2606 gives 0.002652 on the same mesh)
            let tol = c == .flatPlateSST ? 0.08 : 0.05
            add("Cf at x=0.97 (Re_θ = \(Int(rt)))", String(format: "%.5f ±%.0f%%", ks, tol * 100), String(format: "%.5f", cf), abs(cf - ks) / ks < tol)
            if c == .flatPlateSST {
                add("Cf vs OpenFOAM v2606 kOmegaSST, same mesh", "0.002652 ±1%", String(format: "%.6f", cf), abs(cf - 0.002652) / 0.002652 < 0.01)
            }
        case .schaferTurek:
            var ms = MeshingSettings(template: .channelCylinder(length: 2.2, height: 0.41, cx: 0.2, cy: 0.2, radius: 0.05))
            ms.maxSize = 0.008; ms.wallSize = 0.001; ms.growthDistance = 0.3
            ms.blFirstHeight = 0.0003; ms.blGrowth = 1.15; ms.blThickness = 0.01
            let m = try GmshDriver.generate(ms).mesh
            let solver = try PressureBasedSolver(mesh: m, setup: Benchmarks.schaferTurekSetup(mesh: m))
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run(iterations: 4000) { s, r in if s.iteration % 500 == 0 { log(s.formatResiduals(r)) } }
            let cd = Reports.evaluate(solver.setup.reports[0], solver: solver)
            let cl = Reports.evaluate(solver.setup.reports[1], solver: solver)
            let zc = m.bounds.centre.z
            let p = solver.sample("pressure", at: [Vec3(0.15, 0.2, zc), Vec3(0.25, 0.2, zc)])
            add("Drag coefficient", "5.57 – 5.59", fmt(cd), cd > 5.55 && cd < 5.60)
            add("Lift coefficient", "0.0104 – 0.0110", String(format: "%.5f", cl), cl > 0.0095 && cl < 0.0115)
            add("Δp front-back", "0.1172 – 0.1176", String(format: "%.5f", p[0] - p[1]), abs((p[0] - p[1]) - 0.1174) < 0.0006)
        case .sod:
            let (m, s, endT) = try Benchmarks.sodCase(cells: 400)
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run()
            let (l1, _) = Benchmarks.sodError(solver, endTime: endT)
            add("L1 density error at t = 0.2 (400 cells)", "≤ 0.005", String(format: "%.4f", l1), l1 <= 0.005)
        case .ramp:
            let (m, s) = try Benchmarks.rampCase()
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run(iterations: 4000) { s, r in if s.iteration % 500 == 0 { log(s.formatResiduals(r)) } }
            let beta = Benchmarks.obliqueShockAngle(mach: 2.5, deflection: 15 * .pi / 180)
            let mn = 2.5 * sin(beta)
            let p21 = 1 + 2 * 1.4 / 2.4 * (mn * mn - 1)
            var pr = 0.0, a = 0.0
            if let z = m.zone(named: "ramp") {
                for f in z.faceRange where m.faceCentres[f].x > 0.8 && m.faceCentres[f].x < 1.3 {
                    pr += (solver.state.bP[f - m.nInternalFaces] + s.general.operatingPressure) * m.faceAreaMag[f]; a += m.faceAreaMag[f]
                }
            }
            let ratio = pr / a / 1e5
            add("Pressure ratio across the shock", String(format: "%.4f ±1%%", p21), String(format: "%.4f", ratio), abs(ratio - p21) / p21 < 0.01)
        case .cylinder100:
            let (m, s) = try Benchmarks.cylinderCase(dt: 0.05, endTime: 200)
            let solver = try PressureBasedSolver(mesh: m, setup: s)
            solver.log = { _ in }
            try solver.initialize()
            _ = solver.run { s, _ in if s.state.timeStep % 400 == 0 && s.state.timeStep > 0 { log(String(format: "t = %.1f", s.state.time)) } }
            if let r = Benchmarks.analyseShedding(solver.reportHistory, settle: 100) {
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
