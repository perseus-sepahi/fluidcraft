import Foundation
import CurlewMesh

/// Published reference solutions and the cases that reproduce them.
public enum Benchmarks {
    public struct Comparison: Sendable, Codable {
        public var name: String
        public var quantity: String
        public var positions: [Double]
        public var reference: [Double]
        public var computed: [Double]
        public var maxAbsError: Double { zip(reference, computed).map { abs($0 - $1) }.max() ?? 0 }
        public var rmsError: Double {
            let n = Double(max(reference.count, 1))
            return sqrt(zip(reference, computed).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / n)
        }
    }

    // MARK: Lid-driven cavity — Ghia, Ghia & Shin (1982), J. Comput. Phys. 48:387-411

    public static let ghiaY: [Double] = [1.0000, 0.9766, 0.9688, 0.9609, 0.9531, 0.8516, 0.7344, 0.6172, 0.5000,
                                         0.4531, 0.2813, 0.1719, 0.1016, 0.0703, 0.0625, 0.0547, 0.0000]
    public static let ghiaX: [Double] = [1.0000, 0.9688, 0.9609, 0.9531, 0.9453, 0.9063, 0.8594, 0.8047, 0.5000,
                                         0.2344, 0.2266, 0.1563, 0.0938, 0.0781, 0.0703, 0.0625, 0.0000]
    public static let ghiaU: [Int: [Double]] = [
        100: [1.00000, 0.84123, 0.78871, 0.73722, 0.68717, 0.23151, 0.00332, -0.13641, -0.20581,
              -0.21090, -0.15662, -0.10150, -0.06434, -0.04775, -0.04192, -0.03717, 0.00000],
        400: [1.00000, 0.75837, 0.68439, 0.61756, 0.55892, 0.29093, 0.16256, 0.02135, -0.11477,
              -0.17119, -0.32726, -0.24299, -0.14612, -0.10338, -0.09266, -0.08186, 0.00000],
        1000: [1.00000, 0.65928, 0.57492, 0.51117, 0.46604, 0.33304, 0.18719, 0.05702, -0.06080,
               -0.10648, -0.27805, -0.38289, -0.29730, -0.22220, -0.20196, -0.18109, 0.00000],
    ]
    public static let ghiaV: [Int: [Double]] = [
        100: [0.00000, -0.05906, -0.07391, -0.08864, -0.10313, -0.16914, -0.22445, -0.24533, 0.05454,
              0.17527, 0.17507, 0.16077, 0.12317, 0.10890, 0.10091, 0.09233, 0.00000],
        // Re=400 at x=0.9063 (-0.23827) is a known misprint in the original table; it is excluded.
        400: [0.00000, -0.12146, -0.15663, -0.19254, -0.22847, .nan, -0.44993, -0.38598, 0.05186,
              0.30174, 0.30203, 0.28124, 0.22965, 0.20920, 0.19713, 0.18360, 0.00000],
        1000: [0.00000, -0.21388, -0.27669, -0.33714, -0.39188, -0.51550, -0.42665, -0.31966, 0.02526,
               0.32235, 0.33075, 0.37095, 0.32627, 0.30353, 0.29012, 0.27485, 0.00000],
    ]

    public static func cavityCase(re: Int, cells: Int) throws -> (Mesh, CaseSetup) {
        let mesh = try BlockMeshSpec(x: BlockAxis(from: 0, to: 1, cells: cells), y: BlockAxis(from: 0, to: 1, cells: cells), depth: 0.1).build()
        var s = CaseSetup()
        s.title = "Lid-driven cavity Re=\(re)"
        s.models.viscous = .laminar
        var fluid = Material(name: "cavity-fluid")
        fluid.density = 1; fluid.viscosity = 1 / Double(re)
        s.materials.append(fluid)
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "cavity-fluid" }
        var lid = BoundarySettings(type: .wall)
        lid.wallMotion = .moving; lid.wallVelocity = [1, 0, 0]
        s.boundaries["y-max"] = lid
        s.methods.coupling = .simplec
        s.controls.urf.momentum = 0.8
        s.controls.urf.pressure = 1.0
        s.residuals.continuity = 1e-6
        s.residuals.velocity = 1e-7
        s.run.iterations = 4000
        s.reference.velocity = 1; s.reference.density = 1
        return (mesh, s)
    }

    public static func compareCavity(_ solver: PressureBasedSolver, re: Int) -> [Comparison] {
        let z = solver.mesh.bounds.centre.z
        let uPts = ghiaY.map { Vec3(0.5, min(max($0, 1e-9), 1 - 1e-9), z) }
        let vPts = ghiaX.map { Vec3(min(max($0, 1e-9), 1 - 1e-9), 0.5, z) }
        var u = solver.sample("x-velocity", at: uPts)
        var v = solver.sample("y-velocity", at: vPts)
        // exact wall values at the end points
        u[0] = 1; u[u.count - 1] = 0; v[0] = 0; v[v.count - 1] = 0
        let refU = ghiaU[re] ?? [], refV = ghiaV[re] ?? []
        func strip(_ pos: [Double], _ ref: [Double], _ comp: [Double]) -> ([Double], [Double], [Double]) {
            var a: [Double] = [], b: [Double] = [], c: [Double] = []
            for i in 0..<ref.count where !ref[i].isNaN { a.append(pos[i]); b.append(ref[i]); c.append(comp[i]) }
            return (a, b, c)
        }
        let (pu, ru, cu) = strip(ghiaY, refU, u)
        let (pv, rv, cv) = strip(ghiaX, refV, v)
        return [Comparison(name: "Cavity Re=\(re)", quantity: "u(x=0.5, y)", positions: pu, reference: ru, computed: cu),
                Comparison(name: "Cavity Re=\(re)", quantity: "v(x, y=0.5)", positions: pv, reference: rv, computed: cv)]
    }
}
