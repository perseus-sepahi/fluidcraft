import Foundation
import CurlewMesh

/// Ready-to-run cases: mesh + setup + what to look at.
public struct Tutorial: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var needsGmsh: Bool
    public var suggestedField: String
    public var build: @Sendable () throws -> (Mesh, CaseSetup)
}

public enum TutorialCatalog {
    public static let all: [Tutorial] = [
        Tutorial(id: "cavity", title: "Lid-Driven Cavity (Re = 1000)",
                 summary: "Laminar 2D cavity, SIMPLEC, second-order upwind. Compare centreline velocities with Ghia et al. (1982).",
                 needsGmsh: false, suggestedField: "velocity-magnitude") {
            var (m, s) = try Benchmarks.cavityCase(re: 1000, cells: 96)
            s.residuals.continuity = 1e-5; s.residuals.velocity = 1e-6; s.run.iterations = 3000
            return (m, s)
        },
        Tutorial(id: "natural-convection", title: "Natural Convection in a Square Cavity (Ra = 10⁵)",
                 summary: "Boussinesq buoyancy with the energy equation; Nusselt number vs de Vahl Davis (1983).",
                 needsGmsh: false, suggestedField: "temperature") {
            let (m, s, _) = try Benchmarks.naturalConvectionCase(log10Ra: 5, cells: 64)
            return (m, s)
        },
        Tutorial(id: "flat-plate", title: "Turbulent Flat Plate (k-ω SST, Re = 5×10⁶)",
                 summary: "Zero-pressure-gradient boundary layer resolved to y⁺ ≈ 0.25; skin friction vs Kármán-Schoenherr.",
                 needsGmsh: false, suggestedField: "turbulent-viscosity-ratio") {
            try Benchmarks.flatPlateCase(model: .kOmegaSST)
        },
        Tutorial(id: "cylinder", title: "Vortex Shedding Behind a Cylinder (Re = 100)",
                 summary: "Transient laminar wake on an O-grid, BDF2; Strouhal number and drag/lift histories.",
                 needsGmsh: false, suggestedField: "vorticity-magnitude") {
            try Benchmarks.cylinderCase(dt: 0.05, endTime: 150)
        },
        Tutorial(id: "backward-step", title: "Backward-Facing Step (k-ω SST)",
                 summary: "Turbulent separation and reattachment downstream of a step (Re_h ≈ 36 000).",
                 needsGmsh: false, suggestedField: "x-velocity") { try backwardStep() },
        Tutorial(id: "cht-chip", title: "Conjugate Heat Transfer: Cooled Chip",
                 summary: "Air flow over a heated aluminium block on a board: coupled conduction and convection.",
                 needsGmsh: false, suggestedField: "temperature") { try chipCooling() },
        Tutorial(id: "porous", title: "Flow Through a Porous Filter",
                 summary: "Channel with a porous cell zone (Darcy + inertial resistance); pressure drop across the filter.",
                 needsGmsh: false, suggestedField: "pressure") { try porousFilter() },
        Tutorial(id: "mixing-tee", title: "Thermal Mixing Tee (3D, transient)",
                 summary: "Hot branch flow enters a cold main duct; unsteady RANS (realizable k-ε) with a scalar tracking the branch fluid and outlet temperature monitors.",
                 needsGmsh: false, suggestedField: "branch-fraction") { try mixingTee() },
        Tutorial(id: "schafer-turek", title: "Cylinder in a Channel (Schäfer-Turek 2D-1)",
                 summary: "Gmsh quad mesh, parabolic inlet from a named expression; drag/lift coefficients vs the benchmark.",
                 needsGmsh: true, suggestedField: "velocity-magnitude") {
            var ms = MeshingSettings(template: .channelCylinder(length: 2.2, height: 0.41, cx: 0.2, cy: 0.2, radius: 0.05))
            ms.maxSize = 0.012; ms.wallSize = 0.0015; ms.growthDistance = 0.3
            ms.blFirstHeight = 0.0004; ms.blGrowth = 1.15; ms.blThickness = 0.008
            let m = try GmshDriver.generate(ms).mesh
            return (m, Benchmarks.schaferTurekSetup(mesh: m))
        },
        Tutorial(id: "naca0012", title: "NACA 0012 Airfoil at 10° (Spalart-Allmaras)",
                 summary: "Gmsh mesh with boundary layer around the airfoil, far field at 30 chords, Re = 6×10⁶.",
                 needsGmsh: true, suggestedField: "pressure-coefficient") { try naca0012() },
        Tutorial(id: "supersonic-ramp", title: "Supersonic Ramp (density-based, Mach 2.5)",
                 summary: "Inviscid Mach 2.5 flow over a 15° compression ramp: Roe flux, MUSCL, characteristic far field; the oblique shock vs theory.",
                 needsGmsh: false, suggestedField: "mach-number") { try Benchmarks.rampCase() },
        Tutorial(id: "sod", title: "Sod Shock Tube (density-based, transient)",
                 summary: "The classic Riemann problem: shock, contact and rarefaction from an exact initial discontinuity.",
                 needsGmsh: false, suggestedField: "density") {
            let (m, s, _) = try Benchmarks.sodCase(cells: 400)
            return (m, s)
        },
        Tutorial(id: "pipe", title: "Laminar Pipe Flow (3D, Re = 100)",
                 summary: "Gmsh tetrahedral pipe; developing flow and pressure drop vs Hagen-Poiseuille.",
                 needsGmsh: true, suggestedField: "velocity-magnitude") { try pipe() },
    ]

    static func setMaterial(_ s: inout CaseSetup, _ mat: Material, zones: [String]? = nil) {
        if !s.materials.contains(where: { $0.name == mat.name }) { s.materials.append(mat) }
        for k in s.cellZones.keys where zones == nil || zones!.contains(k) { s.cellZones[k]!.material = mat.name }
    }

    static func backwardStep() throws -> (Mesh, CaseSetup) {
        let h = 1.0
        let x = BlockAxis(start: -4, segments: [AxisSegment(end: 0, cells: 40, grading: 0.3), AxisSegment(end: 30, cells: 160, grading: 8)])
        let y = BlockAxis(start: 0, segments: [AxisSegment(end: 0.5 * h, cells: 20, grading: 10),
                                               AxisSegment(end: h, cells: 20, grading: 0.1),
                                               AxisSegment(end: 9 * h, cells: 60, grading: 30)])
        let mesh = try BlockMeshSpec(x: x, y: y, depth: 1, obstacles: [[-4, 0, -1, 0, h, 2]], patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [-4, h, -1], boxMax: [-4, 9, 2]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [30, 0, -1], boxMax: [30, 9, 2]),
            PatchRule(name: "top", kind: .symmetry, boxMin: [-4, 9, -1], boxMax: [30, 9, 2]),
        ]).build()
        var s = CaseSetup()
        s.title = "Backward-facing step"
        s.models.viscous = .kOmegaSST
        var fluid = Material(name: "step-fluid"); fluid.density = 1; fluid.viscosity = 1 / 36000
        s.adopt(mesh: mesh); setMaterial(&s, fluid)
        var inlet = BoundarySettings(type: .velocityInlet)
        inlet.velocityMagnitude = 1; inlet.turbulentIntensity = 0.01; inlet.turbulentViscosityRatio = 10
        s.boundaries["inlet"] = inlet
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.7
        s.run.iterations = 3000
        s.reference.velocity = 1; s.reference.density = 1
        return (mesh, s)
    }

    static func chipCooling() throws -> (Mesh, CaseSetup) {
        // 2D channel 0.2 m long, 0.05 m high, chip 0.02 x 0.01 on the floor
        let x = BlockAxis(start: 0, segments: [AxisSegment(end: 0.06, cells: 40, grading: 0.5), AxisSegment(end: 0.08, cells: 24), AxisSegment(end: 0.2, cells: 70, grading: 4)])
        let y = BlockAxis(start: 0, segments: [AxisSegment(end: 0.01, cells: 16), AxisSegment(end: 0.05, cells: 40, grading: 4)])
        let mesh = try BlockMeshSpec(x: x, y: y, depth: 0.01, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.05, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.2, 0, -1], boxMax: [0.2, 0.05, 1]),
            PatchRule(name: "board", kind: .wall, boxMin: [0, 0, -1], boxMax: [0.2, 0, 1]),
            PatchRule(name: "top", kind: .wall, boxMin: [0, 0.05, -1], boxMax: [0.2, 0.05, 1]),
        ], cellZones: [.init(name: "chip", kind: .solid, box: [0.06, 0, -1, 0.08, 0.01, 1])]).build()
        var s = CaseSetup()
        s.title = "Chip cooling (CHT)"
        s.models.viscous = .laminar
        s.models.energy = true
        s.adopt(mesh: mesh)
        s.cellZones["chip"]?.material = "aluminum"
        s.cellZones["chip"]?.energySource = .constant(1e5)   // W/m3: 0.2 W in the 0.02 x 0.01 x 0.01 m chip
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.2; inlet.temperature = 300
        s.boundaries["inlet"] = inlet
        var out = BoundarySettings(type: .pressureOutlet); out.temperature = 300
        s.boundaries["outlet"] = out
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.initialization.method = .hybrid
        s.residuals.energy = 1e-7
        s.run.iterations = 3000
        var tChip = ReportDefinition(name: "max-chip-temperature", kind: .volumeMaximum); tChip.field = "temperature"; tChip.zones = ["chip"]
        var q = ReportDefinition(name: "outlet-heat-rate", kind: .heatTransferRate); q.zones = ["outlet", "inlet"]
        s.reports = [tChip, q]
        return (mesh, s)
    }

    static func porousFilter() throws -> (Mesh, CaseSetup) {
        let x = BlockAxis(from: 0, to: 1, cells: 120)
        let y = BlockAxis(from: 0, to: 0.2, cells: 30)
        let mesh = try BlockMeshSpec(x: x, y: y, depth: 0.05, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, -1], boxMax: [0, 0.2, 1]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [1, 0, -1], boxMax: [1, 0.2, 1]),
        ], cellZones: [.init(name: "filter", kind: .fluid, box: [0.4, -1, -1, 0.5, 1, 1])]).build()
        var s = CaseSetup()
        s.title = "Porous filter"
        s.models.viscous = .laminar
        s.adopt(mesh: mesh)
        var por = PorousSettings(); por.viscousResistance = [1e6, 1e6, 1e6]; por.inertialResistance = [100, 100, 100]
        s.cellZones["filter"]?.porous = por
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.5
        s.boundaries["inlet"] = inlet
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.run.iterations = 1000
        return (mesh, s)
    }

    static func mixingTee() throws -> (Mesh, CaseSetup) {
        // main duct along x (0..0.6) with a branch entering from y- at x = 0.15..0.21
        let x = BlockAxis(start: 0, segments: [AxisSegment(end: 0.15, cells: 20), AxisSegment(end: 0.21, cells: 10), AxisSegment(end: 0.9, cells: 70, grading: 3)])
        let y = BlockAxis(start: -0.15, segments: [AxisSegment(end: 0, cells: 18), AxisSegment(end: 0.06, cells: 12)])
        let z = BlockAxis(from: 0, to: 0.06, cells: 12)
        let mesh = try BlockMeshSpec(x: x, y: y, z: z, obstacles: [[-1, -1, -1, 0.15, 0, 1], [0.21, -1, -1, 2, 0, 1]], patches: [
            PatchRule(name: "inlet-main", kind: .velocityInlet, boxMin: [0, 0, 0], boxMax: [0, 0.06, 0.06]),
            PatchRule(name: "inlet-branch", kind: .velocityInlet, boxMin: [0.15, -0.15, 0], boxMax: [0.21, -0.15, 0.06]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [0.9, 0, 0], boxMax: [0.9, 0.06, 0.06]),
        ]).build()
        var s = CaseSetup()
        s.title = "Mixing tee"
        s.models.viscous = .kEpsilonRealizable
        s.models.energy = true
        s.models.passiveScalars = [PassiveScalar(name: "branch-fraction", diffusivity: 2e-5)]
        s.adopt(mesh: mesh)
        setMaterial(&s, MaterialLibrary.lookup("water-liquid")!)
        var main = BoundarySettings(type: .velocityInlet); main.velocityMagnitude = 0.3; main.temperature = 290
        main.turbulentIntensity = 0.05; main.hydraulicDiameter = 0.06; main.turbulenceSpecification = .intensityAndHydraulicDiameter
        var branch = BoundarySettings(type: .velocityInlet); branch.velocityMagnitude = 0.1; branch.temperature = 330
        branch.turbulentIntensity = 0.05; branch.hydraulicDiameter = 0.06; branch.turbulenceSpecification = .intensityAndHydraulicDiameter
        branch.scalars = ["branch-fraction": 1]
        s.boundaries["inlet-main"] = main
        s.boundaries["inlet-branch"] = branch
        var out = BoundarySettings(type: .pressureOutlet); out.temperature = 300
        s.boundaries["outlet"] = out
        s.general.time = .transient
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.8
        s.methods.transient = .secondOrderImplicit
        s.run.timeStepSize = 0.02
        s.run.numberOfTimeSteps = 200
        s.run.maxIterationsPerTimeStep = 10
        s.run.dataSampling = true
        s.residuals.continuity = 1e-3
        var tOut = ReportDefinition(name: "outlet-temperature", kind: .massWeightedAverage); tOut.field = "temperature"; tOut.zones = ["outlet"]
        var fOut = ReportDefinition(name: "outlet-branch-fraction", kind: .massWeightedAverage); fOut.field = "branch-fraction"; fOut.zones = ["outlet"]
        var tMax = ReportDefinition(name: "max-wall-temperature", kind: .volumeMaximum); tMax.field = "temperature"
        s.reports = [tOut, fOut, tMax]
        return (mesh, s)
    }

    static func naca0012() throws -> (Mesh, CaseSetup) {
        var ms = MeshingSettings(template: .naca4(code: "0012", farfieldRadius: 30))
        ms.maxSize = 2.0; ms.wallSize = 0.004; ms.growthDistance = 8
        ms.blFirstHeight = 2e-6; ms.blGrowth = 1.2; ms.blThickness = 0.03
        ms.quads = true
        let mesh = try GmshDriver.generate(ms).mesh
        var s = CaseSetup()
        s.title = "NACA 0012, alpha = 10 deg"
        s.models.viscous = .spalartAllmaras
        var fluid = Material(name: "airfoil-fluid"); fluid.density = 1; fluid.viscosity = 1 / 6e6
        s.adopt(mesh: mesh); setMaterial(&s, fluid)
        let a = 10.0 * Double.pi / 180
        var ff = BoundarySettings(type: .pressureFarField)
        ff.velocityMagnitude = 1; ff.flowDirection = [cos(a), sin(a), 0]
        ff.turbulenceSpecification = .intensityAndViscosityRatio; ff.turbulentIntensity = 0.001; ff.turbulentViscosityRatio = 3
        s.boundaries["farfield"] = ff
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.6
        s.methods.momentum = .secondOrderUpwind
        s.reference.velocity = 1; s.reference.density = 1; s.reference.length = 1
        s.reference.area = mesh.bounds.size.z
        var cl = ReportDefinition(name: "cl", kind: .liftCoefficient); cl.zones = ["airfoil"]; cl.direction = [-sin(a), cos(a), 0]
        var cd = ReportDefinition(name: "cd", kind: .dragCoefficient); cd.zones = ["airfoil"]; cd.direction = [cos(a), sin(a), 0]
        s.reports = [cl, cd]
        // airfoil boundary layers develop long after the potential-flow start: converge tightly
        s.residuals.continuity = 1e-6; s.residuals.velocity = 1e-7; s.residuals.turbulence = 1e-7
        s.run.iterations = 4000
        return (mesh, s)
    }

    static func pipe() throws -> (Mesh, CaseSetup) {
        var ms = MeshingSettings(template: .pipe(length: 0.5, diameter: 0.05))
        ms.maxSize = 0.006; ms.wallSize = 0.003; ms.growthDistance = 0.02
        let mesh = try GmshDriver.generate(ms).mesh
        var s = CaseSetup()
        s.title = "Laminar pipe Re=100"
        s.models.viscous = .laminar
        var fluid = Material(name: "pipe-fluid"); fluid.density = 1000; fluid.viscosity = 1e-3
        s.adopt(mesh: mesh); setMaterial(&s, fluid)
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = 0.002
        s.boundaries["inlet"] = inlet
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.run.iterations = 600
        return (mesh, s)
    }
}
