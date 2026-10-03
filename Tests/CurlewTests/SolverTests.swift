import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewLinear
@testable import CurlewSolver
@testable import CurlewPost

func material(_ name: String, rho: Double = 1, mu: Double = 1e-3, cp: Double = 1000, k: Double = 1) -> Material {
    var m = Material(name: name)
    m.density = rho; m.viscosity = mu; m.specificHeat = cp; m.thermalConductivity = k
    return m
}

func solve(_ mesh: Mesh, _ s: CaseSetup, iterations: Int = 3000) throws -> PressureBasedSolver {
    let solver = try PressureBasedSolver(mesh: mesh, setup: s)
    solver.log = { _ in }
    try solver.initialize()
    _ = solver.run(iterations: iterations)
    return solver
}

@Suite struct ExpressionTests {
    @Test func arithmeticAndFunctions() throws {
        #expect(try Expr("1 + 2 * 3").value() == 7)
        #expect(try Expr("2^3^2").value() == 512)          // right associative
        #expect(try Expr("-2^2").value() == -4)
        #expect(abs(try Expr("sin(pi/2) + exp(0) + sqrt(16)").value() - 6) < 1e-12)
        #expect(try Expr("if(x > 1, 10, 20)").value(x: 2) == 10)
        #expect(try Expr("4*0.3*y*(0.41-y)/0.41^2").value(y: 0.205) - 0.3 < 1e-12)
        #expect(try Expr("2 [m/s] * 3").value() == 6)      // units ignored
    }
    @Test func namedExpressions() throws {
        let d = try Expr.compileNamed([("Umax", "1.5"), ("H", "2"), ("profile", "4*Umax*y*(H-y)/H^2")])
        #expect(abs(d["profile"]!.value(y: 1) - 1.5) < 1e-12)
    }
    @Test func errors() {
        #expect(throws: (any Error).self) { try Expr("1 +") }
        #expect(throws: (any Error).self) { try Expr("foo(1)") }
        #expect(throws: (any Error).self) { try Expr("unknownName * 2") }
        #expect(throws: (any Error).self) { try Expr.compileNamed([("a", "b"), ("b", "a")]) }
    }
}

@Suite struct CaseFileTests {
    @Test func lenientDecoding() throws {
        let json = """
        {"title": "minimal", "models": {"viscous": "k-omega-sst"},
         "boundaries": {"inlet": {"type": "velocity-inlet", "velocityMagnitude": "2*sin(t)"}},
         "materials": [{"name": "water-liquid", "density": 1000}]}
        """
        let s = try CaseSetup.decodeLenient(Data(json.utf8))
        #expect(s.title == "minimal")
        #expect(s.models.viscous == .kOmegaSST)
        #expect(s.boundaries["inlet"]?.type == .velocityInlet)
        #expect(s.boundaries["inlet"]?.velocityMagnitude == .expression("2*sin(t)"))
        #expect(s.material(named: "water-liquid")?.density == 1000)
        #expect(s.material(named: "water-liquid")?.viscosity == 1.003e-3)   // library default kept
        #expect(s.material(named: "air") != nil)
        #expect(s.controls.urf.pressure == 0.3)                              // Fluent default
        let round = try CaseSetup.decodeLenient(try s.encoded())
        #expect(round == s)
    }
}

@Suite struct MeshIOTests {
    func sample() throws -> Mesh {
        try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 5), y: BlockAxis(from: 0, to: 0.5, cells: 4), z: BlockAxis(from: 0, to: 0.3, cells: 3),
                          sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet], cellZones: [.init(name: "block", kind: .solid, box: [0.4, 0, 0, 0.6, 0.25, 0.3])]).build()
    }

    @Test func fluentRoundTrip() throws {
        let m = try sample()
        let text = MeshWriters.fluentMesh(m)
        let r = try FluentMeshReader.read(data: Data(text.utf8))
        #expect(r.nCells == m.nCells)
        #expect(r.nFaces == m.nFaces)
        #expect(abs(r.totalVolume - m.totalVolume) < 1e-12)
        #expect(Set(r.boundaryZones.map(\.name)) == Set(m.boundaryZones.map(\.name)))
        #expect(r.zone(named: "x-min")?.kind == .velocityInlet)
        #expect(r.zone(named: "x-max")?.kind == .pressureOutlet)
        #expect(r.cellZones.count == 2)
        #expect(r.cellZones.first { $0.name == "block" }?.kind == .solid)
    }

    @Test func foamRoundTrip() throws {
        let m = try sample()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("curlew-foam-\(UUID().uuidString)")
        try MeshWriters.writeFoamPolyMesh(m, caseDir: dir)
        let r = try FoamMeshReader.read(url: dir)
        #expect(r.nCells == m.nCells && r.nFaces == m.nFaces)
        #expect(abs(r.totalVolume - m.totalVolume) < 1e-12)
        #expect(r.zone(named: "x-min") != nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func fluent2DMesh() throws {
        // two quads side by side, hand-written in Fluent 2D ASCII format
        let msh = """
        (0 "two quads")
        (2 2)
        (10 (0 1 6 0 2))
        (12 (0 1 2 0))
        (13 (0 1 7 0))
        (10 (1 1 6 1 2)(
        0 0
        1 0
        2 0
        0 1
        1 1
        2 1
        ))
        (12 (2 1 2 1 3))
        (13 (3 1 1 2 2)(
        2 5 1 2
        ))
        (13 (4 2 3 3 2)(
        1 2 1 0
        2 3 2 0
        ))
        (13 (5 4 5 3 2)(
        5 4 1 0
        6 5 2 0
        ))
        (13 (6 6 6 a 2)(
        4 1 1 0
        ))
        (13 (7 7 7 5 2)(
        3 6 2 0
        ))
        (45 (2 fluid fluid)())
        (45 (3 interior interior-fluid)())
        (45 (4 wall bottom)())
        (45 (5 wall top)())
        (45 (6 velocity-inlet inlet)())
        (45 (7 pressure-outlet outlet)())
        """
        let m = try FluentMeshReader.read(data: Data(msh.utf8), depth2D: 0.1)
        #expect(m.nCells == 2)
        #expect(m.isTwoDimensional)
        #expect(abs(m.totalVolume - 0.2) < 1e-12)
        #expect(m.zone(named: "inlet")?.kind == .velocityInlet)
        #expect(m.zone(named: "outlet")?.kind == .pressureOutlet)
        #expect(m.zone(named: "bottom")?.count == 2)
    }

    @Test func gmshReaderV2() throws {
        let msh = """
        $MeshFormat
        2.2 0 8
        $EndMeshFormat
        $PhysicalNames
        3
        1 1 "wall"
        1 2 "inlet"
        2 3 "fluid"
        $EndPhysicalNames
        $Nodes
        4
        1 0 0 0
        2 1 0 0
        3 1 1 0
        4 0 1 0
        $EndNodes
        $Elements
        6
        1 1 2 1 1 1 2
        2 1 2 1 1 2 3
        3 1 2 1 1 3 4
        4 1 2 2 2 4 1
        5 2 2 3 1 1 2 3
        6 2 2 3 1 1 3 4
        $EndElements
        """
        let m = try GmshReader.read(data: Data(msh.utf8), depth2D: 1)
        #expect(m.nCells == 2)
        #expect(abs(m.totalVolume - 1) < 1e-12)
        #expect(m.zone(named: "inlet")?.count == 1)
        #expect(m.zone(named: "wall")?.count == 3)
        #expect(m.cellShapeHistogram()["wedges"] == 2)
    }
}

@Suite struct AnalyticSolutionTests {
    /// Plane Poiseuille flow: u(y) = 6 U y (H - y)/H^2, dp/dx = -12 mu U / H^2.
    @Test func poiseuilleChannel() throws {
        let H = 0.1, L = 1.0, U = 0.01, mu = 1e-3
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: L, cells: 40), y: BlockAxis(from: 0, to: H, cells: 20), depth: 0.01,
                                     sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.materials.append(material("f", mu: mu))
        s.adopt(mesh: mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
        var inlet = BoundarySettings(type: .velocityInlet)
        inlet.velocitySpecification = .components
        inlet.velocity = [.expression("6*\(U)*y*(\(H)-y)/\(H)^2"), 0, 0]
        s.boundaries["x-min"] = inlet
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.residuals.continuity = 1e-8; s.residuals.velocity = 1e-9
        let solver = try solve(mesh, s)
        let z = mesh.bounds.centre.z
        // velocity profile at x = 0.8
        let ys = stride(from: 0.005, to: H, by: 0.01).map { $0 }
        let u = solver.sample("x-velocity", at: ys.map { Vec3(0.8, $0, z) })
        for (y, v) in zip(ys, u) {
            let exact = 6 * U * y * (H - y) / (H * H)
            #expect(abs(v - exact) < 0.01 * 1.5 * U, "u(\(y)) = \(v), exact \(exact)")
        }
        let p = solver.sample("pressure", at: [Vec3(0.3, H / 2, z), Vec3(0.7, H / 2, z)])
        let dpdx = (p[1] - p[0]) / 0.4
        let exact = -12 * mu * U / (H * H)
        #expect(abs(dpdx - exact) / abs(exact) < 0.01, "dp/dx = \(dpdx), exact \(exact)")
    }

    /// Steady conduction in a slab with uniform source: T(x) = T0 + q x (L - x) / (2 k).
    @Test func conductionWithSource() throws {
        let L = 1.0, q = 1000.0, k = 10.0
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: L, cells: 50), y: BlockAxis(from: 0, to: 0.1, cells: 2), depth: 0.1).build()
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        s.materials.append(material("solid-k10", k: k))
        s.materials[s.materials.count - 1].kind = .solid
        s.adopt(mesh: mesh)
        for key in s.cellZones.keys { s.cellZones[key]!.kind = .solid; s.cellZones[key]!.material = "solid-k10"; s.cellZones[key]!.energySource = .constant(q) }
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = 300
        s.boundaries["x-min"] = hot; s.boundaries["x-max"] = hot
        s.residuals.energy = 1e-12
        let mesh2 = mesh
        // the single zone must be solid in the mesh too
        mesh2.updateCellZone(0, kind: .solid)
        let solver = try solve(mesh2, s, iterations: 200)
        var maxErr = 0.0
        for c in 0..<mesh.nCells {
            let x = mesh.cellCentres[c].x
            maxErr = max(maxErr, abs(solver.state.T[c] - (300 + q * x * (L - x) / (2 * k))))
        }
        // cell-centred FV with a half-cell boundary distance is second order: error = q dx^2 / (8 k)
        let dx = L / 50
        #expect(maxErr < 1.01 * q * dx * dx / (8 * k), "max |T - exact| = \(maxErr)")
    }

    /// Conjugate composite wall: fluid-free solid slabs in series reproduce series resistances.
    @Test func compositeWall() throws {
        // two solids (k=1 for x<0.5, k=4 for x>0.5), T(0)=400, T(1)=300 -> interface T = 300 + 100*(0.5/4)/(0.5/1+0.5/4) = 320
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 40), y: BlockAxis(from: 0, to: 0.1, cells: 1), depth: 0.1,
                                     cellZones: [.init(name: "right", kind: .solid, box: [0.5, -1, -1, 1, 1, 1])]).build()
        mesh.updateCellZone(0, kind: .solid)
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        var a = material("k1", k: 1); a.kind = .solid
        var b = material("k4", k: 4); b.kind = .solid
        s.materials += [a, b]
        s.adopt(mesh: mesh)
        s.cellZones["fluid"]!.kind = .solid; s.cellZones["fluid"]!.material = "k1"
        s.cellZones["right"]!.material = "k4"
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = 400
        var cold = BoundarySettings(type: .wall); cold.thermalCondition = .temperature; cold.temperature = 300
        s.boundaries["x-min"] = hot; s.boundaries["x-max"] = cold
        s.residuals.energy = 1e-12
        let solver = try solve(mesh, s, iterations: 200)
        // exact piecewise-linear profile: 400 - 160 x (x < 0.5), 320 - 40 (x - 0.5) (x > 0.5)
        var maxErr = 0.0
        for c in 0..<mesh.nCells {
            let x = mesh.cellCentres[c].x
            let exact = x < 0.5 ? 400 - 160 * x : 320 - 40 * (x - 0.5)
            maxErr = max(maxErr, abs(solver.state.T[c] - exact))
        }
        #expect(maxErr < 1e-6, "max |T - exact| = \(maxErr)")
        // heat flux: q = 100 / (0.5/1 + 0.5/4) = 160 W/m2
        let nI = mesh.nInternalFaces
        let f = mesh.zone(named: "x-min")!.start
        #expect(abs(solver.state.bHeatFlux[f - nI] - 160) / 160 < 0.01)
    }

    /// Uniform flow through a porous slab (slip walls): dp = (mu/alpha U + C2 rho U^2 / 2) * thickness.
    @Test(arguments: [100, 400])
    func porousPressureDrop(cells: Int) throws {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: cells), y: BlockAxis(from: 0, to: 0.1, cells: 4), depth: 0.1,
                                     sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet, "y-min": .symmetry, "y-max": .symmetry],
                                     cellZones: [.init(name: "filter", kind: .fluid, box: [0.4, -1, -1, 0.5, 1, 1])]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var por = PorousSettings(); por.viscousResistance = [1e6, 1e6, 1e6]; por.inertialResistance = [100, 100, 100]
        s.cellZones["filter"]?.porous = por
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.5
        s.boundaries["x-min"] = inlet
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.methods.pressure = .standard
        s.residuals.continuity = 1e-8; s.residuals.velocity = 1e-9
        let solver = try solve(mesh, s)
        let z = mesh.bounds.centre.z
        let p = solver.sample("pressure", at: [Vec3(0.3, 0.05, z), Vec3(0.6, 0.05, z)])
        let air = MaterialLibrary.lookup("air")!
        let exact = (air.viscosity * 1e6 * 0.5 + 100 * 0.5 * air.density * 0.25) * 0.1
        // the pressure kink at the porous interfaces is shared by the two adjacent cells:
        // a consistent interface error that vanishes with refinement (2.8 % -> 0.4 % for 4x cells)
        let tol = cells >= 400 ? 0.006 : 0.035
        #expect(abs((p[0] - p[1]) - exact) / exact < tol, "dp \(p[0] - p[1]) vs \(exact)")
    }

    @Test func sodShockTube() throws {
        let (m, s, endT) = try Benchmarks.sodCase(cells: 200)
        let solver = try solve(m, s)
        let (l1, _) = Benchmarks.sodError(solver, endTime: endT)
        #expect(l1 < 0.008, "L1 density error \(l1)")
    }

    @Test func cavityRe100() throws {
        let (m, s) = try Benchmarks.cavityCase(re: 100, cells: 32)
        let solver = try solve(m, s, iterations: 2000)
        for c in Benchmarks.compareCavity(solver, re: 100) { #expect(c.maxAbsError < 0.03, "\(c.quantity): \(c.maxAbsError)") }
    }
}

@Suite struct PostTests {
    @Test func planeCutAndVTK() throws {
        let (m, s) = try Benchmarks.cavityCase(re: 100, cells: 16)
        let solver = try solve(m, s, iterations: 50)
        let post = PostProcessor(solver: solver)
        let plane = post.surface(.plane(point: [0.5, 0.5, 0.05], normal: [1, 0, 0]), field: "velocity-magnitude")
        #expect(!plane.isEmpty)
        let (_, area) = plane.areaAverage()
        #expect(abs(area - 0.1) < 1e-6)   // 1 x 0.1 slab cross-section (float32 vertices)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("curlew-test-\(UUID().uuidString).vtu")
        try VTKExport.write(solver: solver, to: url)
        let d = try Data(contentsOf: url)
        #expect(d.count > 1000)
        #expect(String(decoding: d.prefix(200), as: UTF8.self).contains("UnstructuredGrid"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func solutionArchiveRoundTrip() throws {
        let (m, s) = try Benchmarks.cavityCase(re: 100, cells: 16)
        let solver = try solve(m, s, iterations: 30)
        let data = try SolutionArchive.write(solver)
        let other = try PressureBasedSolver(mesh: m, setup: s)
        other.log = { _ in }
        try SolutionArchive.read(data, into: other)
        #expect(other.state.u == solver.state.u)
        #expect(other.state.p == solver.state.p)
        #expect(other.iteration == solver.iteration)
    }
}
