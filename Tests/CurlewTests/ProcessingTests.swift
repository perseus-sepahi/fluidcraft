import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewSolver
@testable import CurlewFoam

/// Pre-processing (setFields) and post-processing (function objects, line samples,
/// iso-surfaces, streamlines, VTK export) set up by Curlew and done by OpenFOAM.
@Suite struct ProcessingTests {
    static let hasFoam = !FoamDiscovery.discover().isEmpty

    func cavity() throws -> (Mesh, CaseSetup) {
        var (mesh, s) = try Benchmarks.cavityCase(re: 100, cells: 32)
        s.openfoam.initialFields = .uniform
        s.run.iterations = 600
        var post = FoamPostProcessing()
        post.functions = ["vorticity", "Q", "CourantNo"]
        var line = FoamLineSample(name: "centreline")
        let z = mesh.bounds.centre.z
        line.start = [0.5, 0, z]; line.end = [0.5, 1, z]; line.points = 50; line.fields = "U p"
        post.lineSamples = [line]
        var iso = FoamIsoSurface(name: "pmid"); iso.field = "p"; iso.value = -1.2     // inside this cavity's (kinematic) pressure range
        post.isoSurfaces = [iso]
        post.streamlineSeedStart = [0.1, 0.5, z]; post.streamlineSeedEnd = [0.9, 0.5, z]; post.streamlineSeeds = 10
        post.exportVTK = true
        s.openfoam.postProcessing = post
        return (mesh, s)
    }

    @Test func dictionariesAreWritten() throws {
        var (mesh, s) = try cavity()
        var r = FoamSetFieldsRegion(name: "blob")
        r.a = [0.4, 0.4, -1]; r.b = [0.6, 0.6, 1]; r.values = [FoamFieldValue(field: "U", vector: [0.5, 0, 0]), FoamFieldValue(field: "p", scalar: 1.225)]
        s.openfoam.preProcessing.setFieldsRegions = [r]
        let dir = URL(fileURLWithPath: "/tmp/curlew-pp-dict-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        let sf = try String(contentsOf: dir.appendingPathComponent("system/setFieldsDict"), encoding: .utf8)
        #expect(sf.contains("boxToCell") && sf.contains("volVectorFieldValue U (0.5 0 0)"))
        #expect(sf.contains("volScalarFieldValue p 1"))          // 1.225 Pa → kinematic 1 m²/s²
        let pp = try String(contentsOf: dir.appendingPathComponent("system/curlewPostProcess"), encoding: .utf8)
        #expect(pp.contains("type            vorticity;") && pp.contains("type            sets;") && pp.contains("isoSurface") && pp.contains("streamLine"))
        let allrun = try String(contentsOf: dir.appendingPathComponent("Allrun"), encoding: .utf8)
        #expect(allrun.contains("runApplication setFields") && allrun.contains("-postProcess -latestTime -dict system/curlewPostProcess") && allrun.contains("foamToVTK"))
        // names that are not OpenFOAM words are dropped, never written
        r.values = [FoamFieldValue(field: "U; #codeStream", vector: [1, 0, 0])]
        s.openfoam.preProcessing.setFieldsRegions = [r]
        _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir)
        #expect(!(try String(contentsOf: dir.appendingPathComponent("system/setFieldsDict"), encoding: .utf8)).contains("codeStream"))
    }

    @Test(.enabled(if: hasFoam)) func postProcessingRuns() throws {
        var (mesh, s) = try cavity()
        s.openfoam.caseDirectory = "/tmp/curlew-test-postprocess"
        try? FileManager.default.removeItem(atPath: s.openfoam.caseDirectory)
        var lines: [String] = []
        let out = try FoamSolve(mesh: mesh, setup: s).run(initial: nil, log: { lines.append($0) }, progress: { _, _, _, _ in })
        if out.failure != nil { print(lines.suffix(30).joined(separator: "\n")) }
        #expect(out.failure == nil, "\(out.failure ?? "")")
        let dir = URL(fileURLWithPath: s.openfoam.caseDirectory)
        let samples = try FoamPostResults.lineSamples(in: dir)
        let c = try #require(samples.first { $0.name == "centreline" })
        #expect(c.columns.contains("U_0") || c.columns.contains("U_x") || c.columns.contains { $0.hasPrefix("U") })
        #expect(c.rows.count == 50)
        // the sampled centreline velocity matches Curlew's own sample of the loaded solution
        let sol = try #require(out.solution)
        let ui = c.columns.firstIndex { $0 == "U_0" || $0 == "U_x" || $0 == "U:0" }!
        let mid = c.rows[25]
        let curlew = sol.sample("x-velocity", at: [Vec3(0.5, mid[0], mesh.bounds.centre.z)])[0]
        #expect(abs(mid[ui] - curlew) < 0.02, "OpenFOAM sample \(mid[ui]) vs Curlew \(curlew)")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("VTK").path))
        let latest = try #require(out.loadedTime)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(latest)/vorticity").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("postProcessing/isoSurfaces").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("postProcessing/sets/streamlines").path))
    }

    /// mapFields from a converged run and setFields in a box, before one iteration.
    @Test(.enabled(if: hasFoam)) func preProcessingRuns() throws {
        var (mesh, base) = try Benchmarks.cavityCase(re: 100, cells: 24)
        base.openfoam.initialFields = .uniform
        base.run.iterations = 400
        let srcDir = "/tmp/curlew-test-mapsource"
        var a = base; a.openfoam.caseDirectory = srcDir
        try? FileManager.default.removeItem(atPath: srcDir)
        let outA = try FoamSolve(mesh: mesh, setup: a).run(initial: nil, log: { _ in }, progress: { _, _, _, _ in })
        #expect(outA.failure == nil, "\(outA.failure ?? "")")
        var b = base
        b.openfoam.caseDirectory = "/tmp/curlew-test-mapped"
        try? FileManager.default.removeItem(atPath: b.openfoam.caseDirectory)
        b.run.iterations = 1
        b.openfoam.preProcessing.mapFieldsSource = srcDir
        var r = FoamSetFieldsRegion(name: "blob")
        r.a = [0.45, 0.45, -1]; r.b = [0.55, 0.55, 1]; r.values = [FoamFieldValue(field: "U", vector: [0.3, 0, 0])]
        b.openfoam.preProcessing.setFieldsRegions = [r]
        var lines: [String] = []
        let outB = try FoamSolve(mesh: mesh, setup: b).run(initial: nil, log: { lines.append($0) }, progress: { _, _, _, _ in })
        if outB.failure != nil { print(lines.suffix(20).joined(separator: "\n")) }
        #expect(outB.failure == nil, "\(outB.failure ?? "")")
        let dir = URL(fileURLWithPath: b.openfoam.caseDirectory)
        let mapLog = (try? String(contentsOf: dir.appendingPathComponent("log.mapFields"), encoding: .utf8)) ?? ""
        let setLog = (try? String(contentsOf: dir.appendingPathComponent("log.setFields"), encoding: .utf8)) ?? ""
        #expect(mapLog.contains("End") && setLog.contains("End"))
        // after one iteration the mapped solution is still the converged one away from the box
        let sa = try #require(outA.solution), sb = try #require(outB.solution)
        let probe = [Vec3(0.2, 0.8, mesh.bounds.centre.z)]
        #expect(abs(sa.sample("x-velocity", at: probe)[0] - sb.sample("x-velocity", at: probe)[0]) < 0.02)
        try? FileManager.default.removeItem(atPath: srcDir); try? FileManager.default.removeItem(at: dir)
    }
}
