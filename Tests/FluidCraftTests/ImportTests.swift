import Testing
import Foundation
@testable import FluidCraftMesh
@testable import FluidCraftSolver
@testable import FluidCraftFoam

/// Two quads side by side, hand-written in Fluent 2D ASCII format.
let twoQuadsFluent = """
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

/// An element-level Gmsh mesh as an ASCII v2.2 file.
func gmsh22(_ p: GmshReader.Parsed) -> String {
    var t = "$MeshFormat\n2.2 0 8\n$EndMeshFormat\n$PhysicalNames\n"
    let names = p.physicalNames.flatMap { d, m in m.map { (d, $0.key, $0.value) } }
    t += "\(names.count)\n" + names.map { "\($0.0) \($0.1) \"\($0.2)\"" }.joined(separator: "\n") + "\n$EndPhysicalNames\n"
    t += "$Nodes\n\(p.points.count)\n"
    for (i, x) in p.points.enumerated() { t += "\(i + 1) \(x.x) \(x.y) \(x.z)\n" }
    t += "$EndNodes\n$Elements\n\(p.elements.count)\n"
    for (i, e) in p.elements.enumerated() {
        t += "\(i + 1) \(e.type) 2 \(e.physical) \(e.physical) " + e.nodes.map { String($0 + 1) }.joined(separator: " ") + "\n"
    }
    return t + "$EndElements\n"
}

func scratchFile(_ name: String, _ text: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let u = d.appendingPathComponent(name)
    try text.write(to: u, atomically: true, encoding: .utf8)
    return u
}

@Suite struct MeshProbeTests {
    @Test func fluentHeader() {
        let i = MeshFileProbe.fluent(data: Data(twoQuadsFluent.utf8))
        #expect(i.dimension == 2 && !i.binary)
        #expect(i.zoneTypes["inlet"] == "velocity-inlet" && i.zoneTypes["fluid"] == "fluid")
        let b = MeshFileProbe.fluent(data: Data("(0 \"x (y)\")\n(2 3)\n(10 (0 1 8 0 3))\n(3010 (1 1 8 1 3)(".utf8))
        #expect(b.binary && b.dimension == 3)
    }

    @Test func gmshHeader() {
        let v4 = MeshFileProbe.gmsh(header: Data("$MeshFormat\n4.1 0 8\n$EndMeshFormat\n$Entities\n4 4 1 0\n".utf8))
        #expect(v4.version == 4.1 && !v4.binary && v4.volumes == 0)
        let bin = MeshFileProbe.gmsh(header: Data("$MeshFormat\n4.1 1 8\n".utf8))
        #expect(bin.binary)
        #expect(MeshFileProbe.gmsh(header: Data("$MeshFormat\n2.2 0 8\n$EndMeshFormat\n$Nodes\n".utf8)).volumes == nil)
    }
}

/// Fluent and Gmsh files are converted by OpenFOAM's fluentMeshToFoam and gmshToFoam.
@Suite(.enabled(if: hasOpenFOAM), .serialized) struct FoamImportTests {
    @Test func fluent3DWithZones() throws {
        let m = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 5), y: BlockAxis(from: 0, to: 0.5, cells: 4), z: BlockAxis(from: 0, to: 0.3, cells: 3),
                                  sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet],
                                  cellZones: [.init(name: "block", kind: .solid, box: [0.4, 0, 0, 0.6, 0.25, 0.3])]).build()
        let u = try scratchFile("box.msh", MeshWriters.fluentMesh(m))
        let r = try FoamMeshImport.read(url: u)
        #expect(r.converter == "fluentMeshToFoam")
        #expect(r.mesh.nCells == m.nCells && r.mesh.nFaces == m.nFaces)
        #expect(abs(r.mesh.totalVolume - m.totalVolume) < 1e-12)
        #expect(r.mesh.zone(named: "x-min")?.kind == .velocityInlet)
        #expect(r.mesh.zone(named: "x-max")?.kind == .pressureOutlet)
        let solid = try #require(r.mesh.cellZones.first { $0.name == "block" })
        #expect(solid.kind == .solid)
        #expect(r.mesh.cellZone.filter { r.mesh.cellZones[Int($0)].name == "block" }.count == m.cellZone.filter { m.cellZones[Int($0)].name == "block" }.count)
    }

    @Test func fluent2D() throws {
        let r = try FoamMeshImport.read(url: try scratchFile("two quads.msh", twoQuadsFluent), depth2D: 0.1)
        #expect(r.converter == "fluentMeshToFoam")
        #expect(r.mesh.nCells == 2 && r.mesh.isTwoDimensional)
        #expect(abs(r.mesh.totalVolume - 0.2) < 1e-12)
        #expect(r.mesh.zone(named: "inlet")?.kind == .velocityInlet)
        #expect(r.mesh.zone(named: "bottom")?.count == 2)
    }

    @Test func gmsh3D() throws {
        var p = tetCube(3)
        // Gmsh numbers physical groups across dimensions; tetCube reuses tag 1
        p.elements = p.elements.map { var e = $0; if e.dim == 3 { e.physical = 9 }; return e }
        p.physicalNames[3] = [9: "fluid"]
        let u = try scratchFile("-cube.msh", gmsh22(p))
        let r = try FoamMeshImport.read(url: u)
        #expect(r.converter == "gmshToFoam")
        #expect(r.mesh.nCells == 6 * 27)
        #expect(abs(r.mesh.totalVolume - 1) < 1e-12)
        #expect(r.mesh.zone(named: "wall")?.kind == .wall)
        #expect(r.mesh.zone(named: "inlet")?.kind == .velocityInlet)
        #expect(r.mesh.zone(named: "symmetry")?.kind == .symmetry)
        #expect(r.mesh.cellVolumes.min()! > 0)
    }

    @Test func sharedPhysicalTagsUseFluidCraftsReader() throws {
        let r = try FoamMeshImport.read(url: try scratchFile("shared.msh", gmsh22(tetCube(2))))
        #expect(r.converter.contains("physical tag"))
        #expect(r.mesh.zone(named: "wall")?.kind == .wall && r.mesh.cellZones.first?.name == "fluid")
    }

    @Test func gmsh2DUsesFluidCraftsReader() throws {
        var p = tetCube(1)
        // keep only the z = 0 triangles as a 2D mesh
        p.elements = p.elements.filter { $0.dim == 2 && $0.physical == 1 }.map { GmshReader.Element(type: 2, nodes: $0.nodes, physical: 5, dim: 2) }
        p.physicalNames = [2: [5: "fluid"]]
        let r = try FoamMeshImport.read(url: try scratchFile("flat.msh", gmsh22(p)), depth2D: 0.5)
        #expect(r.converter.hasPrefix("FluidCraft's Gmsh reader (2D"))
        #expect(r.mesh.isTwoDimensional && abs(r.mesh.totalVolume - 0.5) < 1e-12)
    }
}

@Suite struct ExternalToolTests {
    @Test func detectsInstalledTools() {
        for t in ExternalTool.allCases {
            let s = t.detect()
            print("\(t.name): \(s.found ? "found" : "missing") \(s.version ?? "-") \(s.location ?? "") \(s.detail ?? "")")
            if s.found {
                #expect(s.location != nil)
                // version probes must not come back empty while other tests run processes
                if t != .paraview { #expect(!(s.version ?? "").isEmpty, "\(t.name) version") }
            }
            #expect(!t.terminalCommand.isEmpty)
        }
        #expect(ExternalTool.openfoam.detect().found == hasOpenFOAM)
        #expect(ExternalTool.gmsh.detect().found == GmshDriver.isAvailable)
    }
}

/// The app was called Curlew until 25 November 2026: its cases, preferences and scripts keep working.
@Suite struct RenameCompatibilityTests {
    @Test func oldCaseFilesStillRead() throws {
        #expect(CasePackage.isCase(URL(fileURLWithPath: "/x/old.curlew")) && CasePackage.isCase(URL(fileURLWithPath: "/x/new.fluidcraft")))
        #expect(!CasePackage.isCase(URL(fileURLWithPath: "/x/mesh.msh")))
        // values that older case files store
        #expect(try JSONDecoder().decode(FoamInitialFields.self, from: Data(#""curlew""#.utf8)) == .fluidcraft)
        #expect(try JSONDecoder().decode(FoamTurbulenceModel.self, from: Data(#""fromCurlew""#.utf8)) == .fromFluidCraft)
        // the saved example case from before the rename loads
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Examples/CAD/manifold-result.fluidcraft").standardized
        let p = try CasePackage.read(pkg)
        #expect(p.setup.openfoam.initialFields == .fluidcraft && p.mesh.nCells > 0)
    }

    @Test func preferencesMoveOver() {
        let old = "test.fluidcraft.legacy.\(UUID().uuidString)", new = "test.fluidcraft.new.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: new)!
        d.setPersistentDomain(["curlew.python": "/opt/py", "curlew.ai.settings": Data([1, 2]), "NSWindow Frame x": "1 2 3 4"], forName: old)
        d.set("/kept", forKey: "fluidcraft.gmsh")
        LegacyPreferences.migrate(into: d, from: old)
        #expect(d.string(forKey: "fluidcraft.python") == "/opt/py")
        #expect(d.data(forKey: "fluidcraft.ai.settings") == Data([1, 2]))
        #expect(d.object(forKey: "NSWindow Frame x") == nil)
        #expect(d.string(forKey: "fluidcraft.gmsh") == "/kept")
        // only once: later changes in the old domain are not copied again
        d.setPersistentDomain(["curlew.python": "/other"], forName: old)
        LegacyPreferences.migrate(into: d, from: old)
        #expect(d.string(forKey: "fluidcraft.python") == "/opt/py")
        d.removePersistentDomain(forName: old); d.removePersistentDomain(forName: new)
    }
}
