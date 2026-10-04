import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewLinear

/// Laplacian with Dirichlet boundaries assembled the same way the solver does.
func assemblePoisson(_ m: Mesh, boundary: (Vec3) -> Double, source: (Vec3) -> Double = { _ in 0 })
    -> (SparseMatrix, [Double]) {
    let (pat, up, lo) = SparsePattern.fromPairs(n: m.nCells, owner: m.owner, neighbour: m.neighbour)
    let A = SparseMatrix(pattern: pat)
    var b = [Double](repeating: 0, count: m.nCells)
    for f in 0..<m.nInternalFaces {
        let P = Int(m.owner[f]), N = Int(m.neighbour[f])
        let S = m.faceAreas[f], d = m.cellCentres[N] - m.cellCentres[P]
        let c = dot(S, S) / dot(S, d)
        A.values[Int(pat.diag[P])] += c; A.values[Int(pat.diag[N])] += c
        A.values[Int(up[f])] -= c; A.values[Int(lo[f])] -= c
    }
    for z in m.boundaryZones where z.kind != .empty {
        for f in z.faceRange {
            let P = Int(m.owner[f])
            let S = m.faceAreas[f], d = m.faceCentres[f] - m.cellCentres[P]
            let c = dot(S, S) / dot(S, d)
            A.values[Int(pat.diag[P])] += c
            b[P] += c * boundary(m.faceCentres[f])
        }
    }
    for c in 0..<m.nCells { b[c] += source(m.cellCentres[c]) * m.cellVolumes[c] }
    return (A, b)
}

@Suite struct MeshTests {
    @Test func blockMesh2DGeometry() throws {
        let spec = BlockMeshSpec(x: BlockAxis(from: 0, to: 2, cells: 20), y: BlockAxis(from: 0, to: 1, cells: 10, grading: 4), depth: 0.1)
        let m = try spec.build()
        #expect(m.nCells == 200)
        #expect(m.isTwoDimensional && m.twoDimensionalAxis == 2)
        #expect(abs(m.totalVolume - 0.2) < 1e-12)
        #expect(Set(m.boundaryZones.map(\.name)) == ["x-min", "x-max", "y-min", "y-max", "frontAndBack"])
        // closed cells: sum of outward area vectors vanishes
        for c in 0..<m.nCells {
            var s = Vec3.zero
            for k in m.cellFaceRange(c) {
                let f = Int(m.cellFaces[k])
                s += Int(m.owner[f]) == c ? m.faceAreas[f] : -m.faceAreas[f]
            }
            #expect(norm(s) < 1e-12)
        }
        // orientation: owner -> neighbour
        for f in 0..<m.nInternalFaces {
            let d = m.cellCentres[Int(m.neighbour[f])] - m.cellCentres[Int(m.owner[f])]
            #expect(dot(d, m.faceAreas[f]) > 0)
            #expect(m.owner[f] < m.neighbour[f])
        }
        let q = MeshQuality.report(m)
        #expect(q.minOrthogonalQuality > 0.999)
    }

    @Test func gradingRatio() {
        let n = BlockAxis(from: 0, to: 1, cells: 10, grading: 9).nodes()
        let first = n[1] - n[0], last = n[10] - n[9]
        #expect(abs(last / first - 9) < 1e-9)
        #expect(abs(n[10] - 1) < 1e-15)
    }

    @Test func obstacleAndRules() throws {
        // backward-facing step: remove the lower-left block
        let spec = BlockMeshSpec(
            x: BlockAxis(start: -1, segments: [AxisSegment(end: 0, cells: 10), AxisSegment(end: 4, cells: 40)]),
            y: BlockAxis(start: 0, segments: [AxisSegment(end: 0.5, cells: 5), AxisSegment(end: 1, cells: 5)]),
            obstacles: [[-1, 0, -1, 0, 0.5, 1]],
            patches: [PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [-1, 0.5, -1], boxMax: [-1, 1, 2], normal: [-1, 0, 0]),
                      PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [4, 0, -1], boxMax: [4, 1, 2])])
        let m = try spec.build()
        #expect(m.nCells == 10 * 5 + 40 * 10)
        #expect(m.zone(named: "inlet")?.count == 5)
        #expect(m.zone(named: "outlet")?.count == 10)
        #expect(m.zone(named: "obstacle")?.count == 5 + 10) // step face + top of the step
    }

    @Test func cylinderOGrid() throws {
        let m = try CylinderOGridSpec(radius: 0.5, outerRadius: 10, radialCells: 20, circumferentialCells: 32).build()
        #expect(m.nCells == 640)
        #expect(m.zone(named: "cylinder")?.count == 32)
        let q = MeshQuality.report(m)
        #expect(q.negativeVolumes == 0)
        #expect(q.minOrthogonalQuality > 0.95)
    }

    @Test func binaryArchiveRoundTrip() throws {
        let m = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 4), y: BlockAxis(from: 0, to: 1, cells: 3),
                                  z: BlockAxis(from: 0, to: 1, cells: 2)).build()
        let d = try MeshIO.writeBinary(m)
        let r = try MeshIO.readBinary(d)
        #expect(r.nCells == m.nCells && r.nFaces == m.nFaces && r.points == m.points)
        #expect(r.boundaryZones == m.boundaryZones)
        #expect(abs(r.totalVolume - 1) < 1e-12)
    }
}

@Suite struct LinearTests {
    func poissonCase(_ n: Int) throws -> (Mesh, SparseMatrix, [Double]) {
        let m = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: n), y: BlockAxis(from: 0, to: 1, cells: n)).build()
        // u = x + 2y is reproduced exactly by the 2-point flux on orthogonal meshes
        let (A, b) = assemblePoisson(m, boundary: { $0.x + 2 * $0.y })
        return (m, A, b)
    }

    @Test(arguments: [LinearMethod.amgCG, .amgBiCGStab, .amg])
    func linearExactness(method: LinearMethod) throws {
        let (m, A, b) = try poissonCase(64)
        var x = [Double](repeating: 0, count: m.nCells)
        let s = LinearSolver(LinearSolverSettings(method: method, cycle: method == .amgCG ? .k : .v, relTol: 1e-10, maxIterations: 200))
        let st = s.solve(A, x: &x, b: b)
        #expect(st.converged)
        var err = 0.0
        for c in 0..<m.nCells { err = max(err, abs(x[c] - (m.cellCentres[c].x + 2 * m.cellCentres[c].y))) }
        #expect(err < 1e-7)
        print("\(method): \(st.iterations) iterations, levels \(s.amg.levelSizes)")
    }

    @Test func amgScalability() throws {
        // Iteration count should stay roughly flat as the mesh is refined.
        var its: [Int] = []
        for n in [32, 128, 256] {
            let (m, A, b) = try poissonCase(n)
            var x = [Double](repeating: 0, count: m.nCells)
            let s = LinearSolver(LinearSolverSettings(method: .amgCG, cycle: .k, relTol: 1e-8, maxIterations: 200))
            let st = s.solve(A, x: &x, b: b)
            its.append(st.iterations)
        }
        print("AMG-FCG K-cycle iterations for 32², 128², 256²: \(its)")
        #expect(its.last! < 40)
    }
}

/// Unit cube of n³ Kuhn-split hexes (6 tets each) as an element-level Gmsh mesh: wall at z = 0,
/// inlet x = 0, outlet x = 1, symmetry on the other three sides.
func tetCube(_ n: Int) -> GmshReader.Parsed {
    var pts: [Vec3] = []
    func id(_ i: Int, _ j: Int, _ k: Int) -> Int32 { Int32((k * (n + 1) + j) * (n + 1) + i) }
    for k in 0...n { for j in 0...n { for i in 0...n { pts.append(Vec3(Double(i), Double(j), Double(k)) / Double(n)) } } }
    var els: [GmshReader.Element] = []
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for k in 0..<n { for j in 0..<n { for i in 0..<n {
        for p in perms {
            var c = [i, j, k]
            var nodes = [id(c[0], c[1], c[2])]
            for a in p { c[a] += 1; nodes.append(id(c[0], c[1], c[2])) }
            els.append(GmshReader.Element(type: 4, nodes: nodes, physical: 1, dim: 3))
        }
    }}}
    var count: [GmshReader.FaceKey: ([Int32], Int)] = [:]
    for e in els { for f in GmshReader.cellFaces(base: 4, e.nodes) { count[GmshReader.FaceKey(f), default: (f, 0)].1 += 1; count[GmshReader.FaceKey(f)]!.0 = f } }
    for (_, v) in count where v.1 == 1 {
        let c = v.0.map { pts[Int($0)] }.reduce(Vec3.zero, +) / 3
        let tag = c.z < 1e-9 ? 1 : c.x < 1e-9 ? 2 : c.x > 1 - 1e-9 ? 3 : 4
        els.append(GmshReader.Element(type: 2, nodes: v.0, physical: tag, dim: 2))
    }
    return GmshReader.Parsed(points: pts, elements: els,
                             physicalNames: [2: [1: "wall", 2: "inlet", 3: "outlet", 4: "symmetry"], 3: [1: "fluid"]])
}

@Suite struct PrismInflationTests {
    @Test func layersConserveVolumeAndKeepFirstHeight() throws {
        let n = 8
        var parsed = tetCube(n)
        let before = try GmshReader.build(parsed)
        let s = InflationSettings(firstHeight: 0.004, growth: 1.2, layers: 5)
        let rep = try PrismInflation.inflate(&parsed, settings: s)
        let m = try GmshReader.build(parsed)
        #expect(rep.wallFaces == 2 * n * n)
        #expect(rep.prisms == 2 * n * n * 5)
        #expect(m.cellShapeHistogram()["wedges"] == rep.prisms)
        #expect(rep.coverage == 1)
        // no gaps or overlaps: the cube keeps its volume and every cell stays positive
        #expect(abs(m.cellVolumes.reduce(0, +) - 1) < 1e-10)
        #expect(m.cellVolumes.min()! > 0)
        // wall-adjacent cells are the first prism layer: centre at h1/2
        let wall = try #require(m.zone(named: "wall"))
        for f in wall.faceRange { #expect(abs(m.cellCentres[Int(m.owner[f])].z - 0.002) < 1e-9) }
        // the inlet gains one lateral quad per layer along each wall edge it shares
        let inletBefore = try #require(before.zone(named: "inlet")).count
        #expect(try #require(m.zone(named: "inlet")).count == inletBefore + n * 5)
        // nodes on the inlet stayed in the inlet plane
        for f in try #require(m.zone(named: "inlet")).faceRange { #expect(abs(m.faceCentres[f].x) < 1e-12) }
        #expect(m.boundaryZones.map(\.name).sorted() == before.boundaryZones.map(\.name).sorted())
    }

    @Test func oversizedStackIsThinnedNotInverted() throws {
        var parsed = tetCube(4)
        // asks for a 0.85-thick stack in a unit cube of 0.25 cells: must be thinned locally
        let s = InflationSettings(firstHeight: 0.02, growth: 1.3, layers: 10)
        let rep = try PrismInflation.inflate(&parsed, settings: s)
        let m = try GmshReader.build(parsed)
        #expect(rep.coverage == 0)
        #expect(rep.meanThickness < 0.5)
        #expect(m.cellVolumes.min()! > 0)
        #expect(abs(m.cellVolumes.reduce(0, +) - 1) < 1e-10)
        // the first layer keeps its height where the stack was thinned
        let wall = try #require(m.zone(named: "wall"))
        for f in wall.faceRange { #expect(abs(m.cellCentres[Int(m.owner[f])].z - 0.01) < 1e-6) }
    }

    @Test func thinStackKeepsFirstHeight() {
        let s = InflationSettings(firstHeight: 0.001, growth: 1.2, layers: 10)
        let f = s.fractions(thickness: 0.5 * s.targetThickness)
        #expect(abs(f[1] * 0.5 * s.targetThickness - 0.001) < 1e-9)
        #expect(f.first == 0 && abs(f.last! - 1) < 1e-12)
        let u = s.fractions(thickness: 0.005)            // thinner than 10 × h1: uniform layers
        #expect(abs(u[1] - 0.1) < 1e-12)
    }

    @Test func layerCountFromThickness() {
        #expect(InflationSettings.layers(firstHeight: 0.001, growth: 1.2, thickness: 0.001 * (pow(1.2, 8) - 1) / 0.2) == 8)
        let e = WallSpacing.estimate(yPlus: 1, velocity: 10, length: 1, density: 1.225, viscosity: 1.7894e-5)
        #expect(e.reynolds > 6.8e5 && e.reynolds < 6.9e5)
        #expect(e.firstHeight > 1e-5 && e.firstHeight < 1e-4)
    }
}
