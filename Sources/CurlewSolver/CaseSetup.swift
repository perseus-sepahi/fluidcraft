import Foundation
import CurlewMesh
import CurlewLinear

// MARK: - General

public enum SolverType: String, Codable, CaseIterable, Sendable { case pressureBased = "pressure-based", densityBased = "density-based" }
public enum TimeMode: String, Codable, CaseIterable, Sendable { case steady, transient }

public struct GeneralSettings: Codable, Sendable, Equatable {
    public var solver: SolverType = .pressureBased
    public var time: TimeMode = .steady
    public var gravityEnabled = false
    public var gravity: [Double] = [0, -9.81, 0]
    /// Absolute pressure = operating pressure + gauge pressure.
    public var operatingPressure = 101325.0
    /// Reference temperature for Boussinesq buoyancy.
    public var operatingTemperature = 288.16
    /// Density removed from the body-force term (nil: use the fluid density).
    public var operatingDensity: Double? = nil
    public var referencePressureLocation: [Double] = [0, 0, 0]
    public init() {}
}

// MARK: - Models

public enum ViscousModel: String, Codable, CaseIterable, Sendable {
    case inviscid
    case laminar
    case spalartAllmaras = "spalart-allmaras"
    case kEpsilonStandard = "k-epsilon-standard"
    case kEpsilonRealizable = "k-epsilon-realizable"
    case kOmegaSST = "k-omega-sst"

    public var displayName: String {
        switch self {
        case .inviscid: return "Inviscid"
        case .laminar: return "Laminar"
        case .spalartAllmaras: return "Spalart-Allmaras (1 eqn)"
        case .kEpsilonStandard: return "k-epsilon Standard (2 eqn)"
        case .kEpsilonRealizable: return "k-epsilon Realizable (2 eqn)"
        case .kOmegaSST: return "k-omega SST (2 eqn)"
        }
    }
    public var isTurbulent: Bool { ![.inviscid, .laminar].contains(self) }
    public var usesOmega: Bool { self == .kOmegaSST }
    public var usesEpsilon: Bool { self == .kEpsilonStandard || self == .kEpsilonRealizable }
}

public enum WallTreatment: String, Codable, CaseIterable, Sendable {
    /// Blended (Reichardt) law valid from y+ ~ 1 to the log layer.
    case automatic
    case standardWallFunctions = "standard-wall-functions"
}

public struct Models: Codable, Sendable, Equatable {
    public var viscous: ViscousModel = .laminar
    public var wallTreatment: WallTreatment = .automatic
    public var energy = false
    /// Turbulent Prandtl number for energy.
    public var turbulentPrandtl = 0.85
    /// Passive scalars (user-defined scalars) transported with the flow.
    public var passiveScalars: [PassiveScalar] = []
    public init() {}
}

public struct PassiveScalar: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var diffusivity: Double = 1e-5
    public var turbulentSchmidt = 0.7
    public init(name: String, diffusivity: Double = 1e-5) { self.name = name; self.diffusivity = diffusivity }
}

// MARK: - Materials

public enum DensityMethod: String, Codable, CaseIterable, Sendable {
    case constant
    /// Constant density in all terms except buoyancy: rho = rho0 (1 - beta (T - T0)).
    case boussinesq
    /// rho = p_op / (R T), independent of pressure changes.
    case incompressibleIdealGas = "incompressible-ideal-gas"
    /// rho = (p_op + p) / (R T) (density-based solver).
    case idealGas = "ideal-gas"
}

public enum ViscosityMethod: String, Codable, CaseIterable, Sendable {
    case constant, sutherland
    /// Non-Newtonian power law: mu = k * gammaDot^(n-1), clipped to [muMin, muMax].
    case powerLaw = "power-law"
}

public struct Material: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var kind: CellZoneKind = .fluid
    public var densityMethod: DensityMethod = .constant
    public var density = 1.225
    public var viscosityMethod: ViscosityMethod = .constant
    public var viscosity = 1.7894e-5
    public var sutherlandT0 = 273.11
    public var sutherlandS = 110.56
    public var powerLawK = 1.0
    public var powerLawN = 1.0
    public var powerLawMin = 1e-5
    public var powerLawMax = 1e3
    public var specificHeat = 1006.43
    public var thermalConductivity = 0.0242
    public var thermalExpansion = 3.4e-3
    public var molecularWeight = 28.966
    public init(name: String) { self.name = name }

    public var gasConstant: Double { 8314.462618 / molecularWeight }
}

// MARK: - Cell zones

public struct PorousSettings: Codable, Sendable, Equatable {
    /// Inverse permeability 1/alpha [1/m2] per direction (viscous resistance).
    public var viscousResistance: [Double] = [0, 0, 0]
    /// Inertial resistance C2 [1/m] per direction.
    public var inertialResistance: [Double] = [0, 0, 0]
    public var porosity = 1.0
    public init() {}
}

public struct CellZoneSettings: Codable, Sendable, Equatable {
    public var kind: CellZoneKind = .fluid
    public var material: String = "air"
    public var porous: PorousSettings? = nil
    /// Volumetric sources (per m3): energy [W/m3], momentum [N/m3].
    public var energySource: Quantity = 0
    public var momentumSource: [Quantity] = [0, 0, 0]
    /// Moving reference frame (MRF): rotation speed [rad/s] about axis through origin.
    public var frameMotion = false
    public var rotationAxisOrigin: [Double] = [0, 0, 0]
    public var rotationAxisDirection: [Double] = [0, 0, 1]
    public var rotationSpeed = 0.0
    public init() {}
}

// MARK: - Boundary conditions

public enum VelocitySpecification: String, Codable, CaseIterable, Sendable {
    case magnitudeNormal = "magnitude-normal"
    case components
}
public enum ThermalCondition: String, Codable, CaseIterable, Sendable {
    case temperature
    case heatFlux = "heat-flux"
    case convection
    /// Shorthand for zero heat flux.
    case adiabatic
}
public enum TurbulenceSpecification: String, Codable, CaseIterable, Sendable {
    case intensityAndLengthScale = "intensity-and-length-scale"
    case intensityAndViscosityRatio = "intensity-and-viscosity-ratio"
    case intensityAndHydraulicDiameter = "intensity-and-hydraulic-diameter"
    case direct = "k-and-omega"
}
public enum WallMotion: String, Codable, CaseIterable, Sendable { case stationary, moving, rotating }
public enum ShearCondition: String, Codable, CaseIterable, Sendable {
    case noSlip = "no-slip"
    /// Zero shear stress (slip wall).
    case specifiedShear = "specified-shear"
}

public struct BoundarySettings: Codable, Sendable, Equatable {
    public var type: ZoneKind
    // Velocity / mass-flow inlet
    public var velocitySpecification: VelocitySpecification = .magnitudeNormal
    public var velocityMagnitude: Quantity = 1
    public var velocity: [Quantity] = [1, 0, 0]
    public var massFlowRate: Quantity = 1
    // Pressure inlet (total) / outlet (static), gauge
    public var gaugePressure: Quantity = 0
    // Thermal
    public var thermalCondition: ThermalCondition = .adiabatic
    public var temperature: Quantity = 300
    public var heatFlux: Quantity = 0
    public var heatTransferCoefficient: Quantity = 10
    public var freeStreamTemperature: Quantity = 300
    // Wall
    public var wallMotion: WallMotion = .stationary
    public var wallVelocity: [Quantity] = [0, 0, 0]
    public var rotationAxisOrigin: [Double] = [0, 0, 0]
    public var rotationAxisDirection: [Double] = [0, 0, 1]
    public var rotationSpeed = 0.0
    public var shearCondition: ShearCondition = .noSlip
    // Turbulence (inlets and backflow)
    public var turbulenceSpecification: TurbulenceSpecification = .intensityAndViscosityRatio
    public var turbulentIntensity = 0.05
    public var turbulentLengthScale = 0.01
    public var hydraulicDiameter = 0.1
    public var turbulentViscosityRatio = 10.0
    public var k = 1e-3
    public var omega = 1.0
    public var epsilon = 1e-4
    public var modifiedTurbulentViscosity = 1e-4
    // Far field / density-based
    public var machNumber = 0.6
    public var flowDirection: [Double] = [1, 0, 0]
    // Passive scalar values at inlets (by scalar name)
    public var scalars: [String: Double] = [:]

    public init(type: ZoneKind) { self.type = type }
}

// MARK: - Methods & controls

public enum PVCoupling: String, Codable, CaseIterable, Sendable { case simple = "SIMPLE", simplec = "SIMPLEC", piso = "PISO" }
public enum GradientScheme: String, Codable, CaseIterable, Sendable {
    case leastSquares = "least-squares-cell-based"
    case greenGauss = "green-gauss-cell-based"
}
public enum PressureInterpolation: String, Codable, CaseIterable, Sendable {
    case standard, secondOrder = "second-order", bodyForceWeighted = "body-force-weighted", linear
}
public enum ConvectionScheme: String, Codable, CaseIterable, Sendable {
    case firstOrderUpwind = "first-order-upwind"
    case secondOrderUpwind = "second-order-upwind"
    case central = "central-differencing"
    case boundedCentral = "bounded-central-differencing"
    case quick = "QUICK"
    case muscl = "third-order-MUSCL"

    public var displayName: String {
        switch self {
        case .firstOrderUpwind: return "First Order Upwind"
        case .secondOrderUpwind: return "Second Order Upwind"
        case .central: return "Central Differencing"
        case .boundedCentral: return "Bounded Central Differencing"
        case .quick: return "QUICK"
        case .muscl: return "Third-Order MUSCL"
        }
    }
}
public enum TransientFormulation: String, Codable, CaseIterable, Sendable {
    case firstOrderImplicit = "first-order-implicit"
    case secondOrderImplicit = "second-order-implicit"
}

public struct SolutionMethods: Codable, Sendable, Equatable {
    public var coupling: PVCoupling = .simple
    public var gradient: GradientScheme = .leastSquares
    public var pressure: PressureInterpolation = .secondOrder
    public var momentum: ConvectionScheme = .secondOrderUpwind
    /// Fluent's default for k/omega/epsilon is first-order upwind.
    public var turbulence: ConvectionScheme = .firstOrderUpwind
    public var energy: ConvectionScheme = .secondOrderUpwind
    public var scalars: ConvectionScheme = .secondOrderUpwind
    public var transient: TransientFormulation = .secondOrderImplicit
    /// Extra pressure-correction solves per iteration on non-orthogonal meshes.
    public var nonOrthogonalCorrectors = 0
    /// Limit higher-order face values (momentum, energy) to the range of the two adjacent cells:
    /// keeps temperatures bounded and improves convergence on coarse meshes.
    public var limitMomentum = true
    /// Include the transpose part of the viscous stress, div(mu_eff (grad u)^T), for turbulent
    /// viscosity. It changes typical RANS results by well under 1 % but slows convergence of
    /// separated flows; it is always included for variable molecular viscosity.
    public var transposeStress = false
    /// Non-orthogonal correction limiter psi (OpenFOAM "limited corrected"): the explicit
    /// correction is capped at psi/(1-psi) times the orthogonal part. 1 = fully corrected,
    /// 0 = uncorrected; nil = automatic from the mesh's maximum non-orthogonality.
    public var nonOrthogonalLimit: Double? = nil
    /// Pressure force from a conservative (skewness-corrected Green–Gauss) gradient when the
    /// gradient scheme is least squares, so the pressure force on any region equals the
    /// pressure integral over its boundary. Off reproduces the plain least-squares source.
    public var conservativePressureGradient = true
    /// PISO neighbour corrections.
    public var pisoCorrectors = 1
    // Density-based
    public var flux: FluxScheme = .roe
    public var courantNumber = 1.0
    public init() {}
}

public enum FluxScheme: String, Codable, CaseIterable, Sendable { case roe = "roe-fds", ausm = "AUSM" }

public struct UnderRelaxation: Codable, Sendable, Equatable {
    public var pressure = 0.3
    public var density = 1.0
    public var bodyForces = 1.0
    public var momentum = 0.7
    public var turbulentKineticEnergy = 0.8
    public var specificDissipationRate = 0.8
    public var dissipationRate = 0.8
    public var modifiedTurbulentViscosity = 0.8
    public var turbulentViscosity = 1.0
    public var energy = 1.0
    public var scalars = 1.0
    public init() {}
}

public struct SolutionLimits: Codable, Sendable, Equatable {
    public var minimumTemperature = 1.0
    public var maximumTemperature = 5000.0
    public var minimumK = 1e-14
    public var minimumOmega = 1e-20
    public var minimumEpsilon = 1e-20
    public var maximumViscosityRatio = 1e5
    public init() {}
}

public struct LinearControls: Codable, Sendable, Equatable {
    public var pressure = LinearSolverSettings.pressure
    public var momentum = LinearSolverSettings.transport
    public var turbulence = LinearSolverSettings.transport
    public var energy = LinearSolverSettings(method: .amgBiCGStab, cycle: .v, relTol: 0.05, maxIterations: 50)
    public var scalars = LinearSolverSettings.transport
    /// Use the Metal GPU linear-solver backend when available.
    public var useGPU = false
    public init() {}
}

public struct SolutionControls: Codable, Sendable, Equatable {
    public var urf = UnderRelaxation()
    public var limits = SolutionLimits()
    public var linear = LinearControls()
    public init() {}
}

// MARK: - Monitors & reports

public struct ResidualCriteria: Codable, Sendable, Equatable {
    public var continuity = 1e-3
    public var velocity = 1e-3
    public var energy = 1e-6
    public var turbulence = 1e-3
    public var scalars = 1e-5
    public var checkConvergence = true
    public init() {}
}

public enum ReportKind: String, Codable, CaseIterable, Sendable {
    case areaWeightedAverage = "area-weighted-average"
    case massWeightedAverage = "mass-weighted-average"
    case integral
    case massFlowRate = "mass-flow-rate"
    case volumeAverage = "volume-average"
    case volumeMaximum = "volume-maximum"
    case volumeMinimum = "volume-minimum"
    case force
    case dragCoefficient = "drag-coefficient"
    case liftCoefficient = "lift-coefficient"
    case momentCoefficient = "moment-coefficient"
    case heatTransferRate = "heat-transfer-rate"
    case expression

    public var displayName: String {
        switch self {
        case .areaWeightedAverage: return "Surface: Area-Weighted Average"
        case .massWeightedAverage: return "Surface: Mass-Weighted Average"
        case .integral: return "Surface: Integral"
        case .massFlowRate: return "Surface: Mass Flow Rate"
        case .volumeAverage: return "Volume: Average"
        case .volumeMaximum: return "Volume: Maximum"
        case .volumeMinimum: return "Volume: Minimum"
        case .force: return "Force"
        case .dragCoefficient: return "Drag Coefficient"
        case .liftCoefficient: return "Lift Coefficient"
        case .momentCoefficient: return "Moment Coefficient"
        case .heatTransferRate: return "Total Heat Transfer Rate"
        case .expression: return "Expression"
        }
    }
}

public struct ReportDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var kind: ReportKind
    /// Field name for surface/volume reports (e.g. "pressure", "velocity-magnitude").
    public var field = "pressure"
    /// Boundary zones (surface reports, forces) or cell zones (volume reports); empty = all.
    public var zones: [String] = []
    /// Force direction or moment axis.
    public var direction: [Double] = [1, 0, 0]
    public var momentCentre: [Double] = [0, 0, 0]
    public var expression = ""
    public var plot = true
    public var print = true
    public init(name: String, kind: ReportKind) { self.name = name; self.kind = kind }
}

public struct ReferenceValues: Codable, Sendable, Equatable {
    public var area = 1.0
    public var length = 1.0
    public var velocity = 1.0
    public var density = 1.225
    public var pressure = 0.0
    public var temperature = 288.16
    public var viscosity = 1.7894e-5
    public init() {}
}

// MARK: - Initialization & run

public enum InitializationMethod: String, Codable, CaseIterable, Sendable { case hybrid, standard }

public enum PatchRegion: String, Codable, CaseIterable, Sendable { case box, sphere, cylinder }

public struct PatchSettings: Codable, Sendable, Equatable {
    public var region: PatchRegion = .box
    /// Box: [xmin,ymin,zmin,xmax,ymax,zmax]; sphere: [cx,cy,cz,r]; cylinder: [x0,y0,z0,x1,y1,z1,r].
    public var parameters: [Double] = []
    public var field = "temperature"
    public var value: Quantity = 0
    public init() {}
}

public struct InitializationSettings: Codable, Sendable, Equatable {
    public var method: InitializationMethod = .hybrid
    /// Standard initialization: compute defaults from this boundary zone (empty: use values below).
    public var computeFrom = ""
    public var gaugePressure: Quantity = 0
    public var velocity: [Quantity] = [0, 0, 0]
    public var temperature: Quantity = 300
    public var k = 1e-3
    public var omega = 1.0
    public var epsilon = 1e-4
    public var modifiedTurbulentViscosity = 1e-4
    public var hybridIterations = 10
    public var patches: [PatchSettings] = []
    public init() {}
}

public struct RunSettings: Codable, Sendable, Equatable {
    public var iterations = 500
    public var reportingInterval = 1
    public var timeStepSize = 1e-3
    public var numberOfTimeSteps = 100
    public var maxIterationsPerTimeStep = 20
    /// Write data every N iterations/time steps (0 = only at the end).
    public var autosaveInterval = 0
    /// Collect time statistics (mean/rms) during transient runs.
    public var dataSampling = false
    public init() {}
}

public struct NamedExpression: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var definition: String
    public init(name: String, definition: String) { self.name = name; self.definition = definition }
}

// MARK: - Case

public struct CaseSetup: Codable, Sendable, Equatable {
    public var title = "Untitled"
    public var general = GeneralSettings()
    public var models = Models()
    public var materials: [Material] = MaterialLibrary.defaults
    public var cellZones: [String: CellZoneSettings] = [:]
    public var boundaries: [String: BoundarySettings] = [:]
    public var methods = SolutionMethods()
    public var controls = SolutionControls()
    public var residuals = ResidualCriteria()
    public var reports: [ReportDefinition] = []
    public var reference = ReferenceValues()
    public var initialization = InitializationSettings()
    public var run = RunSettings()
    public var expressions: [NamedExpression] = []
    public init() {}

    /// Fill in missing zone settings from the mesh (default kinds, air/fluid).
    public mutating func adopt(mesh: Mesh) {
        for z in mesh.boundaryZones where boundaries[z.name] == nil {
            boundaries[z.name] = BoundarySettings(type: z.kind)
        }
        for z in mesh.cellZones where cellZones[z.name] == nil {
            var s = CellZoneSettings()
            s.kind = z.kind
            s.material = z.kind == .solid ? (materials.first { $0.kind == .solid }?.name ?? "aluminum") : (materials.first { $0.kind == .fluid }?.name ?? "air")
            cellZones[z.name] = s
        }
        // drop settings for zones that no longer exist
        let bz = Set(mesh.boundaryZones.map(\.name)), cz = Set(mesh.cellZones.map(\.name))
        boundaries = boundaries.filter { bz.contains($0.key) }
        cellZones = cellZones.filter { cz.contains($0.key) }
    }

    public func material(named n: String) -> Material? { materials.first { $0.name == n } }

    // MARK: Lenient JSON

    /// Decode JSON that may omit any field; omitted fields take defaults.
    public static func decodeLenient(_ data: Data) throws -> CaseSetup {
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExpressionError(message: "case file must be a JSON object")
        }
        let enc = JSONEncoder()
        var base = try JSONSerialization.jsonObject(with: enc.encode(CaseSetup())) as! [String: Any]
        // Map-valued sections need per-entry templates.
        var merged = user
        if let b = user["boundaries"] as? [String: Any] {
            var out: [String: Any] = [:]
            for (name, v) in b {
                guard let entry = v as? [String: Any] else { continue }
                let kind = (entry["type"] as? String).flatMap(ZoneKind.init(rawValue:)) ?? ZoneKind.guess(fromName: name)
                let t = try JSONSerialization.jsonObject(with: enc.encode(BoundarySettings(type: kind))) as! [String: Any]
                out[name] = deepMerge(t, entry)
            }
            merged["boundaries"] = out
        }
        if let c = user["cellZones"] as? [String: Any] {
            var out: [String: Any] = [:]
            let t = try JSONSerialization.jsonObject(with: enc.encode(CellZoneSettings())) as! [String: Any]
            for (name, v) in c { if let e = v as? [String: Any] { out[name] = deepMerge(t, e) } }
            merged["cellZones"] = out
        }
        if let m = user["materials"] as? [[String: Any]] {
            var out: [[String: Any]] = []
            for e in m {
                let name = e["name"] as? String ?? "material"
                let template = MaterialLibrary.lookup(name) ?? Material(name: name)
                let t = try JSONSerialization.jsonObject(with: enc.encode(template)) as! [String: Any]
                out.append(deepMerge(t, e))
            }
            // keep library defaults that the user did not redefine
            let names = Set(out.compactMap { $0["name"] as? String })
            for d in MaterialLibrary.defaults where !names.contains(d.name) {
                out.append(try JSONSerialization.jsonObject(with: enc.encode(d)) as! [String: Any])
            }
            merged["materials"] = out
        }
        if let r = user["reports"] as? [[String: Any]] {
            merged["reports"] = try r.map { e -> [String: Any] in
                let kind = (e["kind"] as? String).flatMap(ReportKind.init(rawValue:)) ?? .areaWeightedAverage
                let t = try JSONSerialization.jsonObject(with: enc.encode(ReportDefinition(name: e["name"] as? String ?? "report", kind: kind))) as! [String: Any]
                return deepMerge(t, e)
            }
        }
        if let ini = user["initialization"] as? [String: Any], let patches = ini["patches"] as? [[String: Any]] {
            let t = try JSONSerialization.jsonObject(with: enc.encode(PatchSettings())) as! [String: Any]
            var i2 = ini
            i2["patches"] = patches.map { deepMerge(t, $0) }
            merged["initialization"] = i2
        }
        if let ms = (user["models"] as? [String: Any])?["passiveScalars"] as? [[String: Any]] {
            let t = try JSONSerialization.jsonObject(with: enc.encode(PassiveScalar(name: "scalar"))) as! [String: Any]
            var m2 = merged["models"] as! [String: Any]
            m2["passiveScalars"] = ms.map { deepMerge(t, $0) }
            merged["models"] = m2
        }
        base = deepMerge(base, merged)
        let out = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(CaseSetup.self, from: out)
    }

    static func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let bv = v as? [String: Any], let av = a[k] as? [String: Any], !(k == "boundaries" || k == "cellZones") {
                out[k] = deepMerge(av, bv)
            } else {
                out[k] = v
            }
        }
        return out
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
