import Foundation
import CurlewMesh
import CurlewSolver
import CurlewPost
import CurlewFoam

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard let cmd = args.first else {
    print("""
    curlew-cli — Curlew batch interface (OpenFOAM solves; Gmsh and OpenFOAM mesh)

      run <case.json> --mesh <file> | <case.curlew> | --tutorial <id>   solve with OpenFOAM
                [--dir d] [--cores n] [--iterations N] [--app simpleFoam] [--turbulence kOmegaSST]
                [--continue] [--write-only] [--save out.curlew] [--vtu out.vtu]
                [--bl-first h --bl-growth g --bl-layers n --bl-zones a,b]   prism layers (snappyHexMesh) on a 3D mesh
      tutorial <id> [run options]                same as run --tutorial <id>
      validate <\(ValidationSuite.Case.allCases.map(\.cliName).joined(separator: "|"))|pipe|all> [--cores n]
      mesh-info <mesh file> [--bl-first h …]
      mesh-cad <file.step|stl|obj|ply|off|3mf> [--internal] [--axis 0|1|2] [--unit mm] [--max-size h] [--wall-size h] [--solve]
      mesh-pipe [--length L] [--diameter D] [--max-size h] [--wall-size h] [--bl-first h --bl-layers n] [--foam dir]
      foam detect | foam run … | foam mesh <cad file>   OpenFOAM installations and snappyHexMesh (see: foam)
      cad-analysis <file | sample:NAME> [options]
      export <case.curlew> [--foam dir] [--fluent-mesh out.msh]
      post-script --case <OpenFOAM case> --script <file.py> [--time t]   Python post-processing (curlew_post)
      post-script <case.curlew> [--name script] [--trust-case-content]   run the scripts saved in a case
      pinn <tutorial id | case.curlew> [options]

    Tutorials: \(TutorialCatalog.all.map(\.id).joined(separator: ", "))
    """)
    exit(0)
}

/// Write an OpenFOAM case for a Curlew setup (steady runs get `iterations` iterations).
func exportFoam(_ mesh: Mesh, _ setup: CaseSetup, _ dir: String, iterations: Int?) throws {
    var s = setup
    if let it = iterations { s.run.iterations = it }
    let r = try FoamCaseWriter.write(mesh: mesh, setup: s, to: URL(fileURLWithPath: dir))
    for w in r.warnings { print("warning: \(w)") }
    print("OpenFOAM application: \(r.application.rawValue), turbulence: \(r.turbulence.rawValue)")
}

/// A case file can carry custom OpenFOAM content (stages, raw dictionary text, extra files) that
/// can run programs. As the app asks first, the CLI refuses to run it without --trust-case-content.
func requireTrustedContent(_ s: CaseSetup) {
    guard !s.openfoam.activeContent.isEmpty, !args.contains("--trust-case-content") else { return }
    print("This case adds custom OpenFOAM content to the run:\n")
    print(s.openfoam.activeContentFullText)
    fail("\nNot run. Review the content above; if you trust where the case came from, run again with --trust-case-content.")
}

func option(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}

/// `--bl-first h --bl-growth g --bl-layers n` (or `--bl-thickness T`) → prism layers on 3D meshes.
func applyBoundaryLayerOptions(_ ms: inout MeshingSettings) {
    ms.blFirstHeight = Double(option("--bl-first", "0")) ?? 0
    ms.blGrowth = Double(option("--bl-growth", "1.2")) ?? 1.2
    ms.blLayers = Int(option("--bl-layers", "0")) ?? 0
    ms.blThickness = Double(option("--bl-thickness", "0")) ?? 0
}

/// Read a mesh file; a 3D Gmsh mesh gets prism layers when `--bl-first` is given
/// (`--bl-growth`, `--bl-layers`, `--bl-zones a,b` = walls to inflate, default all walls).
func readMesh(_ path: String) throws -> Mesh {
    let mesh = try MeshIO.read(url: URL(fileURLWithPath: path))
    let h1 = Double(option("--bl-first", "0")) ?? 0
    guard h1 > 0 else { return mesh }
    guard !mesh.isTwoDimensional else { fail("--bl-first adds prism layers to 3D meshes") }
    let g = Double(option("--bl-growth", "1.2")) ?? 1.2
    var n = Int(option("--bl-layers", "0")) ?? 0
    if n == 0 { n = InflationSettings.layers(firstHeight: h1, growth: g, thickness: Double(option("--bl-thickness", "0")) ?? 0) }
    let zones = option("--bl-zones", "").split(separator: ",").map(String.init)
    let r = try FoamLayers.add(to: mesh, settings: InflationSettings(firstHeight: h1, growth: g, layers: n, zones: zones), log: { print($0) })
    print(r.summary)
    return r.mesh
}

/// Print a generated mesh and optionally write it out (`--foam dir` for OpenFOAM checkMesh, `--fluent-mesh file`).
func describeGenerated(_ r: GmshDriver.Result, seconds: Double) throws {
    print("Gmsh mesh in \(String(format: "%.1f", seconds)) s: \(r.mesh.summary)")
    print("  shapes \(r.mesh.cellShapeHistogram())")
    if let l = r.layers { print("  \(l)") }
    for z in r.mesh.boundaryZones { print("  zone \(z.name) [\(z.kind.rawValue)] \(z.count) faces") }
    print(MeshQuality.report(r.mesh).text)
    let foam = option("--foam", "")
    if !foam.isEmpty {
        var s = CaseSetup(); s.adopt(mesh: r.mesh)
        try exportFoam(r.mesh, s, foam, iterations: 2000); print("Wrote OpenFOAM case \(foam)")
    }
    let fl = option("--fluent-mesh", "")
    if !fl.isEmpty { try MeshWriters.fluentMesh(r.mesh).write(toFile: fl, atomically: true, encoding: .utf8); print("Wrote \(fl)") }
}

switch cmd {
case "validate":
    // validate <case|pipe|all> [--cores n]: solve the benchmark with OpenFOAM and compare
    guard args.count > 1 else { fail("validate <\(ValidationSuite.Case.allCases.map(\.cliName).joined(separator: "|"))|pipe|all> [--cores n]") }
    let cores = Int(option("--cores", "1")) ?? 1
    if args[1] == "pipe" {
        try validatePipe(cores: cores)
        break
    }
    let cases = args[1] == "all" ? ValidationSuite.Case.allCases : ValidationSuite.Case.allCases.filter { $0.cliName == args[1] }
    guard !cases.isEmpty else { fail("unknown benchmark \(args[1])") }
    var failed = false
    for c in cases {
        print("== \(c.rawValue)")
        let t0 = Date()
        let rows = try ValidationSuite.run(c, cores: cores) { print($0) }
        for r in rows {
            print(String(format: "  %@ %@: %@ (reference %@)", r.passed ? "PASS" : "FAIL", r.quantity as NSString, r.computed as NSString, r.reference as NSString))
            if !r.passed { failed = true }
        }
        print(String(format: "  %.1f s", Date().timeIntervalSince(t0)))
    }
    if failed { exit(2) }
case "tutorial":
    guard args.count > 1 else { fail("tutorials: " + TutorialCatalog.all.map(\.id).joined(separator: ", ")) }
    try foamRun(caseIndex: nil, tutorial: args[1])
case "mesh-cad":
    guard args.count > 1 else { fail("mesh-cad <file.step> [--internal] [--axis 0] [--max-size 0.2] [--wall-size 0.05]") }
    var ms = MeshingSettings(template: .cad(path: args[1], external: !args.contains("--internal"), flowAxis: Int(option("--axis", "0"))!, padding: [3, 8, 3, 3, 3, 3]))
    ms.maxSize = Double(option("--max-size", "0.4"))!
    ms.wallSize = Double(option("--wall-size", "0.05"))!
    ms.growthDistance = Double(option("--growth", "1.5"))!
    ms.cadUnit = CADUnit(rawValue: option("--unit", "m")) ?? .metre
    ms.cadConverter = option("--converter", "")
    applyBoundaryLayerOptions(&ms)
    let t0 = Date()
    let r = try FoamGmsh.generate(ms)
    try describeGenerated(r, seconds: Date().timeIntervalSince(t0))
    if args.contains("--solve") {
        // laminar flow at Re = 100 on a unit-diameter body, solved with OpenFOAM
        var s = CaseSetup()
        s.title = URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent + "-re100"
        s.models.viscous = .laminar
        var f = Material(name: "f"); f.density = 1; f.viscosity = 0.01
        s.materials.append(f); s.adopt(mesh: r.mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 1
        s.boundaries["inlet"] = inlet
        s.boundaries["farfield"] = BoundarySettings(type: .symmetry)
        s.methods.coupling = .simplec
        s.reference.velocity = 1; s.reference.density = 1; s.reference.area = Double.pi * 0.25
        var cd = ReportDefinition(name: "cd", kind: .dragCoefficient); cd.zones = ["body"]
        s.reports = [cd]
        s.run.iterations = Int(option("--iterations", "1500"))!
        let foamDir = option("--export-foam", "")
        if !foamDir.isEmpty { try exportFoam(r.mesh, s, foamDir, iterations: nil); print("OpenFOAM case written to \(foamDir)") }
        let sol = try ValidationSuite.solve(r.mesh, s, cores: Int(option("--cores", "1")) ?? 1, log: { if $0.hasPrefix("iter ") { print($0) } })
        print(String(format: "Cd = %.4f (unconfined sphere at Re = 100: 1.087)", Reports.evaluate(s.reports[0], solver: sol)))
    }
case "mesh-pipe":
    var ms = MeshingSettings(template: .pipe(length: Double(option("--length", "0.5"))!, diameter: Double(option("--diameter", "0.05"))!))
    ms.maxSize = Double(option("--max-size", "0.006"))!
    ms.wallSize = Double(option("--wall-size", "0.003"))!
    ms.growthDistance = Double(option("--growth", "0.02"))!
    applyBoundaryLayerOptions(&ms)
    let t0 = Date()
    try describeGenerated(try FoamGmsh.generate(ms), seconds: Date().timeIntervalSince(t0))
case "run":
    try foamRun(caseIndex: 1, tutorial: args.firstIndex(of: "--tutorial").map { args[$0 + 1] })
case "cad-analysis":
    // cad-analysis <file | sample:NAME> [--type external|internal|conjugate] [--axis 0] [--speed U] [--fluid air]
    //   [--solid aluminum] [--heat W] [--unit mm] [--mesher gmsh|snappy] [--level coarse|medium|fine] [--no-layers]
    //   [--run] [--cores n] [--iterations N] [--save out.curlew]
    guard args.count > 1 else { fail("cad-analysis <file | sample:\(CADSample.allCases.map(\.rawValue).joined(separator: "|"))> [options]") }
    var spec: CADAnalysisSpec
    if args[1].hasPrefix("sample:") {
        guard let sm = CADSample(rawValue: String(args[1].dropFirst(7))) else { fail("samples: " + CADSample.allCases.map(\.rawValue).joined(separator: ", ")) }
        spec = CADAnalysisSpec.sample(sm, path: try sm.export(to: CADSample.directory).path)
    } else {
        spec = CADAnalysisSpec(); spec.path = args[1]
    }
    switch option("--type", "") {
    case "external": spec.kind = .externalAerodynamics
    case "internal": spec.kind = .internalFlow
    case "conjugate", "heatsink": spec.kind = .conjugateHeatSink
    default: break
    }
    if let v = Int(option("--axis", "")) { spec.flowAxis = v }
    if let v = Double(option("--speed", "")) { spec.speed = v }
    if !option("--fluid", "").isEmpty { spec.fluid = option("--fluid", "") }
    if !option("--solid", "").isEmpty { spec.solid = option("--solid", "") }
    if let v = Double(option("--heat", "")) { spec.heatLoad = v }
    if let u = CADUnit(rawValue: option("--unit", "")) { spec.unit = u; spec.unitFromFile = false }
    // region of interest: --margins up,down,side,below,above (body lengths), --on-ground, --moving-ground,
    // --refine x0,y0,z0:x1,y1,z1 (metres) [--refine-size h]
    let mg = option("--margins", "").split(separator: ",").compactMap { Double($0) }
    if mg.count == 5 { spec.domainMargins = mg }
    if args.contains("--on-ground") { spec.onGround = true }
    if args.contains("--moving-ground") { spec.onGround = true; spec.movingGround = true }
    let rf = option("--refine", "").split(separator: ":").map { $0.split(separator: ",").compactMap { Double($0) } }
    if rf.count == 2, rf[0].count == 3, rf[1].count == 3 { spec.refinementBox = rf[0] + rf[1] }
    if let h = Double(option("--refine-size", "")) { spec.refinementSize = h }
    if option("--mesher", "") == "snappy" { spec.mesher = .snappyHexMesh }
    if let l = CADAnalysisSpec.Level(rawValue: option("--level", "")) { spec.level = l }
    if args.contains("--no-layers") { spec.prismLayers = false }
    spec.cores = Int(option("--cores", "1")) ?? 1
    spec.converter = option("--converter", "")
    let work = FoamLocations.defaultCaseDirectory(title: "cad-" + URL(fileURLWithPath: spec.path).deletingPathExtension().lastPathComponent)
    let env = spec.mesher == .snappyHexMesh ? try FoamLocations.installation(for: CaseSetup()).resolve() : nil
    let t0 = Date()
    let built = try CADAnalysis.build(spec, workDir: work.appendingPathComponent("mesh"), environment: env, log: { print($0, terminator: "") })
    print(built.summary + String(format: " (%.1f s)", Date().timeIntervalSince(t0)))
    let mq = MeshQuality.report(built.mesh)
    print(String(format: "  quality: max non-orthogonality %.1f°, min orthogonal quality %.3f, max skewness-free aspect %.3g", mq.maxNonOrthogonality, mq.minOrthogonalQuality, mq.maxAspectRatio))
    for z in built.mesh.boundaryZones { print("  \(z.name) [\(built.setup.boundaries[z.name]?.type.rawValue ?? z.kind.rawValue)] \(z.count) faces") }
    for z in built.mesh.cellZones { print("  cell zone \(z.name) [\(built.setup.cellZones[z.name]?.kind.rawValue ?? "")] \(z.cellCount) cells") }
    var setup = built.setup
    var mesh = built.mesh
    if let n = Int(option("--iterations", "")) { setup.run.iterations = n }
    // --wall a,b: retype detected openings as walls (e.g. close a manifold's far end)
    for name in option("--wall", "").split(separator: ",").map(String.init) where !name.isEmpty {
        guard let i = mesh.boundaryZones.firstIndex(where: { $0.name == name }) else { fail("no opening named \(name)") }
        mesh.updateBoundaryZone(i, kind: .wall)
        setup.boundaries[name] = BoundarySettings(type: .wall)
        setup.reports.removeAll { $0.zones == [name] }
        print("  \(name) is now a wall")
    }
    // --post-line x0,y0,z0:x1,y1,z1 (line sample) and --vtk: OpenFOAM post-processing after the run
    let pl = option("--post-line", "").split(separator: ":").map { $0.split(separator: ",").compactMap { Double($0) } }
    if pl.count == 2, pl[0].count == 3, pl[1].count == 3 {
        var l = FoamLineSample(name: "line1"); l.start = pl[0]; l.end = pl[1]; l.points = 100; l.fields = "U p"
        setup.openfoam.postProcessing.lineSamples = [l]
        setup.openfoam.postProcessing.functions = ["wallShearStress", "yPlus", "vorticity"]
    }
    if args.contains("--vtk") { setup.openfoam.postProcessing.exportVTK = true }
    if args.contains("--run") {
        setup.openfoam.caseDirectory = work.appendingPathComponent("run").path
        requireTrustedContent(setup)
        let out = try FoamSolve(mesh: mesh, setup: setup).run(initial: try FoamSolve.initialFields(mesh: mesh, setup: setup), log: { print($0) }, progress: { _, _, _, _ in })
        if let f = out.failure { fail(f) }
        if let sol = out.solution {
            for r in setup.reports { print(String(format: "  %@ = %.6g", r.name, Reports.evaluate(r, solver: sol))) }
            for smp in (try? FoamPostResults.lineSamples(in: out.caseDirectory)) ?? [] {
                print("  line sample \(smp.name): \(smp.rows.count) points, columns \(smp.columns.joined(separator: " ")) → \(out.caseDirectory.path)/postProcessing/\(smp.name)")
            }
            let save = option("--save", ""); if !save.isEmpty { try CasePackage.write(to: URL(fileURLWithPath: save), mesh: mesh, setup: sol.setup, solver: sol) }
        }
    } else {
        let save = option("--save", ""); if !save.isEmpty { try CasePackage.write(to: URL(fileURLWithPath: save), mesh: mesh, setup: setup, solver: nil); print("Wrote \(save)") }
    }
case "pinn":
    // pinn <tutorial id | case.curlew> [--mode physics|hybrid|data] [--epochs N] [--lbfgs N] [--layers n]
    //   [--neurons n] [--python path] [--dir d] [--prepare-only] [--save out.curlew]
    guard args.count > 1 else { fail("pinn <tutorial id | case.curlew> [options]") }
    var mesh: Mesh, setup: CaseSetup, sol: Solution? = nil
    if args[1].hasSuffix(".curlew") {
        let pkg = try CasePackage.read(URL(fileURLWithPath: args[1]))
        mesh = pkg.mesh; setup = pkg.setup
        if pkg.hasData { let sv = try Solution(mesh: mesh, setup: setup); try CasePackage.restore(URL(fileURLWithPath: args[1]), into: sv); sol = sv }
    } else if args[1].hasPrefix("cavity-re"), let re = Int(args[1].dropFirst(9)) {
        // lid-driven cavity benchmark at any Reynolds number (Ghia et al. data at 100, 400, 1000)
        (mesh, setup) = try Benchmarks.cavityCase(re: re, cells: Int(option("--cells", "64")) ?? 64)
        setup.title = "cavity-re\(re)"
    } else {
        guard let t = TutorialCatalog.all.first(where: { $0.id == args[1] }) else { fail("tutorials: " + TutorialCatalog.all.map(\.id).joined(separator: ", ")) }
        (mesh, setup) = try t.build()
    }
    var ps = PINNSettings()
    if let v = Int(option("--interior", "")) { ps.interiorBatch = v }
    if let v = Double(option("--lr", "")) { ps.learningRate = v }
    if let d = PINNSettings.Device(rawValue: option("--device", "")) { ps.device = d }
    if let v = Double(option("--w-bc", "")) { ps.weightBC = v }
    if let m = PINNSettings.Mode(rawValue: option("--mode", "")) { ps.mode = m }
    if let v = Int(option("--epochs", "")) { ps.adamEpochs = v }
    if let v = Int(option("--lbfgs", "")) { ps.lbfgsIterations = v }
    if let v = Int(option("--layers", "")) { ps.hiddenLayers = v }
    if let v = Int(option("--neurons", "")) { ps.neurons = v }
    if args.contains("--solve") && sol == nil {
        // data for hybrid / surrogate modes: an OpenFOAM solution of the same case
        requireTrustedContent(setup)     // a case file may carry stages or code that runs programs
        let cfd = try ValidationSuite.solve(mesh, setup, cores: Int(option("--cores", "1")) ?? 1, allowCustomContent: true)
        print("CFD solution for the data points: OpenFOAM, \(cfd.iteration) iterations")
        if args[1].hasPrefix("cavity-re"), let re = Int(args[1].dropFirst(9)), Benchmarks.ghiaU[re] != nil {
            for c in Benchmarks.compareCavity(cfd, re: re) { print(String(format: "  CFD vs Ghia, %@: max |error| %.4f", c.quantity as NSString, c.maxAbsError)) }
        }
        sol = cfd
    }
    let dir = option("--dir", "").isEmpty ? PINNJob.defaultDirectory(for: setup) : URL(fileURLWithPath: option("--dir", ""))
    let job = PINNJob(mesh: mesh, setup: setup, settings: ps)
    let summary = try job.prepare(in: dir, solution: sol)
    print(summary.text + " → \(dir.path)")
    if args.contains("--prepare-only") { exit(0) }
    let py = option("--python", "").isEmpty ? PINNJob.defaultPython : option("--python", "")
    try job.run(python: py, in: dir, log: { print($0) }, progress: { _, _ in })
    let s = try PINNJob.load(from: dir, mesh: mesh, setup: setup)
    for r in setup.reports { print(String(format: "  %@ = %.6g", r.name, Reports.evaluate(r, solver: s))) }
    if args[1].hasPrefix("cavity-re"), let re = Int(args[1].dropFirst(9)), Benchmarks.ghiaU[re] != nil {
        for c in Benchmarks.compareCavity(s, re: re) {
            print(String(format: "  Ghia et al. 1982, %@: max |error| %.4f, rms %.4f", c.quantity as NSString, c.maxAbsError, c.rmsError))
        }
    }
    let save = option("--save", ""); if !save.isEmpty { try CasePackage.write(to: URL(fileURLWithPath: save), mesh: mesh, setup: setup, solver: s) }
case "pinn-env":
    // pinn-env [--install] [--dir d]: check (or create/repair) the PyTorch environment
    let dir = option("--dir", "").isEmpty ? PINNJob.environmentDirectory : URL(fileURLWithPath: option("--dir", ""))
    if args.contains("--install") {
        let py = try PINNJob.createEnvironment(directory: dir, log: { print("  " + $0) })
        print("Ready: \(py)")
    } else {
        let st = PINNJob.checkEnvironment(python: dir.appendingPathComponent("bin/python").path)
        print((st.ok ? "OK: " : "Not ready: ") + st.text)
    }
case "post-script":
    // post-script --case <OpenFOAM case> --script <file.py> [--time t] [--python p]
    // post-script <case.curlew> [--name script] [--trust-case-content]   scripts saved in a case
    // post-script --templates                                             list the template scripts
    if args.contains("--templates") {
        for t in PostScriptTemplates.all { print("\(t.script.name): \(t.title)") }
        exit(0)
    }
    let py = option("--python", "").isEmpty ? PINNJob.defaultPython : option("--python", "")
    var setup: CaseSetup? = nil
    var caseDir = option("--case", "")
    if !caseDir.isEmpty {
        caseDir = (caseDir as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: caseDir + "/system/controlDict") else { fail("\(caseDir) is not an OpenFOAM case (no system/controlDict)") }
    }
    var scripts: [FoamPostScript] = []
    if args.count > 1, !args[1].hasPrefix("--") {
        let pkg = try CasePackage.read(URL(fileURLWithPath: args[1]))
        setup = pkg.setup
        if caseDir.isEmpty { caseDir = FoamLocations.caseDirectory(for: pkg.setup).path }
        let name = option("--name", "")
        scripts = pkg.setup.openfoam.postProcessing.scripts.filter { name.isEmpty || $0.name == name }
        if scripts.isEmpty { fail(name.isEmpty ? "the case has no Python post-processing scripts" : "no script named \(name) in the case") }
        // scripts stored in a case file are code from that file: same rule as running the case
        if !args.contains("--trust-case-content") {
            print("This case contains Python post-processing scripts:\n")
            for sc in scripts { print("=== \(sc.name)\n\(sc.code)\n") }
            fail("Not run. Review the scripts above; if you trust where the case came from, run again with --trust-case-content.")
        }
    }
    let template = option("--template", "")
    if !template.isEmpty {
        guard let t = PostScriptTemplates.all.first(where: { $0.script.name == template }) else {
            fail("no template \(template); templates: " + PostScriptTemplates.all.map(\.script.name).joined(separator: ", "))
        }
        scripts = [t.script]
    }
    let file = option("--script", "")
    if !file.isEmpty {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let code = try? String(contentsOf: url, encoding: .utf8) else { fail("cannot read the script \(url.path): no such file (or not UTF-8 text)") }
        scripts = [FoamPostScript(name: url.deletingPathExtension().lastPathComponent, code: code)]
    }
    guard !caseDir.isEmpty, !scripts.isEmpty else {
        fail("post-script --case <OpenFOAM case dir> (--script <file.py> | --template <name>) [--time t] [--python p]\n       post-script <case.curlew> [--name script] [--trust-case-content]\n       post-script --templates")
    }
    var failed = false
    for sc in scripts {
        let r = try PostScriptRun().run(sc, caseDirectory: URL(fileURLWithPath: caseDir), time: option("--time", "").isEmpty ? nil : option("--time", ""),
                                        setup: setup, python: py, log: { print($0) })
        print(String(format: "%@: %@ in %.1f s (time %@)", sc.name, r.succeeded ? "finished" : "failed (exit \(r.exitCode))", r.seconds, r.time))
        for f in r.figures { print("  figure: \(f.path)") }
        failed = failed || !r.succeeded
    }
    if failed { exit(2) }
case "samples":
    // samples [--export dir]: build every CAD sample as STEP
    let dir = option("--export", "").isEmpty ? CADSample.directory : URL(fileURLWithPath: option("--export", ""))
    for sm in CADSample.allCases {
        do { let u = try sm.export(to: dir); print("\(sm.rawValue): \(u.path) — \(sm.title)") }
        catch { print("\(sm.rawValue): \(error)") }
    }
case "foam":
    try foamCommand()
case "export":
    // export <case.curlew> --foam dir | --fluent-mesh file.msh
    guard args.count > 1 else { fail("export <case.curlew> [--foam dir] [--fluent-mesh out.msh]") }
    let pkg = try CasePackage.read(URL(fileURLWithPath: args[1]))
    let foam = option("--foam", "")
    if !foam.isEmpty { try exportFoam(pkg.mesh, pkg.setup, foam, iterations: nil); print("Wrote OpenFOAM case \(foam)") }
    let fl = option("--fluent-mesh", "")
    if !fl.isEmpty { try MeshWriters.fluentMesh(pkg.mesh).write(toFile: fl, atomically: true, encoding: .utf8); print("Wrote \(fl)") }
case "mesh-info":
    guard args.count > 1 else { fail("mesh-info <file> [--bl-first h ...]") }
    let mesh = try readMesh(args[1])
    print(mesh.summary)
    for z in mesh.boundaryZones { print("  \(z.name) [\(z.kind.rawValue)] \(z.count) faces") }
    for z in mesh.cellZones { print("  cell zone \(z.name) [\(z.kind.rawValue)] \(z.cellCount) cells") }
    print(MeshQuality.report(mesh).text)
default:
    fail("unknown command \(cmd)")
}


// MARK: - OpenFOAM

func foamCommand() throws {
    guard args.count > 1 else {
        fail("""
        foam detect                                   list OpenFOAM installations and probe them
        foam run <case.json --mesh f | case.curlew | --tutorial id> [options]
             --dir d --cores n --app simpleFoam --turbulence kOmegaSST --iterations N
             --installation path --continue --write-only --save out.curlew --vtu out.vtu
        foam mesh <file.step|stl|obj|ply|off|3mf> [--internal] [--axis 0|1|2] [--unit mm]
             [--cell h] [--levels 3,4] [--layers n] [--cores n] [--dir d] [--save out.curlew]
        """)
    }
    switch args[1] {
    case "detect":
        let found = FoamDiscovery.discover()
        if found.isEmpty { print("No OpenFOAM installation found."); exit(1) }
        for inst in found {
            print("\(inst.name)  [\(inst.kind.rawValue), \(inst.version ?? "?")]  \(inst.location.path)")
            do { let env = try inst.resolve(); print("  " + env.probe().message) } catch { print("  \(error)") }
        }
    case "run":
        try foamRun(caseIndex: 2, tutorial: args.firstIndex(of: "--tutorial").map { args[$0 + 1] })
    case "mesh":
        guard args.count > 2 else { fail("foam mesh <cad file> [options]") }
        var s = SnappySettings()
        s.path = args[2]
        s.external = !args.contains("--internal")
        s.flowAxis = Int(option("--axis", "0")) ?? 0
        s.unit = CADUnit(rawValue: option("--unit", "m")) ?? .metre
        s.baseCellSize = Double(option("--cell", "0")) ?? 0
        let lv = option("--levels", "").split(separator: ",").compactMap { Int($0) }
        if lv.count == 2 { s.surfaceLevelMin = lv[0]; s.surfaceLevelMax = lv[1]; s.featureLevel = lv[1] }
        s.layers = Int(option("--layers", "3")) ?? 3
        s.cores = Int(option("--cores", "1")) ?? 1
        s.converter = option("--converter", "")
        var setup = CaseSetup()
        let d = option("--dir", "")
        let dir = d.isEmpty ? FoamLocations.defaultCaseDirectory(title: URL(fileURLWithPath: s.path).deletingPathExtension().lastPathComponent + "_mesh") : URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setup.openfoam.installation = option("--installation", "")
        let env = try FoamLocations.installation(for: setup).resolve()
        let t0 = Date()
        let r = try SnappyMesher.mesh(s, workDir: dir, environment: env, log: { print($0, terminator: "") })
        print(r.summary + String(format: " (%.1f s)", Date().timeIntervalSince(t0)))
        print(r.mesh.summary)
        for z in r.mesh.boundaryZones { print("  \(z.name) [\(z.kind.rawValue)] \(z.count) faces") }
        print(MeshQuality.report(r.mesh).text)
        let save = option("--save", "")
        if !save.isEmpty {
            setup.adopt(mesh: r.mesh)
            try CasePackage.write(to: URL(fileURLWithPath: save), mesh: r.mesh, setup: setup, solver: nil); print("Wrote \(save)")
        }
    default:
        fail("unknown foam subcommand \(args[1])")
    }
}

/// Solve a case with OpenFOAM: `<case.json> --mesh f`, `<case.curlew>` (continuing from its
/// data) or a tutorial; prints boundary flows and reports, optionally saves the results.
func foamRun(caseIndex: Int?, tutorial: String?) throws {
    var mesh: Mesh, setup: CaseSetup
    var initial: FlowState? = nil
    if let tid = tutorial {
        guard let t = TutorialCatalog.all.first(where: { $0.id == tid }) else { fail("unknown tutorial \(tid)") }
        (mesh, setup) = try t.build()
    } else {
        guard let ci = caseIndex, args.count > ci else { fail("run needs a case: <case.json> --mesh <file>, <case.curlew> or --tutorial <id>") }
        let input = URL(fileURLWithPath: args[ci])
        if input.pathExtension == "curlew" {
            let pkg = try CasePackage.read(input); mesh = pkg.mesh; setup = pkg.setup
            if pkg.hasData {
                let s = try Solution(mesh: mesh, setup: setup); s.log = { _ in }
                try CasePackage.restore(input, into: s); initial = s.state
            }
        } else {
            setup = try CaseSetup.decodeLenient(Data(contentsOf: input))
            let mp = option("--mesh", "")
            guard !mp.isEmpty else { fail("a JSON case needs --mesh <file>") }
            mesh = try readMesh(mp)
        }
    }
    if let n = Int(option("--iterations", "")) { setup.run.iterations = n; setup.run.numberOfTimeSteps = n }
    if let n = Int(option("--cores", "")) { setup.openfoam.cores = n }
    if let a = FoamApplication(rawValue: option("--app", "")) { setup.openfoam.application = a }
    if let t = FoamTurbulenceModel(rawValue: option("--turbulence", "")) { setup.openfoam.turbulence = t }
    let dir = option("--dir", ""); if !dir.isEmpty { setup.openfoam.caseDirectory = dir }
    let inst = option("--installation", ""); if !inst.isEmpty { setup.openfoam.installation = inst }
    if args.contains("--continue") { setup.openfoam.continueFromLatestTime = true }
    if let f = FoamInitialFields(rawValue: option("--initial-fields", "")) { setup.openfoam.initialFields = f }
    setup.adopt(mesh: mesh)
    print("Curlew → OpenFOAM: \(setup.title) — \(mesh.summary)")
    if initial == nil, let f = try FoamSolve.initialFields(mesh: mesh, setup: setup) {
        initial = f
        print("Initial fields from Curlew's standard initialization")
    }
    if args.contains("--write-only") {
        let d = FoamLocations.caseDirectory(for: setup)
        try FoamLocations.validate(d)
        let r = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: d, initial: initial)
        for w in r.warnings { print("warning: \(w)") }
        print("Wrote \(r.application.rawValue) case to \(d.path)"); return
    }
    requireTrustedContent(setup)
    let job = FoamSolve(mesh: mesh, setup: setup)
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    src.setEventHandler { print("\nInterrupt — stopping OpenFOAM…"); job.cancel() }
    src.resume()
    let out = try job.run(initial: initial, log: { print($0) }, progress: { _, _, _, _ in })
    print(String(format: "OpenFOAM run %@ in %.1f s", out.failure == nil ? "finished" : "stopped", out.seconds))
    if let f = out.failure { print(f) }
    if let s = out.solution {
        for z in mesh.boundaryZones where z.kind != .empty && z.kind != .wall {
            var r = ReportDefinition(name: z.name, kind: .areaWeightedAverage); r.zones = [z.name]
            var mf = ReportDefinition(name: z.name, kind: .massFlowRate); mf.zones = [z.name]
            print(String(format: "  %@: mean pressure %.6g Pa, mass flow %.6g kg/s", z.name as NSString, Reports.evaluate(r, solver: s), Reports.evaluate(mf, solver: s)))
        }
        for rep in s.setup.reports {
            let live = out.reports.series(rep.name).last.map { String(format: "  (OpenFOAM function object %.8g)", $0.1) } ?? ""
            print(String(format: "  %@ = %.8g", rep.name, Reports.evaluate(rep, solver: s)) + live)
        }
        let save = option("--save", "")
        if !save.isEmpty { try CasePackage.write(to: URL(fileURLWithPath: save), mesh: mesh, setup: s.setup, solver: s); print("Wrote \(save)") }
        let vtu = option("--vtu", "")
        if !vtu.isEmpty { try VTKExport.write(solver: s, to: URL(fileURLWithPath: vtu)); print("Wrote \(vtu)") }
    }
    if out.failure != nil { exit(2) }
}

/// Turbulent pipe (Re 20 000, SST, prism layers from snappyHexMesh): Darcy friction factor
/// from the pressure drop and from the wall shear, against smooth-pipe correlations.
func validatePipe(cores: Int) throws {
    let re = Double(option("--re", "20000"))!
    let pc = try Benchmarks.turbulentPipeCase(re: re, lengthDiameters: Double(option("--length", "10"))!,
                                              wallSize: Double(option("--wall-size", "0.06"))!, maxSize: Double(option("--max-size", "0.1"))!,
                                              yPlus: args.contains("--tet-only") ? nil : Double(option("--y-plus", "1"))!,
                                              growth: Double(option("--bl-growth", "1.25"))!)
    print("Mesh: \(pc.mesh.summary)  \(pc.mesh.cellShapeHistogram())")
    if let l = pc.layers { print("  \(l)") }
    let sol = try ValidationSuite.solve(pc.mesh, pc.setup, iterations: Int(option("--iterations", "2000"))!, cores: cores,
                                        log: { if $0.hasPrefix("iter ") || $0.hasPrefix("—") { print($0) } })
    let fr = Benchmarks.measurePipeFriction(sol, from: pc.measureFrom, to: pc.measureTo)
    print(String(format: "Friction factor between x/D = %.1f and %.1f (bulk velocity %.4f, mean wall y+ %.2f):", pc.measureFrom, pc.measureTo, fr.bulkVelocity, fr.meanYPlus))
    print(String(format: "  from dp/dx %.5f   from wall shear %.5f", fr.fromPressure, fr.fromShear))
    for (name, f) in Benchmarks.pipeFrictionCorrelations(re: re) {
        print(String(format: "  %-36@ %.5f   (dp/dx %+.2f%%, shear %+.2f%%)", name as NSString, f, 100 * (fr.fromPressure - f) / f, 100 * (fr.fromShear - f) / f))
    }
}
