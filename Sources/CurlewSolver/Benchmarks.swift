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

    // MARK: Differentially heated cavity — de Vahl Davis (1983), Int. J. Numer. Meth. Fluids 3:249-264

    public struct NaturalConvectionReference: Sendable {
        public var nusselt: Double, uMax: Double, yAtUMax: Double, vMax: Double, xAtVMax: Double
    }
    public static let deVahlDavis: [Int: NaturalConvectionReference] = [
        3: NaturalConvectionReference(nusselt: 1.118, uMax: 3.649, yAtUMax: 0.813, vMax: 3.697, xAtVMax: 0.178),
        4: NaturalConvectionReference(nusselt: 2.243, uMax: 16.178, yAtUMax: 0.823, vMax: 19.617, xAtVMax: 0.119),
        5: NaturalConvectionReference(nusselt: 4.519, uMax: 34.73, yAtUMax: 0.855, vMax: 68.59, xAtVMax: 0.066),
        6: NaturalConvectionReference(nusselt: 8.800, uMax: 64.63, yAtUMax: 0.850, vMax: 219.36, xAtVMax: 0.0379),
    ]

    /// Square cavity, hot wall x=0, cold wall x=1, adiabatic top/bottom, Pr = 0.71.
    public static func naturalConvectionCase(log10Ra: Int, cells: Int, grading: Double = 4) throws -> (Mesh, CaseSetup, alpha: Double) {
        let ra = pow(10.0, Double(log10Ra))
        let pr = 0.71, g = 9.81, beta = 0.01, dT = 1.0
        let alpha = sqrt(g * beta * dT / (ra * pr))
        let nu = pr * alpha
        let half = cells / 2
        let axis = BlockAxis(start: 0, segments: [AxisSegment(end: 0.5, cells: half, grading: grading),
                                                  AxisSegment(end: 1, cells: cells - half, grading: 1 / grading)])
        let mesh = try BlockMeshSpec(x: axis, y: axis, depth: 0.1).build()
        var s = CaseSetup()
        s.title = "Natural convection Ra=1e\(log10Ra)"
        s.models.viscous = .laminar
        s.models.energy = true
        s.general.gravityEnabled = true
        s.general.gravity = [0, -g, 0]
        s.general.operatingTemperature = 300.5
        s.methods.pressure = .bodyForceWeighted
        var fluid = Material(name: "boussinesq-fluid")
        fluid.densityMethod = .boussinesq
        fluid.density = 1; fluid.viscosity = nu; fluid.specificHeat = 1; fluid.thermalConductivity = alpha
        fluid.thermalExpansion = beta
        s.materials.append(fluid)
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "boussinesq-fluid" }
        var hot = BoundarySettings(type: .wall); hot.thermalCondition = .temperature; hot.temperature = 301
        var cold = BoundarySettings(type: .wall); cold.thermalCondition = .temperature; cold.temperature = 300
        s.boundaries["x-min"] = hot
        s.boundaries["x-max"] = cold
        s.initialization.method = .standard
        s.initialization.temperature = 300.5
        s.methods.coupling = .simplec
        s.controls.urf.pressure = 1.0
        s.controls.urf.momentum = 0.7
        s.controls.urf.energy = 0.9
        s.residuals.continuity = 1e-6; s.residuals.velocity = 1e-7; s.residuals.energy = 1e-9
        s.run.iterations = 6000
        return (mesh, s, alpha)
    }

    /// Returns (Nu on hot wall, u_max * L/alpha, y at u_max, v_max * L/alpha, x at v_max).
    public static func measureNaturalConvection(_ solver: PressureBasedSolver, alpha: Double) -> (Double, Double, Double, Double, Double) {
        let m = solver.mesh
        var q = 0.0, a = 0.0
        if let z = m.zone(named: "x-min") {
            for f in z.faceRange { q += solver.state.bHeatFlux[f - m.nInternalFaces] * m.faceAreaMag[f]; a += m.faceAreaMag[f] }
        }
        let nu = (q / a) * 1.0 / (alpha * 1.0) // q L / (k dT), k = alpha (rho cp = 1), dT = 1
        let zc = m.bounds.centre.z
        let n = 400
        let ys = (0...n).map { Double($0) / Double(n) }
        let us = solver.sample("x-velocity", at: ys.map { Vec3(0.5, min(max($0, 1e-6), 1 - 1e-6), zc) })
        let vs = solver.sample("y-velocity", at: ys.map { Vec3(min(max($0, 1e-6), 1 - 1e-6), 0.5, zc) })
        let iu = us.indices.max { us[$0] < us[$1] }!, iv = vs.indices.max { vs[$0] < vs[$1] }!
        return (nu, us[iu] / alpha, ys[iu], vs[iv] / alpha, ys[iv])
    }

    // MARK: Zero-pressure-gradient flat plate (NASA TMR 2DZP layout), Re_L = 5e6

    public static func flatPlateCase(model: ViscousModel, xCells: Int = 96, yCells: Int = 96, wallFunctionMesh: Bool = false) throws -> (Mesh, CaseSetup) {
        let re = 5e6
        let x = BlockAxis(start: -0.333, segments: [AxisSegment(end: 0, cells: max(xCells / 4, 8), grading: 0.15),
                                                    AxisSegment(end: 2, cells: xCells, grading: 12)])
        // resolved: first cell y+ ~ 0.25; wall-function mesh: first cell y+ ~ 40-60
        let y = wallFunctionMesh ? BlockAxis(from: 0, to: 1, cells: 40, grading: 30) : BlockAxis(from: 0, to: 1, cells: yCells, grading: 4e4)
        let mesh = try BlockMeshSpec(x: x, y: y, depth: 0.1, patches: [
            PatchRule(name: "plate", kind: .wall, boxMin: [0, 0, -1], boxMax: [2, 0, 1], normal: [0, -1, 0]),
            PatchRule(name: "symmetry-upstream", kind: .symmetry, boxMin: [-0.333, 0, -1], boxMax: [0, 0, 1], normal: [0, -1, 0]),
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [-0.333, 0, -1], boxMax: [-0.333, 1, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [2, 0, -1], boxMax: [2, 1, 1]),
            PatchRule(name: "top", kind: .symmetry, boxMin: [-0.333, 1, -1], boxMax: [2, 1, 1]),
        ]).build()
        var s = CaseSetup()
        s.title = "Flat plate Re=5e6 (\(model.rawValue))"
        s.models.viscous = model
        var fluid = Material(name: "plate-fluid")
        fluid.density = 1; fluid.viscosity = 1 / re
        s.materials.append(fluid)
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "plate-fluid" }
        var inlet = BoundarySettings(type: .velocityInlet)
        inlet.velocityMagnitude = 1
        inlet.turbulenceSpecification = .direct
        inlet.k = 2.25e-7
        inlet.omega = 2.25e-7 / (0.009 / re)
        inlet.epsilon = 0.09 * 2.25e-7 * inlet.omega
        inlet.modifiedTurbulentViscosity = 3 / re
        if wallFunctionMesh {
            // wall-function models need a turbulent freestream to trip at the leading edge
            inlet.turbulenceSpecification = .intensityAndViscosityRatio
            inlet.turbulentIntensity = 0.01; inlet.turbulentViscosityRatio = 10
        }
        s.boundaries["inlet"] = inlet
        var outlet = BoundarySettings(type: .pressureOutlet)
        outlet.turbulenceSpecification = .direct
        outlet.k = inlet.k; outlet.omega = inlet.omega; outlet.epsilon = inlet.epsilon; outlet.modifiedTurbulentViscosity = 3 / re
        if wallFunctionMesh {
            outlet.turbulenceSpecification = .intensityAndViscosityRatio
            outlet.turbulentIntensity = 0.01; outlet.turbulentViscosityRatio = 10
        }
        s.boundaries["outlet"] = outlet
        if wallFunctionMesh { s.initialization.method = .hybrid }
        s.initialization.method = .standard
        s.initialization.velocity = [1, 0, 0]
        s.initialization.k = inlet.k; s.initialization.omega = inlet.omega
        s.initialization.epsilon = inlet.epsilon; s.initialization.modifiedTurbulentViscosity = 3 / re
        s.methods.coupling = .simplec
        s.controls.urf.pressure = 0.9
        s.controls.urf.momentum = 0.8
        s.residuals.continuity = 1e-6; s.residuals.velocity = 1e-8; s.residuals.turbulence = 1e-7
        s.reference.velocity = 1; s.reference.density = 1
        s.run.iterations = 5000
        return (mesh, s)
    }

    /// Local skin friction at x on the plate, plus u+ / y+ profile there.
    public static func flatPlateSkinFriction(_ solver: PressureBasedSolver, x: Double) -> (cf: Double, profile: [(Double, Double)]) {
        let m = solver.mesh
        guard let z = m.zone(named: "plate") else { return (.nan, []) }
        var best = -1, bd = Double.infinity
        for f in z.faceRange { let d = abs(m.faceCentres[f].x - x); if d < bd { bd = d; best = f } }
        let bf = best - m.nInternalFaces
        let tau = norm(solver.state.bWallShear[bf])
        let cf = tau / 0.5
        let ut = sqrt(tau)
        let nu = 1 / 5e6
        let zc = m.bounds.centre.z
        let ys = (0..<60).map { 1e-6 * pow(10, Double($0) / 12) }.filter { $0 < 0.05 }
        let us = solver.sample("x-velocity", at: ys.map { Vec3(m.faceCentres[best].x, $0, zc) })
        return (cf, zip(ys, us).map { ($0 * ut / nu, $1 / ut) })
    }

    /// Empirical turbulent flat-plate correlations for local Cf.
    public static func cfCorrelations(reX: Double) -> [(String, Double)] {
        [("Prandtl 1/7-power  0.0592 Re^-0.2", 0.0592 * pow(reX, -0.2)),
         ("Schlichting (2log Re - 0.65)^-2.3", pow(2 * log10(reX) - 0.65, -2.3)),
         ("White 0.455/ln^2(0.06 Re)", 0.455 / pow(log(0.06 * reX), 2))]
    }

    /// Momentum-thickness Reynolds number at station x (edge velocity taken at y = 0.5).
    public static func flatPlateReTheta(_ solver: PressureBasedSolver, x: Double, nu: Double = 1 / 5e6) -> Double {
        let zc = solver.mesh.bounds.centre.z
        let n = 4000
        let ys = (0...n).map { 0.2 * pow(Double($0) / Double(n), 2) }
        let us = solver.sample("x-velocity", at: ys.map { Vec3(x, max($0, 1e-9), zc) })
        let Ue = solver.sample("x-velocity", at: [Vec3(x, 0.5, zc)])[0]
        var theta = 0.0
        for i in 1..<ys.count {
            let a = us[i - 1] / Ue, b = us[i] / Ue
            theta += 0.5 * (a * (1 - a) + b * (1 - b)) * (ys[i] - ys[i - 1])
        }
        return Ue * theta / nu
    }

    /// Karman-Schoenherr: 1/Cf = 17.08 (log10 Re_theta)^2 + 25.11 log10 Re_theta + 6.012 (used by NASA TMR).
    public static func karmanSchoenherr(reTheta: Double) -> Double {
        let l = log10(reTheta)
        return 1 / (17.08 * l * l + 25.11 * l + 6.012)
    }
}
