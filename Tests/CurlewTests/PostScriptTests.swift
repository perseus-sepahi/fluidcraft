import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewSolver
@testable import CurlewFoam

/// The Python post-processing interface: export, the curlew_post module, reports, figures and
/// fields written back into the case.
@Suite(.serialized) struct PostScriptTests {
    static let hasFoam = !FoamDiscovery.discover().isEmpty
    static let python = PINNJob.defaultPython
    static let hasNumpy: Bool = {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        return PINNJob.runPython(python, ["-c", "import numpy, matplotlib"], timeout: 60).0 == 0
    }()

    @Test(.enabled(if: hasNumpy)) func npyFilesReadInNumPy() throws {
        let dir = URL(fileURLWithPath: "/tmp/curlew-npy-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try NPY.write(dir.appendingPathComponent("a.npy"), values: [1, 2, 3, 4, 5, 6], shape: [2, 3])
        try NPY.write(dir.appendingPathComponent("b.npy"), values: [7.5], shape: [1])
        let (st, out) = PINNJob.runPython(Self.python, ["-c", "import numpy as np, sys; a = np.load(sys.argv[1]); b = np.load(sys.argv[2]); print(a.shape, a[1, 2], b[0])",
                                                        dir.appendingPathComponent("a.npy").path, dir.appendingPathComponent("b.npy").path])
        #expect(st == 0 && out.contains("(2, 3) 6.0 7.5"), "\(out)")
    }

    @Test(.enabled(if: hasFoam && hasNumpy)) func templatesRunOnASolution() throws {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 0.4, cells: 40), y: BlockAxis(from: 0, to: 0.1, cells: 12), depth: 0.01, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.1, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.4, 0, -1], boxMax: [0.4, 0.1, 1]),
            PatchRule(name: "walls", kind: .wall, boxMin: [0, 0, -1], boxMax: [0.4, 0, 1]),
            PatchRule(name: "top", kind: .wall, boxMin: [0, 0.1, -1], boxMax: [0.4, 0.1, 1]),
        ]).build()
        var s = CaseSetup()
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(0.05)
        s.boundaries["inlet"] = inlet
        s.boundaries["outlet"] = BoundarySettings(type: .pressureOutlet)
        s.initialization.method = .standard; s.initialization.velocity = [.constant(0.05), 0, 0]
        s.run.iterations = 400
        s.general.backend = .openfoam
        s.openfoam.initialFields = .uniform; s.openfoam.checkMesh = false
        s.openfoam.caseDirectory = "/tmp/curlew-test-postscript"
        try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory)
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { _ in }, progress: { _, _, _, _ in })
        #expect(out.failure == nil, "\(out.failure ?? "")")
        let dir = URL(fileURLWithPath: s.openfoam.caseDirectory)
        let sol = try #require(out.solver)
        let rho = FoamCaseWriter.fluidMaterial(s)?.density ?? 1.225

        var results: [String: PostScriptResult] = [:]
        for (_, script) in PostScriptTemplates.all {
            let r = try PostScriptRun().run(script, caseDirectory: dir, setup: s, python: Self.python)
            if !r.succeeded { print("SCRIPT \(script.name) failed:\n" + r.log.suffix(20).joined(separator: "\n")) }
            #expect(r.succeeded, "\(script.name)")
            results[script.name] = r
        }
        // volume flow through the inlet: 0.05 m/s × 0.1 m × 0.01 m (into the domain = negative)
        let q = try #require(results["patch_summary"]?.reports.first { $0.name == "inlet volume flow" }?.value)
        #expect(abs(q + 5e-5) < 1e-7, "inlet flow \(q)")
        // the script's pressure drop matches Curlew's own reports of the loaded solution
        func pAvg(_ z: String) -> Double { var r = ReportDefinition(name: "p", kind: .areaWeightedAverage); r.zones = [z]; r.field = "pressure"; return Reports.evaluate(r, solver: sol) }
        let dp = try #require(results["pressure_drop"]?.reports.first { $0.name == "pressure drop" }?.value)
        let dpCurlew = pAvg("inlet") - pAvg("outlet")
        #expect(dp > 0 && abs(dp - dpCurlew) < 0.02 * abs(dpCurlew), "script \(dp) Pa vs Curlew \(dpCurlew) Pa (ρ = \(rho))")
        // a figure, and a field written back into the time directory that OpenFOAM's reader accepts
        #expect(results["line_plot"]?.figures.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(results["residuals"]?.figures.isEmpty == false)
        let t = try #require(results["total_pressure"]?.time)
        let f = try FoamFieldReader.read(url: dir.appendingPathComponent("\(t)/totalPressurePa"))
        #expect(f.className == "volScalarField" && f.internalField?.count == mesh.nCells)
        #expect(results["total_pressure"]?.fields == ["totalPressurePa"])
        // the next export includes the new field
        let (data, _) = try PostScriptExport.export(caseDirectory: dir, setup: s, to: dir.appendingPathComponent("curlew-post/data"))
        let manifest = try String(contentsOf: data.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("totalPressurePa"))

        // a failing script reports its error and exit code
        let bad = try PostScriptRun().run(FoamPostScript(name: "bad", code: "import curlew_post as cp\ncp.load()['nope']\n"), caseDirectory: dir, python: Self.python)
        #expect(!bad.succeeded && bad.log.joined().contains("no field 'nope'"))
        try? FileManager.default.removeItem(at: dir)
    }
}
