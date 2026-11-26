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

/// Atmospheric boundary layer, actuator disks, radiation, orthotropic solids, several fluids
/// in one conjugate case, and the CAD samples / CAD analysis builder.
@Suite struct EngineeringTests {
    @Test func ablProfile() {
        var a = ABLProfile()
        a.referenceVelocity = 10; a.referenceHeight = 90; a.roughnessLength = 0.05
        #expect(abs(a.velocity(Vec3(0, 0, 90)).x - 10) < 1e-12)
        #expect(a.velocity(Vec3(0, 0, 0)).x.magnitude < 1e-12)
        let us = a.frictionVelocity
        #expect(abs(a.k(Vec3(0, 0, 30)) - us * us / sqrt(ABLProfile.cmu)) < 1e-12)
        // shear production = dissipation in the log layer: ε = u*³/(κ(z + z0))
        #expect(abs(a.epsilon(Vec3(0, 0, 30)) - us * us * us / (ABLProfile.kappa * 30.05)) < 1e-12)
    }

    @Test func windFarmTutorialCase() throws {
        let t = try #require(TutorialCatalog.all.first { $0.id == "wind-farm" })
        let (mesh, setup) = try t.build()
        let disks = setup.cellZones.filter { $0.value.actuatorDisk != nil }
        #expect(disks.count == 3)
        let dir = scratch("wf")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir)
        let opts = text(dir, "constant/fvOptions") + text(dir, "system/fvOptions")
        #expect(opts.components(separatedBy: "actuationDiskSource").count - 1 == 3)
        #expect(text(dir, "0/U").contains("atmBoundaryLayerInletVelocity"))
        #expect(text(dir, "0/nut").contains("atmNutkWallFunction"))
    }

    @Test(.enabled(if: hasOpenFOAM)) func actuatorDiskBecomesActuationDiskSource() throws {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 10, cells: 20), y: BlockAxis(from: 0, to: 2, cells: 4), depth: 2,
                                     cellZones: [.init(name: "disk", kind: .fluid, box: [4.5, -1, -1, 5.5, 3, 3])]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var d = ActuatorDisk(); d.diskArea = 4; d.thrustCoefficient = 0.75; d.powerCoefficient = 0.5
        d.upstreamPoint = [2, 1, 1]
        s.cellZones["disk"]!.actuatorDisk = d
        let dir = scratch("disk")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let fv = text(dir, "system/fvOptions") + text(dir, "constant/fvOptions")
        #expect(fv.contains("actuationDiskSource") && fv.contains("cellZone        disk"))
        #expect(fv.contains("diskArea        4") && fv.contains("Ct              0.75") && fv.contains("(2 1 1)"))
    }

    @Test func radiationCase() throws {
        var (mesh, setup, _) = try Benchmarks.naturalConvectionCase(log10Ra: 4, cells: 8)
        setup.openfoam.radiation.model = .fvDOM
        setup.openfoam.radiation.emissivity = 0.8
        #expect(FoamCaseWriter.resolvedApplication(setup) == .buoyantSimpleFoam)
        let dir = scratch("rad")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir)
        #expect(text(dir, "constant/radiationProperties").contains("fvDOM"))
        #expect(text(dir, "constant/boundaryRadiationProperties").contains("emissivity"))
        #expect(text(dir, "0/IDefault").contains("greyDiffusiveRadiation"))
        #expect(text(dir, "system/fvSchemes").contains("div(Ji,Ii_h)"))
        setup.openfoam.radiation.model = .P1
        setup.openfoam.radiation.absorption = 0.5
        let dir2 = scratch("p1")
        defer { try? FileManager.default.removeItem(at: dir2) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir2)
        #expect(text(dir2, "0/G").contains("MarshakRadiation"))
        #expect(text(dir2, "system/fvSolution").contains("G\n") || text(dir2, "system/fvSolution").contains("    G"))
    }

    /// Two solid slabs in series; the left is orthotropic. Only k along x matters for this
    /// 1-D conduction, so the exact profile (interface 320 K) must not change.
    func slabs(leftK: [Double]) throws -> (Mesh, CaseSetup) {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 20), y: BlockAxis(from: 0, to: 0.1, cells: 1), depth: 0.1,
                                     cellZones: [.init(name: "right", kind: .solid, box: [0.5, -1, -1, 1, 1, 1])]).build()
        mesh.updateCellZone(0, kind: .solid)
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        var a = material("lam", k: 1); a.kind = .solid; a.anisotropicConductivity = leftK
        var b = material("k4", k: 4); b.kind = .solid
        s.materials += [a, b]
        s.adopt(mesh: mesh)
        s.cellZones["fluid"]!.kind = .solid; s.cellZones["fluid"]!.material = "lam"
        s.cellZones["right"]!.material = "k4"
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = 400
        var cold = BoundarySettings(type: .wall); cold.thermalCondition = .temperature; cold.temperature = 300
        s.boundaries["x-min"] = hot; s.boundaries["x-max"] = cold
        s.initialization.method = .standard; s.initialization.temperature = 350
        s.run.iterations = 300
        return (mesh, s)
    }

    @Test(.enabled(if: hasOpenFOAM)) func orthotropicSolidInOpenFOAM() throws {
        var (mesh, s) = try slabs(leftK: [1, 50, 50])
        let dir = scratch("aniso")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let tp = text(dir, "constant/fluid/thermophysicalProperties")
        #expect(tp.contains("constAnIso") && tp.contains("kappa"))
        #expect(text(dir, "constant/right/thermophysicalProperties").contains("constIso"))
        // coupled walls of the orthotropic region use the normal conductivity n·K·n
        #expect(text(dir, "0/fluid/T").contains("directionalSolidThermo") && text(dir, "0/fluid/T").contains("alphaAni"))
        #expect(!text(dir, "0/right/T").contains("directionalSolidThermo"))
        guard !FoamDiscovery.discover().isEmpty else { return }
        s.openfoam.caseDirectory = scratch("aniso-run").path
        s.openfoam.initialFields = .uniform
        s.openfoam.residualEnergy = 1e-10
        s.run.iterations = 400
        defer { try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory) }
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { _ in }, progress: { _, _, _, _ in })
        #expect(out.failure == nil, "\(out.failure ?? "")")
        let sol = try #require(out.solution)
        var maxErr = 0.0
        for c in 0..<mesh.nCells {
            let x = mesh.cellCentres[c].x
            maxErr = max(maxErr, abs(sol.state.T[c] - (x < 0.5 ? 400 - 160 * x : 320 - 40 * (x - 0.5))))
        }
        #expect(maxErr < 0.05, "OpenFOAM max |T - exact| = \(maxErr)")
    }

    @Test func twoFluidsOneSolid() throws {
        // air | aluminium wall | water: each fluid material becomes its own region
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 3, cells: 30), y: BlockAxis(from: 0, to: 1, cells: 2), depth: 0.1,
                                     cellZones: [.init(name: "wall", kind: .solid, box: [1, -1, -1, 2, 2, 2]),
                                                 .init(name: "water", kind: .fluid, box: [2, -1, -1, 3, 2, 2])]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        s.materials += [MaterialLibrary.lookup("water-liquid")!, MaterialLibrary.lookup("aluminum")!]
        s.adopt(mesh: mesh)
        s.cellZones["wall"]!.material = "aluminum"
        s.cellZones["water"]!.material = "water-liquid"
        let (_, fluids, solids) = try FoamCHTWriter.regionNames(mesh, s)
        #expect(Set(fluids) == Set(["air", "water_liquid"]) && solids == ["wall"], "\(fluids) \(solids)")
        let dir = scratch("2f")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let rp = text(dir, "constant/regionProperties")
        #expect(rp.contains("air") && rp.contains("water_liquid") && rp.contains("wall"))
        #expect(text(dir, "constant/water_liquid/thermophysicalProperties").contains("998.2"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path))
    }

    @Test func limitedScalarGradientsOnTets() throws {
        // a tetrahedral box: Green-Gauss gradients and a limited enthalpy gradient
        let p = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 1)]
        let tets: [[Int]] = [[0, 1, 3, 4], [1, 2, 3, 6], [1, 4, 5, 6], [3, 4, 6, 7], [1, 3, 4, 6]]
        var b = MeshBuilder()
        b.points = p
        b.nCells = tets.count
        let walls = b.addZone("walls", kind: .wall)
        var owner: [[Int]: (cell: Int, nodes: [Int32])] = [:]
        for (ci, t) in tets.enumerated() {
            for skip in 0..<4 {
                var f = t.enumerated().filter { $0.offset != skip }.map(\.element)
                let n = cross(p[f[1]] - p[f[0]], p[f[2]] - p[f[0]])
                if dot(n, p[t[skip]] - p[f[0]]) > 0 { f.swapAt(1, 2) }   // outward from this cell
                let key = f.sorted()
                if let o = owner.removeValue(forKey: key) { b.addFace(o.nodes, c0: Int32(o.cell), c1: Int32(ci)) }
                else { owner[key] = (ci, f.map { Int32($0) }) }
            }
        }
        for o in owner.values { b.addFace(o.nodes, c0: Int32(o.cell), c1: -1, zone: walls) }
        let mesh = try b.build()
        #expect((mesh.cellShapeHistogram()["tetrahedra"] ?? 0) == 5)
        var s = CaseSetup()
        s.models.viscous = .laminar; s.models.energy = true
        s.methods.energy = .secondOrderUpwind
        s.general.gravityEnabled = true; s.general.gravity = [0, 0, -9.81]
        var gas = Material(name: "air-iig"); gas.densityMethod = .incompressibleIdealGas
        s.materials.append(gas)
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air-iig" }
        let dir = scratch("grad")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let sch = text(dir, "system/fvSchemes")
        #expect(sch.contains("default         Gauss linear;") && !sch.contains("leastSquares"))
        #expect(sch.contains("grad(h)") && sch.contains("cellLimited Gauss linear 1"))
    }

    @Test func engineeringTutorialsBuild() throws {
        for id in ["chip-air", "chip-liquid"] {
            let t = try #require(TutorialCatalog.all.first { $0.id == id })
            let (mesh, setup) = try t.build()
            #expect(mesh.cellZones.contains { $0.kind == .solid })
            #expect(setup.models.energy)
            #expect(setup.cellZones.values.contains { ($0.energySource.constantValue ?? 0) > 0 })
            for z in setup.cellZones.values { #expect(setup.material(named: z.material) != nil, "\(id): \(z.material)") }
        }
    }

    @Test func facePyramidCheck() throws {
        let (mesh, _) = try Benchmarks.cavityCase(re: 100, cells: 6)
        #expect(MeshQuality.report(mesh).invertedFacePyramids == 0)
        // push the interior node pair at (0.5, 0.5) through the next column of cells: they fold
        var pts = mesh.points
        for i in pts.indices where abs(pts[i].x - 0.5) < 1e-9 && abs(pts[i].y - 0.5) < 1e-9 { pts[i].x = 0.9 }
        var b = MeshBuilder()
        b.points = pts; b.nCells = mesh.nCells; b.renumber = false
        for z in mesh.boundaryZones { _ = b.addZone(z.name, kind: z.kind) }
        for f in 0..<mesh.nFaces {
            let nodes = mesh.faceNodeRange(f).map { mesh.faceNodes[$0] }
            let isB = f >= mesh.nInternalFaces
            b.addFace(nodes, c0: mesh.owner[f], c1: isB ? -1 : mesh.neighbour[f], zone: isB ? Int32(mesh.zoneIndex(ofFace: f) ?? 0) : -1)
        }
        let folded = try b.build()
        let q = MeshQuality.report(folded)
        #expect(q.invertedFacePyramids > 0)
    }

    @Test func cadSampleScripts() {
        for s in CADSample.allCases {
            let g = s.script(saving: "/tmp/x.step")
            #expect(g.contains("SetFactory(\"OpenCASCADE\")") && g.hasSuffix("Save \"/tmp/x.step\";\n"))
        }
        // the blade is lofted from six aerofoil sections
        #expect(CADSample.turbineBlade.script(saving: "b.step").components(separatedBy: "Wire(").count - 1 == 6)
    }

    @Test(.enabled(if: GmshDriver.isAvailable)) func cadAnalysisExternal() throws {
        let dir = scratch("cada")
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = try CADSample.sphere.export(to: dir)
        var spec = CADAnalysisSpec.sample(.sphere, path: step.path)
        spec.level = .coarse
        let r = try CADAnalysis.build(spec, workDir: dir.appendingPathComponent("work"), log: { _ in })
        let names = Set(r.mesh.boundaryZones.map(\.name))
        #expect(names.contains("inlet") && names.contains("outlet"))
        #expect(r.setup.boundaries["inlet"]?.type == .velocityInlet)
        #expect(r.setup.reports.contains { $0.kind == .dragCoefficient || $0.name.contains("drag") })
        #expect(abs(r.mesh.totalVolume) > 0)
        #expect(abs(r.setup.reference.area - .pi / 4) < 0.03)          // frontal area of the D = 1 sphere
        // a wing: planform area (chord 0.25 × span 1) and lift across its thickness (y)
        let wing = try CADSample.nacaWing.export(to: dir)
        var ws = CADAnalysisSpec.sample(.nacaWing, path: wing.path)
        ws.level = .coarse; ws.prismLayers = false
        let w = try CADAnalysis.build(ws, workDir: dir.appendingPathComponent("wing"), log: { _ in })
        #expect(abs(w.setup.reference.area - 0.25) < 0.01)
        #expect(w.setup.reports.first { $0.kind == .liftCoefficient }?.direction == [0, 1, 0])
    }
}
