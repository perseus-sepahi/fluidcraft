import Foundation
import CurlewMesh
import CurlewSolver
import CurlewLinear
import CurlewPost

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
        var (mesh, setup) = try Benchmarks.cavityCase(re: re, cells: cells)
        if let t = Double(option("--p-tol", "")) { setup.controls.linear.pressure.relTol = t }
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
    case "sod":
        let (mesh, setup, endT) = try Benchmarks.sodCase(cells: Int(option("--cells", "400"))!)
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        let r = solver.run()
        let (l1, prof) = Benchmarks.sodError(solver, endTime: endT)
        print(String(format: "Sod: %d cells, t = %.4e s (%d steps, %d explicit stages) in %.2f s; L1(rho error) = %.4f", mesh.nCells, solver.state.time, solver.state.timeStep, solver.iteration, Date().timeIntervalSince(t0), l1))
        _ = r
        for (i, p) in prof.enumerated() where i % max(1, prof.count / 20) == 0 { print(String(format: "  x %.3f  rho %.4f  exact %.4f", p.0, p.1, p.2)) }
    case "ramp":
        let (mesh, setup) = try Benchmarks.rampCase(nx: Int(option("--nx", "150"))!, ny: Int(option("--ny", "100"))!)
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        let r = solver.run(iterations: Int(option("--iterations", "4000"))) { s, res in if s.iteration % 500 == 0 { print(s.formatResiduals(res)) } }
        print("iterations \(r.iterations) converged \(r.converged) diverged \(r.diverged) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let beta = Benchmarks.obliqueShockAngle(mach: 2.5, deflection: 15 * .pi / 180)
        let mn = 2.5 * sin(beta)
        let p21 = 1 + 2 * 1.4 / 2.4 * (mn * mn - 1)
        var pr = 0.0, a = 0.0
        if let z = mesh.zone(named: "ramp") {
            for f in z.faceRange where mesh.faceCentres[f].x > 0.8 && mesh.faceCentres[f].x < 1.3 {
                pr += (solver.state.bP[f - mesh.nInternalFaces] + setup.general.operatingPressure) * mesh.faceAreaMag[f]; a += mesh.faceAreaMag[f]
            }
        }
        let ratio = pr / a / 1e5
        // shock position along y = 0.5: where pressure crosses the mean of p1 and p2
        let zc = mesh.bounds.centre.z
        let xs = (0...600).map { 0.5 + Double($0) / 600 }
        let ps = solver.sample("pressure", at: xs.map { Vec3($0, 0.5, zc) })
        var xShock = Double.nan
        let mid = 1e5 * (1 + p21) / 2
        for i in 1..<ps.count where ps[i - 1] < mid && ps[i] >= mid { xShock = xs[i - 1] + (xs[i] - xs[i - 1]) * (mid - ps[i - 1]) / (ps[i] - ps[i - 1]); break }
        let betaNum = atan(0.5 / (xShock - 0.5)) * 180 / .pi
        print(String(format: "p2/p1 on ramp: Curlew %.4f   theory %.4f   (%.2f%%)", ratio, p21, 100 * (ratio - p21) / p21))
        print(String(format: "shock angle:   Curlew %.2f deg   theory %.2f deg", betaNum, beta * 180 / .pi))
    default: fail("unknown validation case \(which)")
    }
case "tutorial":
    guard args.count > 1, let t = TutorialCatalog.all.first(where: { $0.id == args[1] }) else {
        fail("tutorials: " + TutorialCatalog.all.map(\.id).joined(separator: ", "))
    }
    let t0 = Date()
    var (mesh, setup) = try t.build()
    if let n = Int(option("--iterations", "")) { setup.run.iterations = n; setup.run.numberOfTimeSteps = n }
    if let v = Double(option("--urf-u", "")) { setup.controls.urf.momentum = v }
    if let v = Double(option("--urf-p", "")) { setup.controls.urf.pressure = v }
    if let c = PVCoupling(rawValue: option("--coupling", "")) { setup.methods.coupling = c }
    if let m = ViscousModel(rawValue: option("--model", "")) { setup.models.viscous = m }
    if let sch = ConvectionScheme(rawValue: option("--mom-scheme", "")) { setup.methods.momentum = sch }
    if let tf = TransientFormulation(rawValue: option("--time-scheme", "")) { setup.methods.transient = tf }
    if args.contains("--no-limit") { setup.methods.limitMomentum = false }
    if let pi = PressureInterpolation(rawValue: option("--pressure", "")) { setup.methods.pressure = pi }
    if let nu = Double(option("--mu", "")) { for i in setup.materials.indices where setup.materials[i].kind == .fluid { setup.materials[i].viscosity = nu } }
    if let g = GradientScheme(rawValue: option("--gradient", "")) { setup.methods.gradient = g }
    if let sch = ConvectionScheme(rawValue: option("--energy-scheme", "")) { setup.methods.energy = sch }
    if let dir = args.firstIndex(of: "--export-foam").map({ args[$0 + 1] }) {
        var o = FoamCaseExporter.Options(); o.iterations = setup.run.iterations
        try FoamCaseExporter.export(mesh: mesh, setup: setup, to: URL(fileURLWithPath: dir), options: o)
        print("OpenFOAM case written to \(dir)"); exit(0)
    }
    if args.contains("--mesh-info") {
        print("  shapes \(mesh.cellShapeHistogram())")
        for z in mesh.boundaryZones { print("  zone \(z.name) [\(z.kind.rawValue)] \(z.count)") }
        print(MeshQuality.report(mesh).text)
    }
    print("\(t.title): \(mesh.summary) (built in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
    let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
    solver.log = { _ in }
    try solver.initialize()
    let t1 = Date()
    let every = Int(option("--every", "100"))!
    var lastU = solver.state.u
    let r = solver.run { s, res in
        if s.iteration % every == 0 {
            print(s.formatResiduals(res))
            if args.contains("--debug") {
                var du = 0.0, umax = 0.0, worst = 0
                for c in 0..<s.mesh.nCells { let d = norm(s.state.u[c] - lastU[c]); if d > du { du = d; worst = c }; umax = max(umax, norm(s.state.u[c])) }
                let wc = s.mesh.cellCentres[worst]
                print(String(format: "      worst cell at (%.4f, %.4f, %.4f), u = (%.3f, %.3f, %.3f)", wc.x, wc.y, wc.z, s.state.u[worst].x, s.state.u[worst].y, s.state.u[worst].z))
                lastU = s.state.u
                var imb = [Double](repeating: 0, count: s.mesh.nCells)
                for f in 0..<s.mesh.nInternalFaces { imb[Int(s.mesh.owner[f])] += s.state.massFlux[f]; imb[Int(s.mesh.neighbour[f])] -= s.state.massFlux[f] }
                for f in s.mesh.nInternalFaces..<s.mesh.nFaces { imb[Int(s.mesh.owner[f])] += s.state.massFlux[f] }
                var inflow = 0.0
                for f in s.mesh.nInternalFaces..<s.mesh.nFaces where s.state.massFlux[f] < 0 { inflow -= s.state.massFlux[f] }
                let wmax = s.state.u.map { abs($0.z) }.max()!
                print(String(format: "      max|du| over %d its %.3e (|u|max %.3f, |w|max %.3e)  sum|imbalance|/inflow %.3e  p(probe) %.6f", every, du, umax, wmax, imb.map(abs).reduce(0, +) / inflow,
                             s.sample("pressure", at: [s.mesh.bounds.centre])[0]))
            }
        }
    }
    print("iterations \(r.iterations) converged \(r.converged) diverged \(r.diverged) in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
    for rep in solver.setup.reports { print(String(format: "  %@ = %.6g", rep.name, Reports.evaluate(rep, solver: solver))) }
    if args.contains("--reattachment"), let z = mesh.zone(named: "y-min") {
        // reattachment: first downstream wall face (x > 0, y = 0) where wall shear x changes sign to positive
        var faces = Array(z.faceRange).filter { mesh.faceCentres[$0].y < 1e-9 && mesh.faceCentres[$0].x > 0 }
        faces.sort { mesh.faceCentres[$0].x < mesh.faceCentres[$1].x }
        let nI = mesh.nInternalFaces
        var xr = Double.nan
        for i in 1..<faces.count {
            let a = solver.state.bWallShear[faces[i - 1] - nI].x, b = solver.state.bWallShear[faces[i] - nI].x
            if a < 0 && b >= 0 { let xa = mesh.faceCentres[faces[i - 1]].x, xb = mesh.faceCentres[faces[i]].x; xr = xa + (xb - xa) * (-a) / (b - a) }
        }
        print(String(format: "  reattachment x_r/h = %.3f", xr))
    }
    if args.contains("--debug") && setup.models.energy {
        let st = solver.state
        let i = st.T.indices.max { st.T[$0] < st.T[$1] }!
        let c = mesh.cellCentres[i]
        print(String(format: "  max T %.3f at (%.4f, %.4f, %.4f), u = (%.3f, %.3f, %.3f)", st.T[i], c.x, c.y, c.z, st.u[i].x, st.u[i].y, st.u[i].z))
        for k in mesh.cellFaceRange(i) {
            let f = Int(mesh.cellFaces[k])
            if f < mesh.nInternalFaces {
                let n = Int(mesh.owner[f]) == i ? Int(mesh.neighbour[f]) : Int(mesh.owner[f])
                print(String(format: "     neighbour T %.3f  flux %+.4e", st.T[n], (Int(mesh.owner[f]) == i ? 1.0 : -1.0) * st.massFlux[f]))
            } else {
                print(String(format: "     boundary %@ T %.3f flux %+.4e", mesh.boundaryZones[mesh.zoneIndex(ofFace: f)!].name, st.bT[f - mesh.nInternalFaces], st.massFlux[f]))
            }
        }
    }
    for z in mesh.boundaryZones where [.velocityInlet, .pressureOutlet, .massFlowInlet, .pressureInlet].contains(z.kind) {
        var d = ReportDefinition(name: z.name, kind: .massFlowRate); d.zones = [z.name]
        var p = ReportDefinition(name: z.name, kind: .areaWeightedAverage); p.zones = [z.name]; p.field = "pressure"
        var tt = ReportDefinition(name: z.name, kind: .massWeightedAverage); tt.zones = [z.name]; tt.field = "temperature"
        print(String(format: "  %-16@ mass flow %+.6g kg/s, mean p %.6g Pa%@", z.name as NSString, Reports.evaluate(d, solver: solver), Reports.evaluate(p, solver: solver),
                     setup.models.energy ? String(format: ", T %.4f K", Reports.evaluate(tt, solver: solver)) : ""))
    }
    if let out = args.firstIndex(of: "--vtu").map({ args[$0 + 1] }) { try VTKExport.write(solver: solver, to: URL(fileURLWithPath: out)); print("wrote \(out)") }
case "tee":
    // tee in 2D or 3D with the tutorial's physics, for convergence diagnosis
    let threeD = args.contains("--3d")
    let x = BlockAxis(start: 0, segments: [AxisSegment(end: 0.15, cells: 20), AxisSegment(end: 0.21, cells: 10), AxisSegment(end: 0.9, cells: 70, grading: 3)])
    let y = BlockAxis(start: -0.15, segments: [AxisSegment(end: 0, cells: 18), AxisSegment(end: 0.06, cells: 12)])
    let z: BlockAxis? = threeD ? BlockAxis(from: 0, to: 0.06, cells: 12) : nil
    let mesh = try BlockMeshSpec(x: x, y: y, z: z, depth: 0.06, obstacles: [[-1, -1, -1, 0.15, 0, 1], [0.21, -1, -1, 2, 0, 1]], patches: [
        PatchRule(name: "inlet-main", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.06, 1]),
        PatchRule(name: "inlet-branch", kind: .velocityInlet, boxMin: [0.15, -0.15, -1], boxMax: [0.21, -0.15, 1]),
        PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.9, 0, -1], boxMax: [0.9, 0.06, 1]),
    ]).build()
    var s = CaseSetup()
    s.models.viscous = ViscousModel(rawValue: option("--model", "k-epsilon-realizable"))!
    s.adopt(mesh: mesh)
    for k in s.cellZones.keys { s.cellZones[k]!.material = "water-liquid" }
    s.materials.append(MaterialLibrary.lookup("water-liquid")!)
    var main = BoundarySettings(type: .velocityInlet); main.velocityMagnitude = .constant(Double(option("--u-main", "0.3"))!)
    main.turbulenceSpecification = .intensityAndHydraulicDiameter; main.hydraulicDiameter = 0.06
    var br = main; br.velocityMagnitude = .constant(Double(option("--u-branch", "0.1"))!)
    s.boundaries["inlet-main"] = main; s.boundaries["inlet-branch"] = br
    s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.7
    if let sch = ConvectionScheme(rawValue: option("--mom-scheme", "")) { s.methods.momentum = sch }
    let solver = try PressureBasedSolver(mesh: mesh, setup: s)
    solver.log = { _ in }
    try solver.initialize()
    let r = solver.run(iterations: Int(option("--iterations", "1500"))!) { s, res in if s.iteration % 250 == 0 { print(s.formatResiduals(res)) } }
    print("tee \(threeD ? "3D" : "2D"): iterations \(r.iterations) converged \(r.converged)")
case "test3d":
    // laminar square duct (Re=50) and 3D cavity (Re=100): must converge to tight tolerances
    for which in ["duct", "cavity"] {
        let mesh: Mesh
        var s = CaseSetup()
        if which == "duct" {
            mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 2, cells: 40), y: BlockAxis(from: 0, to: 0.2, cells: 12), z: BlockAxis(from: 0, to: 0.2, cells: 12),
                                     sideKinds: ["x-min": .velocityInlet, "x-max": .pressureOutlet]).build()
            var f = Material(name: "f"); f.density = 1; f.viscosity = 0.004
            s.materials.append(f); s.adopt(mesh: mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
            var i = BoundarySettings(type: .velocityInlet); i.velocityMagnitude = 1; s.boundaries["x-min"] = i
        } else {
            mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: 24), y: BlockAxis(from: 0, to: 1, cells: 24), z: BlockAxis(from: 0, to: 1, cells: 24)).build()
            var f = Material(name: "f"); f.density = 1; f.viscosity = 0.01
            s.materials.append(f); s.adopt(mesh: mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
            var lid = BoundarySettings(type: .wall); lid.wallMotion = .moving; lid.wallVelocity = [1, 0, 0]; s.boundaries["y-max"] = lid
        }
        s.models.viscous = ViscousModel(rawValue: option("--model", "laminar"))!
        if s.models.viscous.isTurbulent {
            for k in s.cellZones.keys { s.cellZones[k]!.material = "water-liquid" }
            s.materials.append(MaterialLibrary.lookup("water-liquid")!)
            if which == "duct" { s.boundaries["x-min"]!.velocityMagnitude = 0.1; s.boundaries["x-min"]!.turbulenceSpecification = .intensityAndHydraulicDiameter; s.boundaries["x-min"]!.hydraulicDiameter = 0.2 }
        }
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.8
        s.residuals.continuity = 1e-6; s.residuals.velocity = 1e-7
        let solver = try PressureBasedSolver(mesh: mesh, setup: s)
        solver.log = { _ in }
        try solver.initialize()
        let r = solver.run(iterations: 3000) { s, res in if s.iteration % 250 == 0 { print(which, s.formatResiduals(res)) } }
        print("\(which): iterations \(r.iterations) converged \(r.converged)")
    }
case "bench-linear":
    // 3D Poisson (Dirichlet walls) on an n^3 block mesh: CPU AMG-FCG vs Metal GPU AMG-PCG (mixed precision)
    import_bench()
case "bench-solver":
    let n = Int(option("--n", "64"))!
    let its = Int(option("--iterations", "30"))!
    let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: n), y: BlockAxis(from: 0, to: 1, cells: n), z: BlockAxis(from: 0, to: 1, cells: n)).build()
    for gpu in [false, true] {
        var s = CaseSetup()
        var f = Material(name: "f"); f.density = 1; f.viscosity = 0.01
        s.materials.append(f); s.adopt(mesh: mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
        var lid = BoundarySettings(type: .wall); lid.wallMotion = .moving; lid.wallVelocity = [1, 0, 0]; s.boundaries["y-max"] = lid
        s.models.viscous = .laminar
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.8
        s.controls.linear.useGPU = gpu
        let solver = try PressureBasedSolver(mesh: mesh, setup: s)
        solver.log = { _ in }
        try solver.initialize()
        let t0 = Date()
        var last: [String: Double] = [:]
        _ = solver.run(iterations: its) { _, r in last = r }
        let dt = Date().timeIntervalSince(t0)
        if !PressureBasedSolver.profile.isEmpty {
            for (k, v) in PressureBasedSolver.profile.sorted(by: { $0.value > $1.value }) { print(String(format: "    %-12@ %7.1f ms/iteration", k as NSString, 1000 * v / Double(its))) }
            PressureBasedSolver.profile = [:]
        }
        print(String(format: "%@ pressure solver: %d cells, %d iterations in %.2f s (%.1f ms/iteration)  continuity %.4e  x-velocity %.4e",
                     gpu ? "GPU" : "CPU", mesh.nCells, its, dt, 1000 * dt / Double(its), last["continuity"] ?? 0, last["x-velocity"] ?? 0))
    }
case "mesh-cad":
    guard args.count > 1 else { fail("mesh-cad <file.step> [--internal] [--axis 0] [--max-size 0.2] [--wall-size 0.05]") }
    var ms = MeshingSettings(template: .cad(path: args[1], external: !args.contains("--internal"), flowAxis: Int(option("--axis", "0"))!, padding: [3, 8, 3, 3, 3, 3]))
    ms.maxSize = Double(option("--max-size", "0.4"))!
    ms.wallSize = Double(option("--wall-size", "0.05"))!
    ms.growthDistance = Double(option("--growth", "1.5"))!
    let t0 = Date()
    let r = try GmshDriver.generate(ms)
    print("Gmsh CAD mesh in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(r.mesh.summary)")
    print("  shapes \(r.mesh.cellShapeHistogram())")
    for z in r.mesh.boundaryZones { print("  zone \(z.name) [\(z.kind.rawValue)] \(z.count) faces") }
    print(MeshQuality.report(r.mesh).text)
    if args.contains("--solve") {
        var s = CaseSetup()
        s.models.viscous = .laminar
        var f = Material(name: "f"); f.density = 1; f.viscosity = 0.01   // Re = 100 on a unit-diameter sphere
        s.materials.append(f); s.adopt(mesh: r.mesh); for k in s.cellZones.keys { s.cellZones[k]!.material = "f" }
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 1
        s.boundaries["inlet"] = inlet
        var ff = BoundarySettings(type: .symmetry); s.boundaries["farfield"] = ff; ff.type = .symmetry
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        if let sch = ConvectionScheme(rawValue: option("--mom-scheme", "")) { s.methods.momentum = sch }
        if let g = GradientScheme(rawValue: option("--gradient", "")) { s.methods.gradient = g }
        if let v = Double(option("--urf-u", "")) { s.controls.urf.momentum = v }
        if let v = Double(option("--nonorth", "")) { s.methods.nonOrthogonalLimit = v }
        if let pi = PressureInterpolation(rawValue: option("--pressure", "")) { s.methods.pressure = pi }
        s.reference.velocity = 1; s.reference.density = 1; s.reference.area = Double.pi * 0.25
        var cd = ReportDefinition(name: "cd", kind: .dragCoefficient); cd.zones = ["body"]
        s.reports = [cd]
        s.residuals.continuity = 1e-5; s.residuals.velocity = 1e-6
        let solver = try PressureBasedSolver(mesh: r.mesh, setup: s)
        solver.log = { _ in }
        try solver.initialize()
        let t1 = Date()
        var lastU = solver.state.u
        let res = solver.run(iterations: Int(option("--iterations", "1500"))!) { s, rr in
            if s.iteration % 250 == 0 {
                print(s.formatResiduals(rr))
                var du = 0.0, worst = 0
                for c in 0..<s.mesh.nCells { let d = norm(s.state.u[c] - lastU[c]); if d > du { du = d; worst = c } }
                lastU = s.state.u
                let wc = s.mesh.cellCentres[worst]
                var nb = 0, wallFaces = 0
                for k in s.mesh.cellFaceRange(worst) { let f = Int(s.mesh.cellFaces[k]); if f >= s.mesh.nInternalFaces { wallFaces += 1 } else { nb += 1 } }
                print(String(format: "      worst cell %d at (%.3f, %.3f, %.3f) |u| %.3f du %.3e vol %.2e boundary faces %d, OQ %.3f", worst, wc.x, wc.y, wc.z, norm(s.state.u[worst]), du, s.mesh.cellVolumes[worst], wallFaces, MeshQuality.orthogonalQuality(s.mesh)[worst]))
            }
        }
        print("iterations \(res.iterations) converged \(res.converged) in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s; Cd = \(String(format: "%.4f", Reports.evaluate(s.reports[0], solver: solver))) (Re=100 sphere: ~1.09)")
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


func import_bench() {
    let n = Int(option("--n", "80"))!
    let mesh = try! BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: n), y: BlockAxis(from: 0, to: 1, cells: n), z: BlockAxis(from: 0, to: 1, cells: n)).build()
    let (pat, up, lo) = SparsePattern.fromPairs(n: mesh.nCells, owner: mesh.owner, neighbour: mesh.neighbour)
    let A = SparseMatrix(pattern: pat)
    var b = [Double](repeating: 0, count: mesh.nCells)
    for f in 0..<mesh.nInternalFaces {
        let P = Int(mesh.owner[f]), N = Int(mesh.neighbour[f])
        let S = mesh.faceAreas[f], d = mesh.cellCentres[N] - mesh.cellCentres[P]
        let c = dot(S, S) / dot(S, d)
        A.values[Int(pat.diag[P])] += c; A.values[Int(pat.diag[N])] += c
        A.values[Int(up[f])] -= c; A.values[Int(lo[f])] -= c
    }
    for f in mesh.nInternalFaces..<mesh.nFaces {
        let P = Int(mesh.owner[f]); let S = mesh.faceAreas[f], d = mesh.faceCentres[f] - mesh.cellCentres[P]
        A.values[Int(pat.diag[P])] += dot(S, S) / dot(S, d)
    }
    for c in 0..<mesh.nCells { let p = mesh.cellCentres[c]; b[c] = sin(3 * p.x) * cos(2 * p.y) * mesh.cellVolumes[c] }
    print("3D Poisson: \(mesh.nCells) unknowns, \(pat.nnz) non-zeros")
    for tol in [1e-2, 1e-6] {
        var x = [Double](repeating: 0, count: mesh.nCells)
        let cpu = LinearSolver(LinearSolverSettings(method: .amgCG, cycle: .k, relTol: tol, maxIterations: 200))
        cpu.amg.setup(A)
        _ = cpu.solve(A, x: &x, b: b) // warm-up (setup cached)
        x = [Double](repeating: 0, count: mesh.nCells)
        var t0 = Date()
        let sc = cpu.solve(A, x: &x, b: b)
        let tCPU = Date().timeIntervalSince(t0)
        print(String(format: "  rel tol %.0e  CPU  AMG-FCG(K): %3d its  %.3f s  final %.2e", tol, sc.iterations, tCPU, sc.finalResidual / sc.initialResidual))
        guard let gpu = GPUAccelerator.shared else { print("  no Metal device"); continue }
        gpu.minimumRows = 0
        let gs = LinearSolver(LinearSolverSettings(method: .amgCG, cycle: .k, relTol: tol, maxIterations: 200))
        gs.accelerator = gpu
        var xg = [Double](repeating: 0, count: mesh.nCells)
        _ = gs.solve(A, x: &xg, b: b) // warm-up: buffers and pipelines
        xg = [Double](repeating: 0, count: mesh.nCells)
        t0 = Date()
        let sg = gs.solve(A, x: &xg, b: b)
        let tGPU = Date().timeIntervalSince(t0)
        var diff = 0.0, mx = 0.0
        for i in 0..<x.count { diff = max(diff, abs(x[i] - xg[i])); mx = max(mx, abs(x[i])) }
        print(String(format: "  rel tol %.0e  GPU  %@: %3d its  %.3f s  final %.2e  (speed-up %.2fx, max |x_gpu - x_cpu| / max|x| = %.1e)",
                     tol, gpu.name, sg.iterations, tGPU, sg.finalResidual / sg.initialResidual, tCPU / tGPU, diff / max(mx, 1e-300)))
    }
}
