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
