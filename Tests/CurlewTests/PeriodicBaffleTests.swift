import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewSolver
@testable import CurlewFoam

/// Periodic patches (cyclicAMI), meanVelocityForce and createBaffles (fan, porous jump, thin
/// wall), all set up by Curlew and done by OpenFOAM.
@Suite struct PeriodicBaffleTests {
    static let hasFoam = !FoamDiscovery.discover().isEmpty

    func channel(nx: Int = 40, ny: Int = 16) throws -> Mesh {
        try BlockMeshSpec(x: BlockAxis(from: 0, to: 0.4, cells: nx), y: BlockAxis(from: 0, to: 0.1, cells: ny), depth: 0.01, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.1, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.4, 0, -1], boxMax: [0.4, 0.1, 1]),
            PatchRule(name: "walls", kind: .wall, boxMin: [0, 0, -1], boxMax: [0.4, 0, 1]),
            PatchRule(name: "top", kind: .wall, boxMin: [0, 0.1, -1], boxMax: [0.4, 0.1, 1]),
        ]).build()
    }

    func duct(_ mesh: Mesh, speed: Double = 0.1) -> CaseSetup {
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(speed)
        s.boundaries["inlet"] = inlet
        s.boundaries["outlet"] = BoundarySettings(type: .pressureOutlet)
        s.initialization.method = .standard
        s.initialization.velocity = [.constant(speed), 0, 0]
        s.run.iterations = 2000
        s.general.backend = .openfoam
        s.openfoam.initialFields = .uniform
        s.openfoam.residualP = 1e-7; s.openfoam.residualU = 1e-8
        return s
    }

    func run(_ mesh: Mesh, _ setup: CaseSetup, _ tag: String) throws -> (PressureBasedSolver, FoamSolve.Outcome) {
        var s = setup
        s.openfoam.caseDirectory = "/tmp/curlew-test-\(tag)"
        try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory)
        var lines: [String] = []
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { lines.append($0) }, progress: { _, _, _, _ in })
        if out.failure != nil { print("LOG \(tag): \(out.failure!)\n" + lines.suffix(30).joined(separator: "\n")) }
        #expect(out.failure == nil, "\(tag): \(out.failure ?? "")")
        let sol = try #require(out.solver)
        if out.failure == nil { try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory) }
        return (sol, out)
    }

    func inletPressure(_ s: PressureBasedSolver) -> Double {
        var r = ReportDefinition(name: "p", kind: .areaWeightedAverage); r.zones = ["inlet"]; r.field = "pressure"
        return Reports.evaluate(r, solver: s)
    }

    @Test func periodicEntriesAreWritten() throws {
        let mesh = try channel()
        var s = duct(mesh)
        s.boundaries["inlet"]!.periodic = PeriodicLink(partner: "outlet")
        let e = try FoamCaseWriter.periodicPatchEntries(mesh, s)
        #expect(e["inlet"]?.contains("neighbourPatch  outlet") == true && e["outlet"]?.contains("neighbourPatch  inlet") == true)
        #expect(e["inlet"]?.contains("separationVector (0.4 0 0)") == true && e["outlet"]?.contains("separationVector (-0.4 -0 -0)") == true)
        var r = s
        r.boundaries["inlet"]!.periodic!.rotational = true
        r.boundaries["inlet"]!.periodic!.angle = 72
        let er = try FoamCaseWriter.periodicPatchEntries(mesh, r)
        #expect(er["inlet"]?.contains("rotationAngle   72") == true && er["outlet"]?.contains("rotationAngle   -72") == true)
    }

    /// Fully developed laminar flow between plates, driven by meanVelocityForce through a
    /// periodic inlet/outlet pair: u(y) = 6 Ū y (H − y) / H².
    @Test(.enabled(if: hasFoam)) func periodicPoiseuille() throws {
        let mesh = try channel(nx: 8, ny: 20)
        var s = duct(mesh)
        let Ubar = 0.01
        s.boundaries["inlet"]!.periodic = PeriodicLink(partner: "outlet")
        s.openfoam.meanVelocity = [Ubar, 0, 0]
        s.run.iterations = 3000
        let (sol, _) = try run(mesh, s, "periodic")
        var maxErr = 0.0
        for c in 0..<mesh.nCells {
            let y = mesh.cellCentres[c].y
            maxErr = max(maxErr, abs(sol.state.u[c].x - 6 * Ubar * y * (0.1 - y) / 0.01))
        }
        #expect(maxErr < 0.02 * 1.5 * Ubar, "max |u - Poiseuille| = \(maxErr)")
    }

    /// A fan with a flat curve (0.5 Pa at any flow) halfway down the duct lowers the inlet
    /// pressure by 0.5 Pa; a porous jump with D only raises it by D μ Ū L.
    @Test(.enabled(if: hasFoam)) func fanAndPorousJump() throws {
        let mesh = try channel()
        let base = duct(mesh)
        let (s0, _) = try run(mesh, base, "nofan")
        let p0 = inletPressure(s0)

        var fan = FoamBaffle(name: "fan1", kind: .fan)
        fan.shape = .plate; fan.origin = [0.2, -1, -1]; fan.span = [0, 2, 2]; fan.normal = [1, 0, 0]
        fan.fanCurve = [[0, 0.5], [1, 0.5]]
        var sf = base; sf.openfoam.baffles = [fan]
        let (s1, out1) = try run(mesh, sf, "fan")
        #expect(out1.failure == nil)
        let p1 = inletPressure(s1)
        #expect(abs((p0 - p1) - 0.5) < 0.05, "fan: inlet pressure \(p0) → \(p1)")

        var jump = FoamBaffle(name: "screen", kind: .porousJump)
        jump.shape = .plate; jump.origin = [0.2, -1, -1]; jump.span = [0, 2, 2]
        jump.darcy = 1e7; jump.inertial = 0; jump.thickness = 0.01
        jump.uniformJump = true      // from the mean velocity: Δp is exactly D μ Ū L
        var sp = base; sp.openfoam.baffles = [jump]
        let (s2, _) = try run(mesh, sp, "porousjump")
        let mu = s0.setup.material(named: "air")!.viscosity
        let expected = 1e7 * mu * 0.1 * 0.01
        let p2 = inletPressure(s2)
        #expect(abs((p2 - p0) - expected) < 0.05 * expected, "porous jump: \(p2 - p0) vs \(expected)")
    }

    @Test(.enabled(if: hasFoam)) func thinWallBaffle() throws {
        let mesh = try channel()
        var s = duct(mesh)
        var w = FoamBaffle(name: "plate", kind: .thinWall)
        w.shape = .plate; w.origin = [0.1, 0.03, -1]; w.span = [0.15, 0, 2]   // a horizontal plate in the stream
        s.openfoam.baffles = [w]
        s.run.iterations = 800
        let (sol, out) = try run(mesh, s, "thinwall")
        #expect(out.failure == nil)
        // the plate adds drag: the inlet pressure is higher than in the empty duct
        let (s0, _) = try run(mesh, duct(mesh), "thinwall0")
        #expect(inletPressure(sol) > inletPressure(s0) * 1.05)
    }
}
