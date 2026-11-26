import Foundation
import FluidCraftMesh
import FluidCraftSolver

// MARK: Fully developed turbulent pipe flow — Darcy friction factor vs smooth-pipe correlations

extension Benchmarks {
    /// Smooth-pipe Darcy friction factor correlations.
    public static func pipeFrictionCorrelations(re: Double) -> [(String, Double)] {
        var f = 0.02   // Prandtl–Kármán: 1/√f = 2 log10(Re √f) − 0.8
        for _ in 0..<50 { f = pow(2 * log10(re * sqrt(f)) - 0.8, -2) }
        return [("Petukhov (0.790 ln Re − 1.64)^-2", pow(0.790 * log(re) - 1.64, -2)),
                ("Prandtl–Kármán (smooth Colebrook)", f),
                ("Blasius 0.316 Re^-1/4", 0.316 * pow(re, -0.25))]
    }

    public struct PipeCase: Sendable {
        public var mesh: Mesh
        public var setup: CaseSetup
        /// What snappyHexMesh reported for the prism layers.
        public var layers: String?
        /// Stations (x/D) between which the friction factor is measured.
        public var measureFrom: Double
        public var measureTo: Double
    }

    /// Pipe of diameter 1 at bulk velocity 1, 1/7-power inlet profile so the flow develops
    /// within a few diameters. `yPlus` sets the first prism height (nil = tetrahedra only).
    public static func turbulentPipeCase(re: Double = 20000, lengthDiameters L: Double = 10,
                                         wallSize: Double = 0.06, maxSize: Double = 0.1,
                                         yPlus: Double? = 1, growth: Double = 1.25,
                                         model: ViscousModel = .kOmegaSST) throws -> PipeCase {
        var ms = MeshingSettings(template: .pipe(length: L, diameter: 1))
        ms.maxSize = maxSize; ms.wallSize = wallSize; ms.growthDistance = 0.3
        if let yPlus {
            let f = pow(0.790 * log(re) - 1.64, -2)
            let uTau = sqrt(f / 8)
            let h1 = 2 * yPlus / (re * uTau)          // first-cell centre at the requested y+
            ms.blFirstHeight = h1
            ms.blGrowth = growth
            // grow until the last layer is about half the tetrahedron size at the wall
            ms.blLayers = max(3, Int((log(0.5 * wallSize / h1) / log(growth)).rounded(.up)) + 1)
        }
        let gen = try FoamGmsh.generate(ms)
        var s = CaseSetup()
        s.title = String(format: "Turbulent pipe Re=%.0f (%@, %@)", re, model.rawValue, yPlus == nil ? "tetrahedra" : "prism layers")
        s.models.viscous = model
        var fluid = Material(name: "pipe-fluid"); fluid.density = 1; fluid.viscosity = 1 / re
        s.materials.append(fluid)
        s.adopt(mesh: gen.mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "pipe-fluid" }
        var inlet = BoundarySettings(type: .velocityInlet)
        // 1/7 power law with unit bulk velocity: Uc = (n+1)(2n+1)/(2n²) = 120/98
        inlet.velocityMagnitude = Quantity.parse("1.2244898*max(0, 1 - sqrt(y^2 + z^2)/0.5)^(1/7)")
        inlet.turbulenceSpecification = .intensityAndHydraulicDiameter
        inlet.turbulentIntensity = 0.16 * pow(re, -0.125)
        inlet.hydraulicDiameter = 1
        s.boundaries["inlet"] = inlet
        var outlet = BoundarySettings(type: .pressureOutlet)
        outlet.turbulenceSpecification = .intensityAndHydraulicDiameter
        outlet.turbulentIntensity = inlet.turbulentIntensity; outlet.hydraulicDiameter = 1
        s.boundaries["outlet"] = outlet
        s.initialization.method = .standard
        s.initialization.velocity = [1, 0, 0]
        s.methods.coupling = .simplec
        s.methods.momentum = .secondOrderUpwind
        s.controls.urf.pressure = 0.9
        s.controls.urf.momentum = 0.8
        s.residuals.continuity = 1e-5; s.residuals.velocity = 1e-6; s.residuals.turbulence = 1e-6
        s.reference.velocity = 1; s.reference.density = 1; s.reference.length = 1; s.reference.area = Double.pi / 4
        s.run.iterations = 2000
        return PipeCase(mesh: gen.mesh, setup: s, layers: gen.layers, measureFrom: 0.55 * L, measureTo: 0.85 * L)
    }

    public struct PipeFriction: Sendable {
        /// From the axial pressure gradient: f = −dp/dx · D / (½ρU²).
        public var fromPressure: Double
        /// From the mean wall shear: f = 8 τw / (ρU²).
        public var fromShear: Double
        /// Mean y+ of the wall-adjacent cells in the measuring section.
        public var meanYPlus: Double
        public var bulkVelocity: Double
    }

    /// Local friction factors along the pipe: (x, from dp/dx over x ± 0.5, from wall shear over x ± 0.5).
    public static func pipeFrictionProfile(_ solver: Solution, length L: Double) -> [(Double, Double, Double)] {
        stride(from: 1.0, through: L - 1, by: 1.0).map { x in
            let fr = measurePipeFriction(solver, from: x - 0.5, to: x + 0.5)
            return (x, fr.fromPressure, fr.fromShear)
        }
    }

    public static func measurePipeFriction(_ solver: Solution, from x0: Double, to x1: Double) -> PipeFriction {
        let m = solver.mesh
        let p = solver.state.p
        // volume-weighted pressure of a thin slab (linear dp/dx → equals the mid-plane mean)
        func slab(_ x: Double) -> (p: Double, u: Double) {
            var pv = 0.0, uv = 0.0, v = 0.0
            for c in 0..<m.nCells where abs(m.cellCentres[c].x - x) < 0.1 {
                pv += p[c] * m.cellVolumes[c]; uv += solver.state.u[c].x * m.cellVolumes[c]; v += m.cellVolumes[c]
            }
            return (pv / max(v, 1e-300), uv / max(v, 1e-300))
        }
        let a = slab(x0), b = slab(x1)
        let dpdx = (b.p - a.p) / (x1 - x0)
        var tau = 0.0, area = 0.0, yp = 0.0
        if let z = m.zone(named: "wall") {
            for f in z.faceRange where m.faceCentres[f].x > x0 && m.faceCentres[f].x < x1 {
                let bf = f - m.nInternalFaces
                tau += norm(solver.state.bWallShear[bf]) * m.faceAreaMag[f]
                yp += solver.state.bYPlus[bf] * m.faceAreaMag[f]
                area += m.faceAreaMag[f]
            }
        }
        let rho = 1.0, U = 1.0
        return PipeFriction(fromPressure: -dpdx * 1 / (0.5 * rho * U * U), fromShear: 8 * tau / max(area, 1e-300) / (rho * U * U),
                            meanYPlus: yp / max(area, 1e-300), bulkVelocity: 0.5 * (a.u + b.u))
    }
}
