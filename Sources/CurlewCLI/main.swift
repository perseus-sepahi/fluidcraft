import Foundation
import CurlewMesh
import CurlewSolver

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard let cmd = args.first else {
    print("""
    curlew-cli — Curlew CFD batch interface

      validate cavity --re 100 --cells 64
      mesh-info <mesh file>
    """)
    exit(0)
}

func option(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}

switch cmd {
case "validate":
    let which = args.count > 1 ? args[1] : "cavity"
    switch which {
    case "cavity":
        let re = Int(option("--re", "100"))!
        let cells = Int(option("--cells", "64"))!
        let (mesh, setup) = try Benchmarks.cavityCase(re: re, cells: cells)
        print("Mesh: \(mesh.summary)")
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        let r = solver.run(iterations: Int(option("--iterations", "4000"))) { s, res in
            if s.iteration % 100 == 0 { print(s.formatResiduals(res)) }
        }
        let dt = Date().timeIntervalSince(t0)
        print("iterations \(r.iterations) converged \(r.converged) in \(String(format: "%.2f", dt)) s")
        for c in Benchmarks.compareCavity(solver, re: re) {
            print("\(c.quantity): max |err| = \(String(format: "%.4f", c.maxAbsError)), rms = \(String(format: "%.4f", c.rmsError))")
            for i in 0..<c.positions.count {
                print(String(format: "   %.4f  ref %+.5f  curlew %+.5f", c.positions[i], c.reference[i], c.computed[i]))
            }
        }
    case "natural-convection":
        let lr = Int(option("--log-ra", "5"))!
        let cells = Int(option("--cells", "64"))!
        let (mesh, setup, alpha) = try Benchmarks.naturalConvectionCase(log10Ra: lr, cells: cells)
        print("Mesh: \(mesh.summary)")
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        let r = solver.run(iterations: Int(option("--iterations", "6000"))) { s, res in
            if s.iteration % 200 == 0 { print(s.formatResiduals(res)) }
        }
        print("iterations \(r.iterations) converged \(r.converged) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        let (nu, um, yu, vm, xv) = Benchmarks.measureNaturalConvection(solver, alpha: alpha)
        let ref = Benchmarks.deVahlDavis[lr]!
        print(String(format: "Nu      curlew %.4f   de Vahl Davis %.3f   (%.2f%%)", nu, ref.nusselt, 100 * (nu - ref.nusselt) / ref.nusselt))
        print(String(format: "u_max   curlew %.3f at y=%.3f   ref %.3f at y=%.3f", um, yu, ref.uMax, ref.yAtUMax))
        print(String(format: "v_max   curlew %.3f at x=%.4f   ref %.3f at x=%.4f", vm, xv, ref.vMax, ref.xAtVMax))
    case "flat-plate":
        let model = ViscousModel(rawValue: option("--model", "k-omega-sst")) ?? .kOmegaSST
        var (mesh, setup) = try Benchmarks.flatPlateCase(model: model, xCells: Int(option("--x-cells", "96"))!, yCells: Int(option("--y-cells", "96"))!, wallFunctionMesh: args.contains("--wall-function-mesh"))
        if let sch = ConvectionScheme(rawValue: option("--turb-scheme", "")) { setup.methods.turbulence = sch }
        if let sch = ConvectionScheme(rawValue: option("--mom-scheme", "")) { setup.methods.momentum = sch }
        let exportDir = option("--export-foam", "")
        if !exportDir.isEmpty {
            var o = FoamCaseExporter.Options()
            o.iterations = Int(option("--iterations", "5000"))!
            try FoamCaseExporter.export(mesh: mesh, setup: setup, to: URL(fileURLWithPath: exportDir), options: o)
            print("OpenFOAM case written to \(exportDir)")
            exit(0)
        }
        print("Mesh: \(mesh.summary)")
        print(MeshQuality.report(mesh).text)
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        let r = solver.run(iterations: Int(option("--iterations", "5000"))) { s, res in
            if args.contains("--debug") {
                let st = s.state
                let ratio = zip(st.muT, st.mu).map { $0 / $1 }
                print(String(format: "   k [%.3e, %.3e] omega [%.3e, %.3e] muT/mu max %.3e  |u| max %.3e", st.k.min()!, st.k.max()!, st.omega.min()!, st.omega.max()!, ratio.max()!, st.u.map { norm($0) }.max()!))
                let iw = st.omega.indices.min { st.omega[$0] < st.omega[$1] }!
                let im = ratio.indices.max { ratio[$0] < ratio[$1] }!
                let c1 = s.mesh.cellCentres[iw], c2 = s.mesh.cellCentres[im]
                print(String(format: "   min omega at (%.4g, %.4g) y=%.3e  max ratio at (%.4g, %.4g)", c1.x, c1.y, s.geo.wallDistance[iw], c2.x, c2.y))
            }
            if s.iteration % Int(option("--every", "200"))! == 0 { print(s.formatResiduals(res)) }
        }
        print("iterations \(r.iterations) converged \(r.converged) diverged \(r.diverged) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        for xs in [0.5, 0.97, 1.5] {
            let (cf, _) = Benchmarks.flatPlateSkinFriction(solver, x: xs)
            var line = String(format: "x=%.2f  Cf curlew %.6f", xs, cf)
            let rt = Benchmarks.flatPlateReTheta(solver, x: xs)
            let ks = Benchmarks.karmanSchoenherr(reTheta: rt)
            line += String(format: "  Re_theta %.0f  Karman-Schoenherr %.6f (%+.2f%%)", rt, ks, 100 * (cf - ks) / ks)
            print(line)
        }
        let (_, prof) = Benchmarks.flatPlateSkinFriction(solver, x: 0.97)
        print("u+ vs y+ at x=0.97 (log law: u+ = ln(y+)/0.41 + 5.0):")
        for (yp, up) in prof where yp > 0.5 && yp < 3000 {
            print(String(format: "  y+ %9.2f  u+ %7.3f   law %7.3f", yp, up, yp < 11 ? yp : log(yp) / 0.41 + 5.0))
        }
    case "cylinder":
        let dt = Double(option("--dt", "0.05"))!
        let endT = Double(option("--time", "200"))!
        let (mesh, setup) = try Benchmarks.cylinderCase(dt: dt, endTime: endT)
        print("Mesh: \(mesh.summary)")
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        var lastPrint = 0
        let r = solver.run { s, _ in
            if s.state.timeStep % 200 == 0 && s.state.timeStep != lastPrint {
                lastPrint = s.state.timeStep
                let cl = s.reportHistory.series("cl").last?.1 ?? 0, cd = s.reportHistory.series("cd").last?.1 ?? 0
                print(String(format: "t = %7.2f  cd %.4f  cl %+.4f  (%.0f s)", s.state.time, cd, cl, Date().timeIntervalSince(t0)))
            }
        }
        print("iterations \(r.iterations) diverged \(r.diverged) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        if let res = Benchmarks.analyseShedding(solver.reportHistory, settle: endT * 0.5) {
            print(String(format: "Strouhal %.4f (ref 0.164-0.166)  Cd mean %.4f (ref 1.33-1.35)  Cl amplitude %.4f (ref 0.32-0.34) over %d periods",
                         res.strouhal, res.cdMean, res.clAmplitude, res.periods))
        } else { print("no periodic shedding detected") }
    case "schafer-turek":
        var ms = MeshingSettings(template: .channelCylinder(length: 2.2, height: 0.41, cx: 0.2, cy: 0.2, radius: 0.05))
        ms.maxSize = Double(option("--max-size", "0.02"))!
        ms.wallSize = Double(option("--wall-size", "0.003"))!
        ms.growthDistance = 0.3
        ms.blFirstHeight = Double(option("--bl", "0.0008"))!; ms.blGrowth = 1.15; ms.blThickness = 0.01
        ms.depth2D = 1
        let t0 = Date()
        let gm = try GmshDriver.generate(ms)
        let mesh = gm.mesh
        print("Gmsh mesh: \(mesh.summary) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        print("  shapes: \(mesh.cellShapeHistogram())")
        for z in mesh.boundaryZones { print("  \(z.name) [\(z.kind.rawValue)] \(z.count)") }
        print(MeshQuality.report(mesh).text)
        let solver = try PressureBasedSolver(mesh: mesh, setup: Benchmarks.schaferTurekSetup(mesh: mesh))
        solver.log = { _ in }
        try solver.initialize()
        let t1 = Date()
        let r = solver.run(iterations: Int(option("--iterations", "3000"))) { s, res in
            if s.iteration % 500 == 0 { print(s.formatResiduals(res)) }
        }
        print("iterations \(r.iterations) converged \(r.converged) in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
        let cd = Reports.evaluate(solver.setup.reports[0], solver: solver), cl = Reports.evaluate(solver.setup.reports[1], solver: solver)
        let zc = mesh.bounds.centre.z
        let pp = solver.sample("pressure", at: [Vec3(0.15, 0.2, zc), Vec3(0.25, 0.2, zc)])
        print(String(format: "Cd %.4f (ref 5.57-5.59)  Cl %.5f (ref 0.0104-0.0110)  dp %.5f (ref 0.1172-0.1176)", cd, cl, pp[0] - pp[1]))
    default: fail("unknown validation case \(which)")
    }
case "mesh-info":
    guard args.count > 1 else { fail("mesh-info <file>") }
    let mesh = try MeshIO.read(url: URL(fileURLWithPath: args[1]))
    print(mesh.summary)
    for z in mesh.boundaryZones { print("  \(z.name) [\(z.kind.rawValue)] \(z.count) faces") }
    for z in mesh.cellZones { print("  cell zone \(z.name) [\(z.kind.rawValue)] \(z.cellCount) cells") }
    print(MeshQuality.report(mesh).text)
default:
    fail("unknown command \(cmd)")
}
