import Testing
import Foundation
@testable import FluidCraftMesh
@testable import FluidCraftSolver
@testable import FluidCraftPost
@testable import FluidCraftFoam

let hasOpenFOAM = !FoamDiscovery.discover().isEmpty

func material(_ name: String, rho: Double = 1, mu: Double = 1e-3, cp: Double = 1000, k: Double = 1) -> Material {
    var m = Material(name: name)
    m.density = rho; m.viscosity = mu; m.specificHeat = cp; m.thermalConductivity = k
    return m
}

/// Solve with OpenFOAM in a temporary case and read the results back.
func solve(_ mesh: Mesh, _ s: CaseSetup, iterations: Int = 3000) throws -> Solution {
    try ValidationSuite.solve(mesh, s, iterations: iterations)
}

/// A solution holding FluidCraft's initial fields (no solver run): enough for post-processing tests.
func initialSolution(_ mesh: Mesh, _ s: CaseSetup) throws -> Solution {
    let sol = try Solution(mesh: mesh, setup: s)
    sol.loadInitialFields()
    return sol
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-foam-\(UUID().uuidString)")
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

@Suite(.enabled(if: hasOpenFOAM)) struct PostTests {
    /// A velocity field given by an expression, as standard initialization writes it.
    func cavityWithField() throws -> (Mesh, CaseSetup, Solution) {
        var (m, s) = try Benchmarks.cavityCase(re: 100, cells: 16)
        s.initialization.method = .standard
        s.initialization.velocity = [.expression("y"), .expression("-x"), 0]
        return (m, s, try initialSolution(m, s))
    }

    @Test func planeCutAndVTK() throws {
        let (_, _, sol) = try cavityWithField()
        let post = PostProcessor(solver: sol)
        let plane = post.surface(.plane(point: [0.5, 0.5, 0.05], normal: [1, 0, 0]), field: "velocity-magnitude")
        #expect(!plane.isEmpty)
        let (_, area) = plane.areaAverage()
        #expect(abs(area - 0.1) < 1e-6)   // 1 x 0.1 slab cross-section (float32 vertices)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-test-\(UUID().uuidString).vtu")
        try VTKExport.write(solver: sol, to: url)
        let d = try Data(contentsOf: url)
        #expect(d.count > 1000)
        #expect(String(decoding: d.prefix(200), as: UTF8.self).contains("UnstructuredGrid"))
        try? FileManager.default.removeItem(at: url)
    }

    /// Initial fields follow the expressions and patches; vorticity of (y, -x) is 2.
    @Test func initialFieldsAndGradients() throws {
        var (m, s, sol) = try cavityWithField()
        for c in 0..<m.nCells {
            let x = m.cellCentres[c]
            #expect(abs(sol.state.u[c].x - x.y) < 1e-12 && abs(sol.state.u[c].y + x.x) < 1e-12)
        }
        let w = try #require(FieldCatalog.cellValues("vorticity-magnitude", sol))
        #expect(abs(w[m.nCells / 2] - 2) < 1e-6)
        var patch = PatchSettings(); patch.field = "temperature"; patch.region = .box; patch.parameters = [0, 0, -1, 0.5, 0.5, 1]; patch.value = 350
        s.initialization.patches = [patch]
        let p2 = try initialSolution(m, s)
        let inside = (0..<m.nCells).filter { m.cellCentres[$0].x < 0.5 && m.cellCentres[$0].y < 0.5 }
        #expect(inside.allSatisfy { p2.state.T[$0] == 350 })
        #expect(p2.state.isInitialization)
    }

    @Test func solutionArchiveRoundTrip() throws {
        let (m, s, sol) = try cavityWithField()
        let data = try SolutionArchive.write(sol)
        let other = try Solution(mesh: m, setup: s)
        try SolutionArchive.read(data, into: other)
        #expect(other.state.u == sol.state.u)
        #expect(other.state.p == sol.state.p)
        #expect(other.iteration == sol.iteration)
    }
}

@Suite(.enabled(if: hasOpenFOAM)) struct ScalarEditingTests {
    /// Removing or renaming a user scalar keeps the other scalar's field and never traps.
    @Test func removeScalarAfterLoading() throws {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 20), y: BlockAxis(from: 0, to: 0.2, cells: 5), depth: 0.1,
                                     sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.models.passiveScalars = [PassiveScalar(name: "a"), PassiveScalar(name: "b")]
        s.adopt(mesh: mesh)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.1
        inlet.scalars = ["a": 1, "b": 2]
        s.boundaries["x-min"] = inlet
        let sol = try Solution(mesh: mesh, setup: s)
        var e = ExternalSolution(u: [Vec3](repeating: Vec3(0.1, 0, 0), count: mesh.nCells), p: [Double](repeating: 0, count: mesh.nCells))
        e.scalars = ["a": [Double](repeating: 1, count: mesh.nCells), "b": (0..<mesh.nCells).map { Double($0) }]
        try sol.load(external: e)
        let bField = sol.state.scalars[1]
        // remove "a": "b" must keep its data
        s.models.passiveScalars.removeAll { $0.name == "a" }
        s.boundaries["x-min"]!.scalars["a"] = nil
        try sol.updateSetup(s)
        #expect(sol.state.scalars.count == 1)
        #expect(sol.state.scalars[0] == bField)
        #expect(FieldCatalog.cellValues("b", sol) != nil)
        #expect(FieldCatalog.cellValues("a", sol) == nil)
        s.models.passiveScalars = []
        try sol.updateSetup(s)
        #expect(sol.state.scalars.isEmpty)
    }
}
