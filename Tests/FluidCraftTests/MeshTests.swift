import Testing
import Foundation
@testable import FluidCraftMesh
@testable import FluidCraftFoam

/// Block and O-grid meshes come from OpenFOAM's blockMesh; these check that the generated
/// blockMeshDict reproduces the spec (grading, obstacles, patch rules, zones) exactly.
@Suite(.enabled(if: hasOpenFOAM)) struct MeshTests {
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

    @Test(.enabled(if: true)) func gradingRatio() {
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
        #expect(m.zone(named: "inlet")?.kind == .velocityInlet && m.zone(named: "obstacle")?.kind == .wall)
        // spacing reproduced: the graded segments meet where the spec puts them
        #expect(abs(m.totalVolume - (1 * 0.5 + 4 * 1)) < 1e-9)
    }

    @Test func gradedSegmentsAndZones() throws {
        let spec = BlockMeshSpec(
            x: BlockAxis(start: 0, segments: [AxisSegment(end: 1, cells: 12, grading: 5), AxisSegment(end: 2, cells: 8, grading: 0.25)]),
            y: BlockAxis(from: 0, to: 1, cells: 10, grading: 3), z: BlockAxis(from: 0, to: 0.5, cells: 4),
            cellZones: [.init(name: "porous", kind: .fluid, box: [0.5, 0.2, -1, 1.5, 0.8, 1]),
                        .init(name: "chip", kind: .solid, box: [1.6, 0, -1, 2, 0.3, 1])])
        let m = try spec.build()
        #expect(m.nCells == 20 * 10 * 4)
        // every cell centre of the generated mesh is one of the spec's cell centres
        let xs = spec.x.nodes(), ys = spec.y.nodes()
        let cx = (0..<20).map { 0.5 * (xs[$0] + xs[$0 + 1]) }, cy = (0..<10).map { 0.5 * (ys[$0] + ys[$0 + 1]) }
        var worst = 0.0
        for c in 0..<m.nCells {
            worst = max(worst, cx.map { abs($0 - m.cellCentres[c].x) }.min()!, cy.map { abs($0 - m.cellCentres[c].y) }.min()!)
        }
        #expect(worst < 1e-8, "max centre offset \(worst)")
        let porous = try #require(m.cellZones.first { $0.name == "porous" })
        let chip = try #require(m.cellZones.first { $0.name == "chip" })
        #expect(chip.kind == .solid)
        for c in 0..<m.nCells {
            let x = m.cellCentres[c], z = m.cellZones[Int(m.cellZone[c])].name
            let inPorous = x.x > 0.5 && x.x < 1.5 && x.y > 0.2 && x.y < 0.8
            let inChip = x.x > 1.6 && x.y < 0.3
            #expect(z == (inChip ? "chip" : (inPorous ? "porous" : "fluid")))
        }
        #expect(porous.cellCount > 0)
    }

    @Test func cylinderOGrid() throws {
        let m = try CylinderOGridSpec(radius: 0.5, outerRadius: 10, radialCells: 20, circumferentialCells: 32).build()
        #expect(m.nCells == 640)
        #expect(m.zone(named: "cylinder")?.count == 32)
        let q = MeshQuality.report(m)
        #expect(q.negativeVolumes == 0)
        #expect(q.minOrthogonalQuality > 0.95)
        // the cells fill the annulus (blockMesh arcs): polygon area → π (R² − r²) as cells refine
        let area = m.totalVolume / 1.0
        #expect(abs(area - Double.pi * (100 - 0.25)) / (Double.pi * 99.75) < 0.01)
        #expect(m.zone(named: "inlet")!.count + m.zone(named: "outlet")!.count == 32)
        let nI = m.nInternalFaces
        for f in m.zone(named: "inlet")!.faceRange { #expect(m.faceCentres[f].x < 0) }
        _ = nI
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

/// Prism layers are snappyHexMesh's layer addition on the Gmsh tetrahedra.
@Suite(.enabled(if: hasOpenFOAM), .serialized) struct PrismLayerTests {
    @Test func snappyAddsLayersOnTheWall() throws {
        let tets = try GmshReader.build(tetCube(8))
        let s = InflationSettings(firstHeight: 0.004, growth: 1.2, layers: 4)
        let r = try FoamLayers.add(to: tets, settings: s)
        let m = r.mesh
        #expect(m.nCells > tets.nCells)
        #expect(m.cellShapeHistogram()["wedges", default: 0] > 0)
        // no gaps or overlaps: the cube keeps its volume (to snappyHexMesh's point sliding on the
        // side patches, ~4e-6) and every cell stays positive
        #expect(abs(m.totalVolume - 1) < 1e-5, "volume \(m.totalVolume)")
        #expect(m.cellVolumes.min()! > 0)
        // zones keep their names and kinds
        #expect(Set(m.boundaryZones.map(\.name)) == Set(tets.boundaryZones.map(\.name)))
        #expect(m.zone(named: "wall")?.kind == .wall && m.zone(named: "inlet")?.kind == tets.zone(named: "inlet")?.kind)
        // where layers were added, the wall-adjacent cell is the first layer (centre at h1/2)
        let wall = try #require(m.zone(named: "wall"))
        let thin = wall.faceRange.filter { abs(m.cellCentres[Int(m.owner[$0])].z - 0.002) < 2e-4 }.count
        #expect(Double(thin) / Double(wall.count) > 0.5, "\(r.summary)")
        #expect(r.summary.contains("layers"))
    }

    @Test func layerCountFromThickness() {
        #expect(InflationSettings.layers(firstHeight: 0.001, growth: 1.2, thickness: 0.001 * (pow(1.2, 8) - 1) / 0.2) == 8)
        let e = WallSpacing.estimate(yPlus: 1, velocity: 10, length: 1, density: 1.225, viscosity: 1.7894e-5)
        #expect(e.reynolds > 6.8e5 && e.reynolds < 6.9e5)
        #expect(e.firstHeight > 1e-5 && e.firstHeight < 1e-4)
    }
}
