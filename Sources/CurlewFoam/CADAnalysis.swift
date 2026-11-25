import Foundation
import CurlewMesh
import CurlewSolver

/// "Import CAD for analysis": from a CAD file (or a sample) and an analysis type, mesh it and
/// build a ready-to-run case — materials, boundary conditions, turbulence model, reference
/// values and report definitions — that OpenFOAM solves.
public struct CADAnalysisSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Body in a wind-tunnel box: drag, lift, force.
        case externalAerodynamics
        /// The body is the fluid volume: pressure drop, mass flow per opening.
        case internalFlow
        /// Solid in an air duct, heated from its base (conjugate heat transfer).
        case conjugateHeatSink

        public var displayName: String {
            switch self {
            case .externalAerodynamics: return "External aerodynamics (drag, lift)"
            case .internalFlow: return "Internal flow (pressure drop)"
            case .conjugateHeatSink: return "Electronics cooling / heat sink (conjugate)"
            }
        }
    }
    public enum Mesher: String, Codable, CaseIterable, Sendable { case gmsh, snappyHexMesh }
    public enum Level: String, Codable, CaseIterable, Sendable { case coarse, medium, fine }

    public var path = ""
    public var unit: CADUnit = .metre
    /// Use the length unit a STEP file declares (SolidWorks, SolidCraft and most CAD systems
    /// write millimetres) instead of `unit`, when it declares one.
    public var unitFromFile = true
    public var kind: Kind = .externalAerodynamics
    public var flowAxis = 0
    public var speed = 10.0
    public var fluid = "air"
    public var solid = "aluminum"
    /// Heat load into the solid [W] (conjugate), through its base face.
    public var heatLoad = 10.0
    public var inletTemperature = 300.0
    public var mesher: Mesher = .gmsh
    public var level: Level = .medium
    public var prismLayers = true
    // Region of interest
    /// Flow domain around the body, in body lengths: upstream, downstream, beside (each side),
    /// below, above. Used for external aerodynamics and the conjugate duct.
    public var domainMargins: [Double]? = nil
    /// The body stands on the ground: no margin below; the floor is a wall named `ground`.
    public var onGround = false
    /// The ground moves with the free stream (road vehicles, wind-tunnel rolling road).
    public var movingGround = false
    /// A region meshed finer: [xmin, ymin, zmin, xmax, ymax, zmax] in metres (after units); nil = none.
    public var refinementBox: [Double]? = nil
    /// Cell size in the refinement region [m]; 0 = twice the wall cell size.
    public var refinementSize = 0.0
    public var cores = 1
    /// Native-format converter command (not saved).
    public var converter = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case path, unit, kind, flowAxis, speed, fluid, solid, heatLoad, inletTemperature, mesher, level, prismLayers, cores
        case domainMargins, onGround, movingGround, refinementBox, refinementSize, unitFromFile
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = CADAnalysisSpec()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? def.path
        unit = (try? c.decodeIfPresent(CADUnit.self, forKey: .unit)) ?? def.unit
        unitFromFile = try c.decodeIfPresent(Bool.self, forKey: .unitFromFile) ?? true
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? def.kind
        flowAxis = try c.decodeIfPresent(Int.self, forKey: .flowAxis) ?? def.flowAxis
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? def.speed
        fluid = try c.decodeIfPresent(String.self, forKey: .fluid) ?? def.fluid
        solid = try c.decodeIfPresent(String.self, forKey: .solid) ?? def.solid
        heatLoad = try c.decodeIfPresent(Double.self, forKey: .heatLoad) ?? def.heatLoad
        inletTemperature = try c.decodeIfPresent(Double.self, forKey: .inletTemperature) ?? def.inletTemperature
        mesher = (try? c.decodeIfPresent(Mesher.self, forKey: .mesher)) ?? def.mesher
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? def.level
        prismLayers = try c.decodeIfPresent(Bool.self, forKey: .prismLayers) ?? def.prismLayers
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? def.cores
        domainMargins = try c.decodeIfPresent([Double].self, forKey: .domainMargins)
        onGround = try c.decodeIfPresent(Bool.self, forKey: .onGround) ?? false
        movingGround = try c.decodeIfPresent(Bool.self, forKey: .movingGround) ?? false
        refinementBox = try c.decodeIfPresent([Double].self, forKey: .refinementBox)
        refinementSize = try c.decodeIfPresent(Double.self, forKey: .refinementSize) ?? 0
    }

    /// Default domain margins in body lengths (upstream, downstream, beside, below, above).
    public static func defaultMargins(_ k: Kind) -> [Double] { k == .conjugateHeatSink ? [1, 2, 0.5, 0, 1] : [3, 8, 3, 3, 3] }

    /// Box padding per axis (-x, +x, -y, +y, -z, +z) from the margins, with the flow along
    /// `flowAxis` and the ground below along `groundAxis`.
    public func padding(groundAxis ga: Int) -> [Double] {
        let m = (domainMargins?.count == 5 ? domainMargins! : CADAnalysisSpec.defaultMargins(kind)).map { max(0, $0) }
        let ax = max(0, min(2, flowAxis)), side = 3 - ax - ga
        var p = [Double](repeating: 0, count: 6)
        p[2 * ax] = m[0]; p[2 * ax + 1] = m[1]
        p[2 * side] = m[2]; p[2 * side + 1] = m[2]
        p[2 * ga] = (onGround || kind == .conjugateHeatSink) ? 0 : m[3]; p[2 * ga + 1] = m[4]
        return p
    }

    /// Spec pre-filled for a sample model.
    public static func sample(_ s: CADSample, path: String) -> CADAnalysisSpec {
        var spec = CADAnalysisSpec()
        spec.path = path
        let sg = s.suggested
        spec.kind = sg.analysis == .external ? .externalAerodynamics : (sg.analysis == .internalFlow ? .internalFlow : .conjugateHeatSink)
        spec.flowAxis = sg.flowAxis
        spec.speed = sg.speed
        spec.fluid = sg.fluid
        return spec
    }
}

public enum CADAnalysis {
    public struct Result: Sendable {
        public var mesh: Mesh
        public var setup: CaseSetup
        public var summary: String
    }

    /// Mesh the CAD and build the case. snappyHexMesh needs `environment`; work files go to `workDir`.
    public static func build(_ spec: CADAnalysisSpec, workDir: URL, environment: FoamEnvironment? = nil,
                             log: @escaping (String) -> Void) throws -> Result {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // 1. Size the problem from the geometry
        let path = try CADConversion.prepare(spec.path, converter: spec.converter.isEmpty ? CADConversion.defaultConverter : spec.converter,
                                             workDir: workDir.appendingPathComponent("convert"))
        var spec = spec
        if spec.unitFromFile, let u = CADConversion.declaredUnit(path), u != spec.unit {
            log("\((path as NSString).lastPathComponent) declares \(u.rawValue): using it (untick “Use the file's units” to override).\n")
            spec.unit = u
        }
        guard let fmt = CADFormat.detect(URL(fileURLWithPath: path)) else { throw MeshError.unsupported("unknown CAD format") }
        let probe = fmt.isBRep
            ? try GmshDriver.tessellate(path: path, unit: spec.unit, minSize: 1e-9, maxSize: 1e9, workDir: workDir.appendingPathComponent("probe"))
            : try SurfaceReader.read(url: URL(fileURLWithPath: path), unit: spec.unit)
        let (lo, hi) = probe.bounds
        let ext = hi - lo
        let L = max(ext.x, ext.y, ext.z)
        guard L > 0 else { throw MeshError.topology("the CAD model has zero size") }
        let ax = max(0, min(2, spec.flowAxis))
        guard let fluid = MaterialLibrary.lookup(spec.fluid) else { throw SolverError("unknown fluid material \(spec.fluid)") }
        // characteristic length: body length (external, conjugate) or inlet hydraulic diameter (internal)
        let openings = spec.kind == .internalFlow ? probe.detectOpenings(flowAxis: ax) : []
        let inlet = openings.first { $0.name == "inlet" } ?? openings.first
        let D = inlet.map { sqrt(4 * $0.area / .pi) } ?? min(ext[(ax + 1) % 3], ext[(ax + 2) % 3])
        let lengthScale = spec.kind == .internalFlow ? D : L
        let reynolds = fluid.density * spec.speed * lengthScale / fluid.viscosity
        let turbulent = spec.kind == .internalFlow ? reynolds > 2300 : reynolds > 5e4
        let f = ["coarse": 0.6, "medium": 1.0, "fine": 1.7][spec.level.rawValue]!
        log(String(format: "Model %.4g × %.4g × %.4g m; Re = %.3g (%@)%@\n", ext.x, ext.y, ext.z, reynolds,
                   turbulent ? "turbulent, k-ω SST" : "laminar",
                   openings.isEmpty ? "" : "; openings " + openings.map(\.name).joined(separator: ", ")))

        // 2. Mesh
        var mesh: Mesh
        switch spec.mesher {
        case .snappyHexMesh:
            guard spec.kind != .conjugateHeatSink else {
                throw MeshError.unsupported("conjugate heat transfer from CAD is meshed with Gmsh (fluid and solid sharing faces)")
            }
            guard let env = environment else { throw FoamSolveError.noInstallation }
            var sn = SnappySettings()
            sn.path = path; sn.unit = spec.unit; sn.external = spec.kind == .externalAerodynamics; sn.flowAxis = ax
            sn.surfaceLevelMax = spec.level == .fine ? 5 : (spec.level == .coarse ? 3 : 4)
            sn.surfaceLevelMin = sn.surfaceLevelMax - 1
            sn.featureLevel = sn.surfaceLevelMax
            sn.layers = spec.prismLayers ? 3 : 0
            sn.cores = max(1, spec.cores)
            if sn.external { sn.padding = spec.padding(groundAxis: ax == 2 ? 1 : 2) }
            if let rb = spec.refinementBox, rb.count == 6 { sn.customRefinementBox = rb; sn.refinementBoxLevel = max(sn.refinementBoxLevel, sn.surfaceLevelMin) }
            let r = try SnappyMesher.mesh(sn, workDir: workDir.appendingPathComponent("snappy"), environment: env, log: log)
            log(r.summary + "\n")
            mesh = r.mesh
        case .gmsh:
            var ms: MeshingSettings
            switch spec.kind {
            case .externalAerodynamics:
                ms = MeshingSettings(template: .cad(path: path, external: true, flowAxis: ax, padding: spec.padding(groundAxis: ax == 2 ? 1 : 2)))
                ms.maxSize = L / (4 * f); ms.wallSize = L / (40 * f); ms.growthDistance = 1.5 * L
                if spec.onGround { ms.groundAxis = ax == 2 ? 1 : 2 }
            case .internalFlow:
                ms = MeshingSettings(template: .cad(path: path, external: false, flowAxis: ax, padding: []))
                ms.maxSize = D / (6 * f); ms.wallSize = D / (10 * f); ms.growthDistance = D
            case .conjugateHeatSink:
                ms = MeshingSettings(template: .cadConjugate(path: path, flowAxis: ax, baseAxis: ax == 2 ? 1 : 2, padding: spec.padding(groundAxis: ax == 2 ? 1 : 2)))
                // fine enough for thin fins: a few cells across the smallest wall thickness is the user's call; this resolves ~1/50 of the body
                ms.maxSize = L / (6 * f); ms.wallSize = L / (50 * f); ms.growthDistance = 0.5 * L
            }
            ms.cadUnit = spec.unit
            if let rb = spec.refinementBox, rb.count == 6 {
                ms.refinementBoxes = [RefinementBox(min: Array(rb[0..<3]), max: Array(rb[3..<6]), size: spec.refinementSize > 0 ? spec.refinementSize : 2 * ms.wallSize)]
            }
            if spec.prismLayers && spec.kind != .conjugateHeatSink {
                let e = WallSpacing.estimate(yPlus: turbulent ? 1 : 0.5, velocity: spec.speed, length: lengthScale, density: fluid.density, viscosity: fluid.viscosity)
                ms.blFirstHeight = min(e.firstHeight, ms.wallSize / 10)
                // last layer ≈ half the wall cell size: fixed layer count, growth chosen to reach it
                let n = 12
                ms.blLayers = n
                ms.blGrowth = min(1.35, max(1.1, pow(0.5 * ms.wallSize / ms.blFirstHeight, 1 / Double(n - 1))))
            }
            var r = try GmshDriver.generate(ms, workDir: workDir.appendingPathComponent("gmsh"), log: { _ in })
            if let layers = ms.inflation3D {
                // prism layers by snappyHexMesh's layer addition on the Gmsh tetrahedra; where it
                // cannot add them (sharp edges, a body on the ground) the mesh stays tetrahedral
                do {
                    let env = try FoamLocations.installation(for: CaseSetup()).resolve()
                    let added = try FoamLayers.add(to: r.mesh, settings: layers, environment: env, log: { log($0 + "\n") })
                    let q = MeshQuality.report(added.mesh)
                    if q.negativeVolumes > 0 || q.invertedFacePyramids > 0 {
                        log("The layered mesh has \(q.invertedFacePyramids) inverted face pyramids; keeping the tetrahedra without layers.\n")
                    } else {
                        r.mesh = added.mesh
                        log(added.summary + "\n")
                    }
                } catch {
                    log("Prism layers could not be added (\(error)); meshing without layers.\n")
                }
            }
            mesh = r.mesh
        }
        log("Mesh: \(mesh.summary)\n")

        // 3. Case
        var s = CaseSetup()
        s.title = URL(fileURLWithPath: spec.path).deletingPathExtension().lastPathComponent + "-" + spec.kind.rawValue
        s.models.viscous = turbulent ? .kOmegaSST : .laminar
        s.adopt(mesh: mesh)
        var flowDir = [0.0, 0, 0]; flowDir[ax] = 1
        for (name, _) in s.cellZones { s.cellZones[name]!.material = spec.fluid; s.cellZones[name]!.kind = .fluid }
        s.initialization.method = .hybrid
        s.methods.coupling = .simplec
        s.controls.urf.pressure = 1
        s.reference.velocity = spec.speed
        s.reference.density = fluid.density
        s.reference.viscosity = fluid.viscosity
        for z in mesh.boundaryZones {
            var b = s.boundaries[z.name] ?? BoundarySettings(type: z.kind)
            switch z.name {
            case "inlet":
                b.type = .velocityInlet; b.velocityMagnitude = .constant(spec.speed)
                b.turbulentIntensity = 0.02; b.temperature = .constant(spec.inletTemperature)
            case let n where n.hasPrefix("outlet"):
                b.type = .pressureOutlet; b.temperature = .constant(spec.inletTemperature)
            case "farfield":
                // wind-tunnel walls far away: slip (symmetry) rather than a far-field condition
                b.type = .symmetry
            case "ground":
                b.type = .wall
                if spec.movingGround {
                    // rolling road: the floor moves with the free stream
                    b.wallMotion = .moving
                    var v: [Quantity] = [0, 0, 0]; v[ax] = .constant(spec.speed); b.wallVelocity = v
                }
            default:
                if z.kind != .empty && z.kind != .symmetry { b.type = .wall }
            }
            s.boundaries[z.name] = b
        }
        // mesh zone kinds follow the setup
        for (i, z) in mesh.boundaryZones.enumerated() { if let t = s.boundaries[z.name]?.type, t != z.kind { mesh.updateBoundaryZone(i, kind: t) } }
        var reports: [ReportDefinition] = []
        let bodyPatches = mesh.boundaryZones.filter { $0.kind == .wall && $0.name != "ground" }.map(\.name)   // the floor is not part of the body
        switch spec.kind {
        case .externalAerodynamics:
            // lift acts across the body's thinnest cross-flow direction (z by default)
            let a1 = (ax + 1) % 3, a2 = (ax + 2) % 3
            var upAxis = ax == 2 ? 1 : 2
            let other = upAxis == a1 ? a2 : a1
            if ext[other] < 0.5 * ext[upAxis] { upAxis = other }
            // slender lifting body (wing, blade, fin): planform area and chord, as for aerofoil
            // coefficients; bluff body: frontal area. Both are half the surface projected on
            // the normal (exact for convex bodies).
            let lifting = ext[upAxis] < 0.2 * ext[ax]
            var n = Vec3(0, 0, 0); n[lifting ? upAxis : ax] = 1
            var proj = 0.0
            for t in 0..<probe.triangleCount { let (a, b, c) = probe.corners(t); proj += 0.5 * abs(dot(cross(b - a, c - a), n)) * 0.5 }
            s.reference.area = max(proj, 1e-12)
            s.reference.length = ext[ax]
            log(String(format: "Reference: %@ area %.4g m², length %.4g m; lift along %@\n", lifting ? "planform" : "frontal",
                       s.reference.area, s.reference.length, ["x", "y", "z"][upAxis]))
            var cd = ReportDefinition(name: "drag-coefficient", kind: .dragCoefficient); cd.zones = bodyPatches; cd.direction = flowDir
            var up = [0.0, 0, 0]; up[upAxis] = 1
            var cl = ReportDefinition(name: "lift-coefficient", kind: .liftCoefficient); cl.zones = bodyPatches; cl.direction = up
            var fd = ReportDefinition(name: "drag-force", kind: .force); fd.zones = bodyPatches; fd.direction = flowDir
            reports = [cd, cl, fd]
            s.run.iterations = 800
        case .internalFlow:
            for z in mesh.boundaryZones where z.name == "inlet" || z.name.hasPrefix("outlet") {
                var mf = ReportDefinition(name: "mass-flow-\(z.name)", kind: .massFlowRate); mf.zones = [z.name]
                reports.append(mf)
            }
            var dp = ReportDefinition(name: "inlet-pressure", kind: .areaWeightedAverage); dp.zones = ["inlet"]; dp.field = "pressure"
            reports.append(dp)
            s.reference.length = D; s.reference.area = .pi * D * D / 4
            s.run.iterations = 800
        case .conjugateHeatSink:
            s.models.energy = true
            for z in mesh.cellZones where z.kind == .solid {
                s.cellZones[z.name]!.kind = .solid; s.cellZones[z.name]!.material = spec.solid
            }
            if let base = mesh.zone(named: "base") {
                let area = base.faceRange.reduce(0.0) { $0 + mesh.faceAreaMag[$1] }
                var b = s.boundaries["base"]!
                b.type = .wall; b.thermalCondition = .heatFlux; b.heatFlux = .constant(spec.heatLoad / max(area, 1e-12))
                s.boundaries["base"] = b
                log(String(format: "Heat load %.4g W on the base (%.4g mm², %.4g W/m²)\n", spec.heatLoad, area * 1e6, spec.heatLoad / max(area, 1e-12)))
            } else if let sz = mesh.cellZones.first(where: { $0.kind == .solid }) {
                var vol = 0.0
                for c in 0..<mesh.nCells where mesh.cellZones[Int(mesh.cellZone[c])].name == sz.name { vol += mesh.cellVolumes[c] }
                s.cellZones[sz.name]!.energySource = .constant(spec.heatLoad / max(vol, 1e-300))
                log("No base face on the floor: the heat load is a volumetric source in the solid.\n")
            }
            s.initialization.temperature = .constant(spec.inletTemperature)
            var tmax = ReportDefinition(name: "max-solid-temperature", kind: .volumeMaximum); tmax.field = "temperature"
            tmax.zones = mesh.cellZones.filter { $0.kind == .solid }.map(\.name)
            var tb = ReportDefinition(name: "base-temperature", kind: .areaWeightedAverage); tb.field = "temperature"; tb.zones = ["base"]
            var q = ReportDefinition(name: "heat-to-air", kind: .heatTransferRate); q.zones = ["inlet", "outlet"]
            var dp = ReportDefinition(name: "inlet-pressure", kind: .areaWeightedAverage); dp.zones = ["inlet"]
            reports = [tmax, tb, q, dp]
            s.run.iterations = 2000
            s.residuals.energy = 1e-8
        }
        s.reports = reports
        s.openfoam.cores = max(1, spec.cores)
        s.includeReferencedLibraryMaterials()
        return Result(mesh: mesh, setup: s, summary: "\(spec.kind.displayName): \(mesh.nCells) cells, \(s.models.viscous.displayName), Re = \(String(format: "%.3g", reynolds))")
    }
}
