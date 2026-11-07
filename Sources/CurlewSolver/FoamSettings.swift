import Foundation
import CurlewMesh

// MARK: - Backend

/// Which code solves the case. Curlew's own finite-volume solver, or an installed OpenFOAM
/// driven by Curlew: the case is written from the same setup, run stage by stage, and the
/// results are read back so every Results page works on either.
public enum SolverBackend: String, Codable, CaseIterable, Sendable {
    case curlew
    case openfoam

    public var displayName: String {
        switch self {
        case .curlew: return "Curlew (built-in)"
        case .openfoam: return "OpenFOAM"
        }
    }
}

// MARK: - Application

/// OpenFOAM (ESI, v2xxx) solver applications Curlew can set up.
public enum FoamApplication: String, Codable, CaseIterable, Sendable {
    /// Picked from the setup: steady/transient, energy, buoyancy, compressibility.
    case automatic
    case simpleFoam, pimpleFoam, pisoFoam, icoFoam, potentialFoam
    case buoyantBoussinesqSimpleFoam, buoyantBoussinesqPimpleFoam
    case buoyantSimpleFoam, buoyantPimpleFoam
    case rhoSimpleFoam, rhoPimpleFoam, rhoCentralFoam
    /// Conjugate heat transfer: one fluid region coupled to solid regions.
    case chtMultiRegionSimpleFoam, chtMultiRegionFoam

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (from the setup)"
        case .simpleFoam: return "simpleFoam — steady incompressible"
        case .pimpleFoam: return "pimpleFoam — transient incompressible (PIMPLE)"
        case .pisoFoam: return "pisoFoam — transient incompressible (PISO)"
        case .icoFoam: return "icoFoam — transient laminar"
        case .potentialFoam: return "potentialFoam — potential flow"
        case .buoyantBoussinesqSimpleFoam: return "buoyantBoussinesqSimpleFoam — steady heat transfer (Boussinesq)"
        case .buoyantBoussinesqPimpleFoam: return "buoyantBoussinesqPimpleFoam — transient heat transfer (Boussinesq)"
        case .buoyantSimpleFoam: return "buoyantSimpleFoam — steady heat transfer/buoyancy"
        case .buoyantPimpleFoam: return "buoyantPimpleFoam — transient heat transfer/buoyancy"
        case .rhoSimpleFoam: return "rhoSimpleFoam — steady compressible"
        case .rhoPimpleFoam: return "rhoPimpleFoam — transient compressible"
        case .rhoCentralFoam: return "rhoCentralFoam — density-based (central-upwind)"
        case .chtMultiRegionSimpleFoam: return "chtMultiRegionSimpleFoam — steady conjugate heat transfer"
        case .chtMultiRegionFoam: return "chtMultiRegionFoam — transient conjugate heat transfer"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .pimpleFoam, .pisoFoam, .icoFoam, .buoyantPimpleFoam, .buoyantBoussinesqPimpleFoam, .rhoPimpleFoam, .rhoCentralFoam, .chtMultiRegionFoam: return true
        default: return false
        }
    }
    /// Solves an energy equation with a thermophysical model (p absolute, T, alphat).
    public var isThermal: Bool {
        switch self {
        case .buoyantSimpleFoam, .buoyantPimpleFoam, .rhoSimpleFoam, .rhoPimpleFoam, .rhoCentralFoam, .chtMultiRegionSimpleFoam, .chtMultiRegionFoam: return true
        default: return false
        }
    }
    public var isBuoyant: Bool { [.buoyantSimpleFoam, .buoyantPimpleFoam, .chtMultiRegionSimpleFoam, .chtMultiRegionFoam].contains(self) }
    /// Multi-region (fluid + solid regions) case layout.
    public var isMultiRegion: Bool { self == .chtMultiRegionSimpleFoam || self == .chtMultiRegionFoam }
    /// Kinematic (constant-density) solvers with a temperature equation and rhok = 1 - beta (T - TRef).
    public var isBoussinesq: Bool { self == .buoyantBoussinesqSimpleFoam || self == .buoyantBoussinesqPimpleFoam }
    /// Solves for temperature (thermophysical or Boussinesq).
    public var solvesTemperature: Bool { isThermal || isBoussinesq }
    /// Uses p_rgh as the solved pressure.
    public var usesPrgh: Bool { isBuoyant || isBoussinesq }
    public var supportsTurbulence: Bool { self != .icoFoam && self != .potentialFoam }
}

// MARK: - Turbulence

/// Turbulence closures available in OpenFOAM. `fromCurlew` uses the Models page; the rest
/// add the RAS variants, LES and DES models Curlew's own solver does not have.
public enum FoamTurbulenceModel: String, Codable, CaseIterable, Sendable {
    case fromCurlew
    case laminar
    // RAS
    case kEpsilon, realizableKE, RNGkEpsilon, LaunderSharmaKE
    case kOmega, kOmegaSST, SpalartAllmaras
    // LES
    case Smagorinsky, WALE, kEqn, dynamicKEqn
    // DES
    case SpalartAllmarasDES, SpalartAllmarasDDES, SpalartAllmarasIDDES
    case kOmegaSSTDES, kOmegaSSTDDES, kOmegaSSTIDDES

    public enum Family: String, Sendable { case laminar, RAS, LES }

    public var family: Family {
        switch self {
        case .fromCurlew, .laminar: return .laminar
        case .kEpsilon, .realizableKE, .RNGkEpsilon, .LaunderSharmaKE, .kOmega, .kOmegaSST, .SpalartAllmaras: return .RAS
        default: return .LES   // OpenFOAM runs DES through simulationType LES
        }
    }

    public var displayName: String {
        switch self {
        case .fromCurlew: return "Same as Models page"
        case .laminar: return "Laminar"
        case .kEpsilon: return "RAS k-epsilon"
        case .realizableKE: return "RAS realizable k-epsilon"
        case .RNGkEpsilon: return "RAS RNG k-epsilon"
        case .LaunderSharmaKE: return "RAS Launder-Sharma low-Re k-epsilon"
        case .kOmega: return "RAS k-omega (Wilcox 1998)"
        case .kOmegaSST: return "RAS k-omega SST"
        case .SpalartAllmaras: return "RAS Spalart-Allmaras"
        case .Smagorinsky: return "LES Smagorinsky"
        case .WALE: return "LES WALE"
        case .kEqn: return "LES one-equation k"
        case .dynamicKEqn: return "LES dynamic k-equation"
        case .SpalartAllmarasDES: return "DES Spalart-Allmaras"
        case .SpalartAllmarasDDES: return "DDES Spalart-Allmaras"
        case .SpalartAllmarasIDDES: return "IDDES Spalart-Allmaras"
        case .kOmegaSSTDES: return "DES k-omega SST"
        case .kOmegaSSTDDES: return "DDES k-omega SST"
        case .kOmegaSSTIDDES: return "IDDES k-omega SST"
        }
    }

    /// Transported turbulence fields (besides nut) the model reads from 0/.
    public var fields: [String] {
        switch self {
        case .fromCurlew, .laminar: return []
        case .kEpsilon, .realizableKE, .RNGkEpsilon, .LaunderSharmaKE: return ["k", "epsilon"]
        case .kOmega, .kOmegaSST, .kOmegaSSTDES, .kOmegaSSTDDES, .kOmegaSSTIDDES: return ["k", "omega"]
        case .SpalartAllmaras, .SpalartAllmarasDES, .SpalartAllmarasDDES, .SpalartAllmarasIDDES: return ["nuTilda"]
        case .Smagorinsky, .WALE: return []
        case .kEqn, .dynamicKEqn: return ["k"]
        }
    }

    /// Equivalent OpenFOAM model for a Curlew viscous model.
    /// Scale-resolving models (LES, DES) need a transient application.
    public var resolvesScales: Bool { family == .LES }

    public static func from(_ v: ViscousModel) -> FoamTurbulenceModel {
        switch v {
        case .inviscid, .laminar: return .laminar
        case .spalartAllmaras: return .SpalartAllmaras
        case .kEpsilonStandard: return .kEpsilon
        case .kEpsilonRealizable: return .realizableKE
        case .kOmegaSST: return .kOmegaSST
        }
    }
}

/// Near-wall treatment for the turbulence fields.
public enum FoamWallTreatment: String, Codable, CaseIterable, Sendable {
    /// Matches the Models page: Spalding (y+-insensitive) for SST/SA/automatic, log-law for
    /// standard wall functions.
    case automatic
    /// Spalding's law for nut, wall functions for k/omega/epsilon (any y+).
    case spalding
    /// High-Re log-law wall functions (y+ 30-300).
    case standardWallFunctions
    /// Resolve the viscous sublayer (y+ ~ 1): nutLowReWallFunction, k = 0 at walls.
    case lowRe

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (match Models page)"
        case .spalding: return "Spalding law (y+ insensitive)"
        case .standardWallFunctions: return "Standard wall functions (log law)"
        case .lowRe: return "Low-Re (resolve sublayer, y+ ≈ 1)"
        }
    }
}

/// Where the initial (0/) fields come from.
public enum FoamInitialFields: String, Codable, CaseIterable, Sendable {
    /// Curlew runs its own Initialization (hybrid or standard, with patches) and the resulting
    /// cell fields are written as nonuniform internal fields; an existing Curlew solution is
    /// written instead when there is one, so OpenFOAM continues from it.
    case curlew
    /// Uniform internal fields from the Initialization page's standard values.
    case uniform
    /// Uniform fields, then `potentialFoam` (incompressible applications only).
    case potentialFoam

    public var displayName: String {
        switch self {
        case .curlew: return "Curlew initialization (or current solution)"
        case .uniform: return "Uniform standard values"
        case .potentialFoam: return "potentialFoam"
        }
    }
}

// MARK: - Linear solvers

/// One `solvers { field { … } }` entry.
public struct FoamLinearSolver: Codable, Sendable, Equatable {
    /// GAMG, PCG, PBiCGStab, smoothSolver, diagonal.
    public var solver: String
    /// GaussSeidel, symGaussSeidel, DIC, DILU, DICGaussSeidel (GAMG and smoothSolver).
    public var smoother: String
    /// DIC, DILU, FDIC, GAMG, none (PCG/PBiCGStab).
    public var preconditioner: String
    public var tolerance: Double
    public var relTol: Double
    public var maxIter: Int
    /// GAMG only.
    public var nCellsInCoarsestLevel: Int

    public init(solver: String, smoother: String = "GaussSeidel", preconditioner: String = "DIC",
                tolerance: Double, relTol: Double, maxIter: Int = 1000, nCellsInCoarsestLevel: Int = 10) {
        self.solver = solver; self.smoother = smoother; self.preconditioner = preconditioner
        self.tolerance = tolerance; self.relTol = relTol; self.maxIter = maxIter
        self.nCellsInCoarsestLevel = nCellsInCoarsestLevel
    }

    public static let pressure = FoamLinearSolver(solver: "GAMG", smoother: "GaussSeidel", tolerance: 1e-7, relTol: 0.01, maxIter: 200)
    public static let transport = FoamLinearSolver(solver: "smoothSolver", smoother: "symGaussSeidel", preconditioner: "DILU", tolerance: 1e-8, relTol: 0.1)

    public static let solverChoices = ["GAMG", "PCG", "PBiCGStab", "smoothSolver"]
    public static let smootherChoices = ["GaussSeidel", "symGaussSeidel", "DIC", "DILU", "DICGaussSeidel", "nonBlockingGaussSeidel"]
    public static let preconditionerChoices = ["DIC", "FDIC", "DILU", "GAMG", "none"]
}

// MARK: - Schemes

/// fvSchemes overrides. An empty string means "derive from Curlew's Methods page"; any other
/// value is written verbatim (e.g. `bounded Gauss linearUpwind limited`, `cellLimited leastSquares 1`).
public struct FoamSchemeOverrides: Codable, Sendable, Equatable {
    public var ddt = ""
    public var grad = ""
    public var gradU = ""
    public var divU = ""
    public var divTurbulence = ""
    public var divEnergy = ""
    public var divScalars = ""
    public var laplacian = ""
    public var snGrad = ""
    public var interpolation = ""
    public var wallDistance = "meshWave"
    public init() {}
}

// MARK: - Monitors and expert entries

/// Raw boundary condition for one field on one patch: `text` is placed verbatim inside the
/// patch braces (e.g. `type codedFixedValue; …`), so any OpenFOAM condition is reachable.
public struct FoamPatchOverride: Codable, Sendable, Equatable, Identifiable {
    public var id: String { patch + "/" + field }
    public var patch: String
    public var field: String
    public var text: String
    public init(patch: String, field: String, text: String) { self.patch = patch; self.field = field; self.text = text }

    private enum K: String, CodingKey { case patch, field, text }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? "U"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// A utility spliced into the run, e.g. `topoSet`, `setFields`, `postProcess -func Q`.
public struct FoamCustomStage: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, CaseIterable, Sendable { case beforeSolve, afterSolve }
    public var id: String { phase.rawValue + ":" + command }
    public var phase: Phase
    /// Application and arguments as typed, e.g. `postProcess -func vorticity -latestTime`.
    public var command: String
    public var parallel: Bool
    public init(phase: Phase, command: String, parallel: Bool = false) { self.phase = phase; self.command = command; self.parallel = parallel }

    /// The command split into words (quotes group words; no shell interpretation).
    public var words: [String] { CADConversion.splitCommand(command) }

    private enum K: String, CodingKey { case phase, command, parallel }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .afterSolve
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        parallel = try c.decodeIfPresent(Bool.self, forKey: .parallel) ?? false
    }
}

/// An OpenFOAM field value: a scalar or a vector.
public struct FoamFieldValue: Codable, Sendable, Equatable, Identifiable {
    public var id: String { field }
    public var field = "U"
    public var scalar = 0.0
    public var vector: [Double]? = [0, 0, 0]
    public init(field: String = "U", scalar: Double = 0, vector: [Double]? = nil) { self.field = field; self.scalar = scalar; self.vector = vector }
    public var isVector: Bool { vector?.count == 3 }
}

/// A region where setFields writes values before the run.
public struct FoamSetFieldsRegion: Codable, Sendable, Equatable, Identifiable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case box, sphere, cylinder }
    public var id: String { name }
    public var name = "region1"
    public var shape: Shape = .box
    /// Box: min and max corners. Sphere: centre (`a`) and radius. Cylinder: axis ends `a`, `b` and radius.
    public var a: [Double] = [0, 0, 0]
    public var b: [Double] = [1, 1, 1]
    public var radius = 0.1
    public var values: [FoamFieldValue] = [FoamFieldValue(field: "U", vector: [0, 0, 0])]
    public init(name: String = "region1") { self.name = name }
}

public struct FoamPreProcessing: Codable, Sendable, Equatable {
    /// Map the solution of another OpenFOAM case onto this mesh (mapFields); empty = off.
    public var mapFieldsSource = ""
    /// Same geometry and patches (consistent) or mapped by patch name pairs.
    public var mapFieldsConsistent = true
    public var setFieldsRegions: [FoamSetFieldsRegion] = []
    /// Near-wall initial velocity profile over this thickness [m] (applyBoundaryLayer); nil = off.
    public var boundaryLayerThickness: Double? = nil
    /// checkMesh with -allGeometry -allTopology.
    public var fullMeshCheck = false
    public init() {}
    public var isEmpty: Bool { mapFieldsSource.isEmpty && setFieldsRegions.isEmpty && boundaryLayerThickness == nil }
}

public struct FoamLineSample: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name = "line1"
    public var start: [Double] = [0, 0, 0]
    public var end: [Double] = [1, 0, 0]
    public var points = 100
    public var fields = "U p"
    public init(name: String = "line1") { self.name = name }
}

public struct FoamIsoSurface: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name = "iso1"
    public var field = "p"
    public var value = 0.0
    public init(name: String = "iso1") { self.name = name }
}

public struct FoamPostProcessing: Codable, Sendable, Equatable {
    /// Derived-field function objects run on the solution (OpenFOAM function names).
    public var functions: [String] = []
    public var lineSamples: [FoamLineSample] = []
    public var isoSurfaces: [FoamIsoSurface] = []
    /// Streamlines seeded along a line (start, end, seed count); nil = off.
    public var streamlineSeedStart: [Double]? = nil
    public var streamlineSeedEnd: [Double] = [0, 1, 0]
    public var streamlineSeeds = 40
    public var exportVTK = false
    public var exportEnsight = false
    /// Run after every solve (otherwise only with "Run Post-Processing Now").
    public var afterSolve = true
    public init() {}

    /// Function objects offered in the app (each runs through `<solver> -postProcess`).
    public static let availableFunctions: [(name: String, title: String)] = [
        ("vorticity", "Vorticity"), ("Q", "Q criterion"), ("Lambda2", "λ₂ vortex criterion"), ("enstrophy", "Enstrophy"),
        ("CourantNo", "Courant number"), ("PecletNo", "Péclet number"), ("MachNo", "Mach number (compressible)"),
        ("wallShearStress", "Wall shear stress"), ("yPlus", "y⁺"), ("wallHeatFlux", "Wall heat flux (heat transfer)"),
        ("streamFunction", "Stream function (2D)"), ("flowType", "Flow type (shear / rotation)"), ("writeCellCentres", "Cell centres"),
        ("writeCellVolumes", "Cell volumes"), ("turbulenceFields", "Turbulence fields (k, ε, ω, νt, R)"),
    ]
    public var isEmpty: Bool {
        functions.isEmpty && lineSamples.isEmpty && isoSurfaces.isEmpty && streamlineSeedStart == nil && !exportVTK && !exportEnsight
    }
}

/// A baffle created by OpenFOAM (`createBaffles`) on the internal faces cut by a plate, disk or
/// box surface. Its two sides become `<name>_master` (the side the surface normal leaves) and
/// `<name>_slave`.
public struct FoamBaffle: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Pressure rise from a fan curve (fan jump condition on a cyclic pair).
        case fan
        /// Pressure drop Δp = (D μ U + ½ I ρ U²) L of a screen, filter or perforated plate.
        case porousJump
        /// Zero-thickness wall (both sides no-slip).
        case thinWall

        public var displayName: String {
            switch self {
            case .fan: return "Fan (pressure jump from a fan curve)"
            case .porousJump: return "Porous jump (filter, screen, perforated plate)"
            case .thinWall: return "Thin wall"
            }
        }
    }
    public enum Shape: String, Codable, CaseIterable, Sendable { case disk, plate, box }

    public var id: String { name }
    public var name = "fan1"
    public var kind: Kind = .fan
    public var shape: Shape = .disk
    /// Disk: centre, normal (flow direction through a fan), radius. Plate: corner `origin` and
    /// `span` (one component 0). Box: `origin` = min corner, `span` = size.
    public var origin: [Double] = [0, 0, 0]
    public var normal: [Double] = [1, 0, 0]
    public var radius = 0.05
    public var span: [Double] = [0, 0.1, 0.1]
    /// Fan curve: (volume flow [m³/s], pressure rise [Pa]) points, flow increasing.
    public var fanCurve: [[Double]] = [[0, 200], [0.01, 150], [0.02, 0]]
    /// Porous jump: Darcy D [1/m²], inertial I [1/m], thickness L [m].
    public var darcy = 1e6
    public var inertial = 100.0
    public var thickness = 0.005
    /// Fan / porous jump from the patch-mean velocity instead of face by face (uniformJump).
    public var uniformJump = false

    public init(name: String = "fan1", kind: Kind = .fan) { self.name = name; self.kind = kind }

    /// Area the baffle spans [m²] (disk π r², plate |span| product, box largest face).
    public var nominalArea: Double {
        switch shape {
        case .disk: return Double.pi * radius * radius
        case .plate: return span.filter { abs($0) > 0 }.reduce(1) { $0 * abs($1) }
        case .box: let s = span.map(abs).sorted(); return s.count == 3 ? s[1] * s[2] : 0
        }
    }
}

public struct FoamCuttingPlane: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var point: [Double]
    public var normal: [Double]
    public init(name: String, point: [Double], normal: [Double]) { self.name = name; self.point = point; self.normal = normal }
}

// MARK: - Radiation

/// Thermal radiation in OpenFOAM heat-transfer cases (fluid regions; solids are opaque).
public struct FoamRadiation: Codable, Sendable, Equatable {
    public enum Model: String, Codable, CaseIterable, Sendable {
        case none
        /// Discrete ordinates: transparent or participating gas, surface-to-surface exchange.
        case fvDOM
        /// Spherical harmonics: optically thick media (needs a nonzero absorption coefficient).
        case P1
    }
    public var model: Model = .none
    /// Gas absorption/emission coefficient [1/m] (0 = transparent air; P1 needs > 0).
    public var absorption = 0.0
    /// Wall emissivity, and per-patch overrides.
    public var emissivity = 0.9
    public var patchEmissivity: [String: Double] = [:]
    /// Flow iterations per radiation solve.
    public var solverFrequency = 10
    /// fvDOM angular resolution (per octant).
    public var nPhi = 3
    public var nTheta = 3
    public init() {}
    private enum K: String, CodingKey { case model, absorption, emissivity, patchEmissivity, solverFrequency, nPhi, nTheta }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        model = try c.decodeIfPresent(Model.self, forKey: .model) ?? .none
        absorption = try c.decodeIfPresent(Double.self, forKey: .absorption) ?? 0
        emissivity = try c.decodeIfPresent(Double.self, forKey: .emissivity) ?? 0.9
        patchEmissivity = try c.decodeIfPresent([String: Double].self, forKey: .patchEmissivity) ?? [:]
        solverFrequency = try c.decodeIfPresent(Int.self, forKey: .solverFrequency) ?? 10
        nPhi = try c.decodeIfPresent(Int.self, forKey: .nPhi) ?? 3
        nTheta = try c.decodeIfPresent(Int.self, forKey: .nTheta) ?? 3
    }
}

// MARK: - Settings

/// Everything the OpenFOAM backend needs beyond the shared Curlew setup. Every field has a
/// default that reproduces the Curlew setup as closely as OpenFOAM allows; the rest of the
/// knobs are what an OpenFOAM user edits in `system/` and `constant/` by hand.
public struct FoamSettings: Codable, Sendable, Equatable {
    // Installation and case location
    /// `.app` bundle, tree root or `etc/bashrc`; empty = the newest one found.
    public var installation = ""
    /// Case directory; empty = `~/CurlewFoam/<title>`. OpenFOAM rejects paths with spaces.
    public var caseDirectory = ""

    // Physics
    public var application: FoamApplication = .automatic
    public var turbulence: FoamTurbulenceModel = .fromCurlew
    public var wallTreatment: FoamWallTreatment = .automatic
    /// LES filter width: cubeRootVol, vanDriest, smooth, maxDeltaxyz.
    public var lesDelta = "cubeRootVol"

    // Time and output (nil = from Run Calculation)
    public var endTime: Double? = nil
    public var deltaT: Double? = nil
    /// Write every N iterations/time steps (0 = only at the end).
    public var writeInterval = 0
    /// ascii or binary.
    public var writeFormat = "binary"
    public var writePrecision = 10
    /// Keep only the last N written times (0 = keep all).
    public var purgeWrite = 0
    public var adjustTimeStep = false
    public var maxCo = 1.0
    public var maxDeltaT = 1.0
    /// Restart from the latest time directory already in the case instead of rewriting 0/.
    public var continueFromLatestTime = false
    public var initialFields: FoamInitialFields = .curlew

    // Discretisation and linear solvers
    public var schemes = FoamSchemeOverrides()
    public var pressureSolver = FoamLinearSolver.pressure
    public var velocitySolver = FoamLinearSolver.transport
    public var turbulenceSolver = FoamLinearSolver.transport
    /// PBiCGStab/DILU copes with the diffusion-dominated first iterations of heat-transfer cases.
    public var energySolver = FoamLinearSolver(solver: "PBiCGStab", smoother: "symGaussSeidel", preconditioner: "DILU", tolerance: 1e-8, relTol: 0.1)

    // Pressure-velocity coupling (nil = from Methods)
    public var consistent: Bool? = nil
    public var nOuterCorrectors = 1
    public var nCorrectors = 2
    public var nNonOrthogonalCorrectors: Int? = nil
    public var momentumPredictor = true
    public var turbOnFinalIterOnly = true
    /// Relaxation factors: from the Controls page unless overridden here.
    public var relaxationU: Double? = nil
    public var relaxationP: Double? = nil
    public var relaxationTurbulence: Double? = nil
    public var relaxationEnergy: Double? = nil
    /// SIMPLE residualControl (initial residuals); 0 disables.
    public var residualP = 1e-5
    public var residualU = 1e-6
    public var residualTurbulence = 1e-6
    public var residualEnergy = 1e-7
    /// PIMPLE outer-loop convergence (0 = fixed nOuterCorrectors).
    public var outerResidual = 0.0

    /// Thermal radiation (OpenFOAM backend).
    public var radiation = FoamRadiation()

    // Parallel
    public var cores = 1
    /// scotch, hierarchical, simple, kahip.
    public var decomposition = "scotch"

    // Monitors (function objects)
    public var yPlus = true
    public var wallShearStress = true
    public var fieldMinMax = false
    public var vorticity = false
    public var qCriterion = false
    public var probes: [[Double]] = []
    /// Raw function-object definitions added inside `functions { }`.
    public var customFunctions = ""

    /// Run checkMesh before solving.
    public var checkMesh = true

    // Expert
    public var patchOverrides: [FoamPatchOverride] = []
    /// Text appended to a generated file, keyed by its case-relative path ("system/fvSolution").
    /// Later keys override earlier ones in OpenFOAM's dictionary parser.
    public var dictionaryAppends: [String: String] = [:]
    /// Whole files added to the case (path → contents), e.g. "system/topoSetDict".
    public var extraFiles: [String: String] = [:]
    public var customStages: [FoamCustomStage] = []
    /// Read the latest time back into Curlew when the run ends (and at each write).
    public var loadResults = true

    // Run control (controlDict)
    /// latestTime (continue from the newest time directory) or startTime.
    public var startFrom = "latestTime"
    /// endTime, writeNow, noWriteNow or nextWrite (useful to change while running).
    public var stopAt = "endTime"
    public var writeCompression = false
    public var timePrecision = 10
    public var runTimeModifiable = true

    // Safety limits (fvOptions)
    /// Cap the velocity magnitude [m/s] (limitVelocity); nil = off.
    public var limitVelocity: Double? = nil

    // More function objects
    public var courantNumber = false
    public var machNumber = false
    public var pressureCoefficient = false
    public var wallHeatFlux = false
    public var turbulenceFields = false
    public var lambda2 = false
    /// Write initial residuals of every equation to postProcessing/residuals.
    public var residualsFile = true
    /// Cutting planes written as VTK surfaces at each write (name, point, normal).
    public var cuttingPlanes: [FoamCuttingPlane] = []
    /// Stop the run when a report definition has changed by less than `runTimeStopTolerance`
    /// (relative) over `runTimeStopWindow` iterations (runTimeControl); empty = off.
    public var runTimeStopReport = ""
    public var runTimeStopTolerance = 1e-4
    public var runTimeStopWindow = 100

    /// Replace a generated file completely with this text (case-relative path → contents).
    public var fileOverrides: [String: String] = [:]

    /// OpenFOAM utilities run before the solver (mapFields, setFields, applyBoundaryLayer).
    public var preProcessing = FoamPreProcessing()
    /// OpenFOAM post-processing after the solver (derived fields, samples, exports).
    public var postProcessing = FoamPostProcessing()

    /// Baffles made from internal faces by OpenFOAM's createBaffles (fans, porous jumps, thin walls).
    public var baffles: [FoamBaffle] = []
    /// Drive a periodic flow at this mean velocity [m/s] (meanVelocityForce); nil = off.
    public var meanVelocity: [Double]? = nil

    public init() {}

    /// Setting strings written into OpenFOAM dictionaries as keywords (schemes, solvers, LES
    /// filter, decomposition) that contain anything but words, numbers, spaces, parentheses,
    /// commas, signs and dots: such text could add dictionary directives (#codeStream, $var)
    /// or entries, so the case is refused. Empty when all are plain.
    public var invalidKeywordSettings: [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _.,()+-:"))
        var bad: [String] = []
        func check(_ name: String, _ v: String) {
            if !v.unicodeScalars.allSatisfy({ allowed.contains($0) }) { bad.append("\(name): \(v.prefix(60))") }
        }
        let sc = schemes
        for (n, v) in [("ddt", sc.ddt), ("grad", sc.grad), ("grad(U)", sc.gradU), ("div(U)", sc.divU), ("div(turbulence)", sc.divTurbulence),
                       ("div(energy)", sc.divEnergy), ("div(scalars)", sc.divScalars), ("laplacian", sc.laplacian), ("snGrad", sc.snGrad),
                       ("interpolation", sc.interpolation), ("wallDist", sc.wallDistance)] { check("scheme \(n)", v) }
        check("LES delta", lesDelta)
        check("decomposition", decomposition)
        check("write format", writeFormat)
        for (n, l) in [("pressure", pressureSolver), ("velocity", velocitySolver), ("turbulence", turbulenceSolver), ("energy", energySolver)] {
            check("\(n) solver", l.solver); check("\(n) smoother", l.smoother); check("\(n) preconditioner", l.preconditioner)
        }
        return bad
    }

    /// Settings that make OpenFOAM run something other than the case Curlew generates: extra
    /// stages, raw function objects (e.g. `systemCall`), dictionary text (e.g. `#codeStream`),
    /// raw boundary conditions (e.g. `codedFixedValue`) and extra files. A case opened from
    /// disk shows these to the user before it is run. Empty when there are none.
    public var activeContent: [String] {
        var out: [String] = []
        for c in customStages where !c.command.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("Stage (\(c.phase == .beforeSolve ? "before" : "after") solve): \(c.command)")
        }
        if !customFunctions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("Function objects: \(customFunctions.prefix(300))") }
        for (p, t) in dictionaryAppends.sorted(by: { $0.key < $1.key }) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Appended to \(p): \(t.prefix(300))")
        }
        for o in patchOverrides { out.append("Raw boundary condition \(o.field) on \(o.patch): \(o.text.prefix(200))") }
        for p in extraFiles.keys.sorted() { out.append("Extra file \(p)") }
        for p in fileOverrides.keys.sorted() { out.append("Replaced file \(p): \(fileOverrides[p]!.prefix(200))") }
        return out
    }
}
