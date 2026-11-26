import Foundation
import FluidCraftMesh

// MARK: - Application

/// OpenFOAM (ESI, v2xxx) solver applications FluidCraft can set up.
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

/// Turbulence closures available in OpenFOAM. `fromFluidCraft` uses the Models page; the rest
/// add RAS variants, LES and DES models beyond FluidCraft's Models page.
public enum FoamTurbulenceModel: String, Codable, CaseIterable, Sendable {
    case fromFluidCraft = "fromCurlew"   // stored value kept so older case files still read
    case laminar
    // RAS
    case kEpsilon, realizableKE, RNGkEpsilon, LaunderSharmaKE
    case kOmega, kOmegaSST, SpalartAllmaras
    case kOmegaSSTSAS, kOmegaSSTLM, GEKO
    /// Reynolds-stress transport (R and epsilon fields).
    case LRR, SSG
    // LES
    case Smagorinsky, WALE, kEqn, dynamicKEqn, sigma, DeardorffDiffStress
    // DES
    case SpalartAllmarasDES, SpalartAllmarasDDES, SpalartAllmarasIDDES
    case kOmegaSSTDES, kOmegaSSTDDES, kOmegaSSTIDDES

    public enum Family: String, Sendable { case laminar, RAS, LES }

    public var family: Family {
        switch self {
        case .fromFluidCraft, .laminar: return .laminar
        case .kEpsilon, .realizableKE, .RNGkEpsilon, .LaunderSharmaKE, .kOmega, .kOmegaSST, .SpalartAllmaras,
             .kOmegaSSTSAS, .kOmegaSSTLM, .GEKO, .LRR, .SSG: return .RAS
        default: return .LES   // OpenFOAM runs DES through simulationType LES
        }
    }

    public var displayName: String {
        switch self {
        case .fromFluidCraft: return "Same as Models page"
        case .laminar: return "Laminar"
        case .kEpsilon: return "RAS k-epsilon"
        case .realizableKE: return "RAS realizable k-epsilon"
        case .RNGkEpsilon: return "RAS RNG k-epsilon"
        case .LaunderSharmaKE: return "RAS Launder-Sharma low-Re k-epsilon"
        case .kOmega: return "RAS k-omega (Wilcox 1998)"
        case .kOmegaSST: return "RAS k-omega SST"
        case .SpalartAllmaras: return "RAS Spalart-Allmaras"
        case .kOmegaSSTSAS: return "RAS k-omega SST-SAS (scale-adaptive)"
        case .kOmegaSSTLM: return "RAS k-omega SST Langtry-Menter transition"
        case .GEKO: return "RAS GEKO (generalised k-omega)"
        case .LRR: return "RAS Reynolds stress LRR"
        case .SSG: return "RAS Reynolds stress SSG"
        case .Smagorinsky: return "LES Smagorinsky"
        case .WALE: return "LES WALE"
        case .kEqn: return "LES one-equation k"
        case .dynamicKEqn: return "LES dynamic k-equation"
        case .sigma: return "LES sigma"
        case .DeardorffDiffStress: return "LES Deardorff differential stress"
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
        case .fromFluidCraft, .laminar: return []
        case .kEpsilon, .realizableKE, .RNGkEpsilon, .LaunderSharmaKE: return ["k", "epsilon"]
        case .kOmega, .kOmegaSST, .kOmegaSSTDES, .kOmegaSSTDDES, .kOmegaSSTIDDES, .kOmegaSSTSAS, .GEKO: return ["k", "omega"]
        case .kOmegaSSTLM: return ["k", "omega", "ReThetat", "gammaInt"]
        case .LRR, .SSG: return ["R", "epsilon"]
        case .DeardorffDiffStress: return ["R"]
        case .SpalartAllmaras, .SpalartAllmarasDES, .SpalartAllmarasDDES, .SpalartAllmarasIDDES: return ["nuTilda"]
        case .Smagorinsky, .WALE, .sigma: return []
        case .kEqn, .dynamicKEqn: return ["k"]
        }
    }

    /// Equivalent OpenFOAM model for a FluidCraft viscous model.
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
    /// The Initialization page decides: standard initialization (values, expressions, patches)
    /// is written as nonuniform internal fields; hybrid runs potentialFoam on uniform fields.
    /// A loaded solution is written instead when there is one, so OpenFOAM continues from it.
    case fluidcraft = "curlew"   // stored value kept so older case files still read
    /// Uniform internal fields from the Initialization page's standard values.
    case uniform
    /// Uniform fields, then `potentialFoam` (incompressible applications only).
    case potentialFoam

    public var displayName: String {
        switch self {
        case .fluidcraft: return "Initialization page (or current solution)"
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
    /// Minimum iterations (0 = may stop before iterating).
    public var minIter = 0
    /// smoothSolver sweeps per iteration.
    public var nSweeps = 1
    /// GAMG: smoothing sweeps before and after each coarse-level correction, levels merged
    /// per coarsening step, and whether the agglomeration is kept between solves.
    public var nPreSweeps = 0
    public var nPostSweeps = 2
    public var mergeLevels = 1
    public var cacheAgglomeration = true

    public init(solver: String, smoother: String = "GaussSeidel", preconditioner: String = "DIC",
                tolerance: Double, relTol: Double, maxIter: Int = 1000, nCellsInCoarsestLevel: Int = 10) {
        self.solver = solver; self.smoother = smoother; self.preconditioner = preconditioner
        self.tolerance = tolerance; self.relTol = relTol; self.maxIter = maxIter
        self.nCellsInCoarsestLevel = nCellsInCoarsestLevel
    }

    private enum K: String, CodingKey {
        case solver, smoother, preconditioner, tolerance, relTol, maxIter, nCellsInCoarsestLevel, minIter, nSweeps, nPreSweeps, nPostSweeps, mergeLevels, cacheAgglomeration
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        solver = c.lenient(.solver, "GAMG"); smoother = c.lenient(.smoother, "GaussSeidel"); preconditioner = c.lenient(.preconditioner, "DIC")
        tolerance = c.lenient(.tolerance, 1e-7); relTol = c.lenient(.relTol, 0.01); maxIter = c.lenient(.maxIter, 1000)
        nCellsInCoarsestLevel = c.lenient(.nCellsInCoarsestLevel, 10); minIter = c.lenient(.minIter, 0); nSweeps = c.lenient(.nSweeps, 1)
        nPreSweeps = c.lenient(.nPreSweeps, 0); nPostSweeps = c.lenient(.nPostSweeps, 2); mergeLevels = c.lenient(.mergeLevels, 1)
        cacheAgglomeration = c.lenient(.cacheAgglomeration, true)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(solver, forKey: .solver); try c.encode(smoother, forKey: .smoother); try c.encode(preconditioner, forKey: .preconditioner)
        try c.encode(tolerance, forKey: .tolerance); try c.encode(relTol, forKey: .relTol); try c.encode(maxIter, forKey: .maxIter)
        try c.encode(nCellsInCoarsestLevel, forKey: .nCellsInCoarsestLevel); try c.encode(minIter, forKey: .minIter); try c.encode(nSweeps, forKey: .nSweeps)
        try c.encode(nPreSweeps, forKey: .nPreSweeps); try c.encode(nPostSweeps, forKey: .nPostSweeps); try c.encode(mergeLevels, forKey: .mergeLevels)
        try c.encode(cacheAgglomeration, forKey: .cacheAgglomeration)
    }

    public static let pressure = FoamLinearSolver(solver: "GAMG", smoother: "GaussSeidel", tolerance: 1e-7, relTol: 0.01, maxIter: 200)
    public static let transport = FoamLinearSolver(solver: "smoothSolver", smoother: "symGaussSeidel", preconditioner: "DILU", tolerance: 1e-8, relTol: 0.1)

    public static let solverChoices = ["GAMG", "PCG", "PBiCGStab", "smoothSolver"]
    public static let smootherChoices = ["GaussSeidel", "symGaussSeidel", "DIC", "DILU", "DICGaussSeidel", "nonBlockingGaussSeidel"]
    public static let preconditionerChoices = ["DIC", "FDIC", "DILU", "GAMG", "none"]
}

// MARK: - Schemes

/// fvSchemes overrides. An empty string means "derive from FluidCraft's Methods page"; any other
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
    /// Fields computed from expressions by OpenFOAM (exprField).
    public var expressionFields: [FoamExpressionField] = []
    /// Cell distributions of fields (histogram).
    public var histograms: [FoamHistogram] = []
    /// Wall heat-transfer coefficient (heatTransferCoeff).
    public var heatTransferCoeff = FoamHeatTransferCoeff()
    /// Python scripts run on the solution through FluidCraft's `fluidcraft_post` module.
    public var scripts: [FoamPostScript] = []
    public init() {}

    private enum K: String, CodingKey {
        case functions, lineSamples, isoSurfaces, streamlineSeedStart, streamlineSeedEnd, streamlineSeeds, exportVTK, exportEnsight, afterSolve
        case expressionFields, histograms, heatTransferCoeff, scripts
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamPostProcessing()
        functions = c.lenient(.functions, []); lineSamples = c.lenient(.lineSamples, []); isoSurfaces = c.lenient(.isoSurfaces, [])
        streamlineSeedStart = c.lenient(.streamlineSeedStart, nil); streamlineSeedEnd = c.lenient(.streamlineSeedEnd, z.streamlineSeedEnd)
        streamlineSeeds = c.lenient(.streamlineSeeds, z.streamlineSeeds); exportVTK = c.lenient(.exportVTK, false)
        exportEnsight = c.lenient(.exportEnsight, false); afterSolve = c.lenient(.afterSolve, true)
        expressionFields = c.lenient(.expressionFields, []); histograms = c.lenient(.histograms, [])
        heatTransferCoeff = c.lenient(.heatTransferCoeff, z.heatTransferCoeff); scripts = c.lenient(.scripts, [])
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(functions, forKey: .functions); try c.encode(lineSamples, forKey: .lineSamples); try c.encode(isoSurfaces, forKey: .isoSurfaces)
        try c.encodeIfPresent(streamlineSeedStart, forKey: .streamlineSeedStart); try c.encode(streamlineSeedEnd, forKey: .streamlineSeedEnd)
        try c.encode(streamlineSeeds, forKey: .streamlineSeeds); try c.encode(exportVTK, forKey: .exportVTK); try c.encode(exportEnsight, forKey: .exportEnsight)
        try c.encode(afterSolve, forKey: .afterSolve); try c.encode(expressionFields, forKey: .expressionFields); try c.encode(histograms, forKey: .histograms)
        try c.encode(heatTransferCoeff, forKey: .heatTransferCoeff); try c.encode(scripts, forKey: .scripts)
    }

    /// Function objects offered in the app (each runs through `<solver> -postProcess`).
    public static let availableFunctions: [(name: String, title: String)] = [
        ("vorticity", "Vorticity"), ("Q", "Q criterion"), ("Lambda2", "λ₂ vortex criterion"), ("enstrophy", "Enstrophy"),
        ("CourantNo", "Courant number"), ("PecletNo", "Péclet number"), ("MachNo", "Mach number (compressible)"),
        ("wallShearStress", "Wall shear stress"), ("yPlus", "y⁺"), ("wallHeatFlux", "Wall heat flux (heat transfer)"),
        ("streamFunction", "Stream function (2D)"), ("flowType", "Flow type (shear / rotation)"), ("writeCellCentres", "Cell centres"),
        ("writeCellVolumes", "Cell volumes"), ("turbulenceFields", "Turbulence fields (k, ε, ω, νt, R)"),
        ("age", "Mean age of air (ventilation; computed during the solve)"), ("comfort", "Thermal comfort PMV / PPD (needs T)"),
        ("LambVector", "Lamb vector (U × ω)"), ("continuityError", "Continuity error"), ("momentum", "Momentum and angular momentum"),
    ]
    /// Functions that need the solver's flux and run during the solve (at each write) instead.
    public static let duringSolveFunctions: Set<String> = ["age"]
    /// OpenFOAM function objects that run in the post-processing dictionary (not needing settings).
    public var runsOpenFOAMFunctions: Bool {
        !(functions.isEmpty && lineSamples.isEmpty && isoSurfaces.isEmpty && streamlineSeedStart == nil && expressionFields.isEmpty
          && histograms.isEmpty && !heatTransferCoeff.enabled)
    }
    public var isEmpty: Bool {
        !runsOpenFOAMFunctions && !exportVTK && !exportEnsight && scripts.isEmpty
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

/// Everything OpenFOAM needs beyond the shared FluidCraft setup. Every field has a
/// default that reproduces the FluidCraft setup as closely as OpenFOAM allows; the rest of the
/// knobs are what an OpenFOAM user edits in `system/` and `constant/` by hand.
public struct FoamSettings: Codable, Sendable, Equatable {
    // Installation and case location
    /// `.app` bundle, tree root or `etc/bashrc`; empty = the newest one found.
    public var installation = ""
    /// Case directory; empty = `~/FluidCraft/<title>`. OpenFOAM rejects paths with spaces.
    public var caseDirectory = ""

    // Physics
    public var application: FoamApplication = .automatic
    public var turbulence: FoamTurbulenceModel = .fromFluidCraft
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
    public var initialFields: FoamInitialFields = .fluidcraft

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

    /// Thermal radiation.
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
    /// Read the latest time back into FluidCraft when the run ends (and at each write).
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

    // Run control (more)
    /// writeControl; `writeEvery` is the interval for the time-based modes [s].
    public var writeControl: FoamWriteControl = .automatic
    public var writeEvery = 0.1
    /// Pressure reference where no boundary fixes the pressure (pRefPoint / pRefValue); nil = cell 0, 0.
    public var pressureReferencePoint: [Double]? = nil
    public var pressureReferenceValue = 0.0
    /// hierarchical/simple decomposition: subdomains along x, y, z (nil = split the longest axis first) and order.
    public var decompositionSplit: [Int]? = nil
    public var decompositionOrder = "xyz"

    // Models (more)
    /// Turbulence-model coefficients written into `<model>Coeffs` (e.g. Cmu, betaStar, Cs).
    public var turbulenceCoefficients: [String: Double] = [:]
    /// Thermophysical model (thermophysical solvers).
    public var thermo = FoamThermoSettings()
    /// OpenFOAM boundary conditions chosen per patch (patch name → options).
    public var patchOptions: [String: FoamPatchOptions] = [:]
    /// fvOptions and constraints without a FluidCraft Cell Zone model.
    public var fvOptions: [FoamFvOption] = []
    /// Time averaging of transient runs.
    public var fieldAverage = FoamFieldAverage()
    /// Adaptive refinement of hexahedral meshes in transient runs.
    public var adaptiveRefinement = FoamAdaptiveRefinement()

    public init() {}

    /// Options for one patch (defaults when none were set).
    public func options(forPatch name: String) -> FoamPatchOptions { patchOptions[name] ?? FoamPatchOptions() }

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
        check("decomposition order", decompositionOrder)
        check("write format", writeFormat)
        for k in turbulenceCoefficients.keys where !(k.first?.isLetter ?? false) || !k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            bad.append("turbulence coefficient name: \(k.prefix(60))")
        }
        for e in postProcessing.expressionFields where !e.isSafe { bad.append("expression \(e.name): \(e.expression.prefix(60))") }
        if adaptiveRefinement.enabled && adaptiveRefinement.isExpression
            && !FoamExpressionField(name: "refinementIndicator", expression: adaptiveRefinement.field).isSafe {
            bad.append("refinement expression: \(adaptiveRefinement.field.prefix(60))")
        }
        for (n, l) in [("pressure", pressureSolver), ("velocity", velocitySolver), ("turbulence", turbulenceSolver), ("energy", energySolver)] {
            check("\(n) solver", l.solver); check("\(n) smoother", l.smoother); check("\(n) preconditioner", l.preconditioner)
        }
        return bad
    }

    /// Settings that make OpenFOAM run something other than the case FluidCraft generates: extra
    /// stages, raw function objects (e.g. `systemCall`), dictionary text (e.g. `#codeStream`),
    /// raw boundary conditions (e.g. `codedFixedValue`) and extra files. A case opened from
    /// disk shows these to the user before it is run. Empty when there are none.
    public var activeContent: [String] {
        activeContentItems.map { item in
            let code = FoamSettings.codeConstructs(in: item.text)
            let preview = item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            let python = item.title.hasPrefix("Python")
            return (python ? "⚠️ runs Python code — " : (code.isEmpty ? "" : "⚠️ runs code (\(code.joined(separator: ", "))) — ")) + item.title + (preview.isEmpty ? "" : ": \(preview)")
        }
    }

    /// Every custom item with its full text (for a complete review before running).
    public var activeContentItems: [(title: String, text: String)] {
        var out: [(String, String)] = []
        for c in customStages where !c.command.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(("Stage (\(c.phase == .beforeSolve ? "before" : "after") solve)", c.command))
        }
        if !customFunctions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(("Function objects in controlDict", customFunctions)) }
        for (p, t) in dictionaryAppends.sorted(by: { $0.key < $1.key }) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(("Appended to \(p)", t))
        }
        for o in patchOverrides { out.append(("Raw boundary condition \(o.field) on \(o.patch)", o.text)) }
        // extra files are written after the generated ones, so one may also replace a generated file
        for p in extraFiles.keys.sorted() { out.append(("Extra file \(p) (replaces the generated file of that name, if any)", extraFiles[p]!)) }
        for p in fileOverrides.keys.sorted() { out.append(("Replaced file \(p)", fileOverrides[p]!)) }
        // post-processing scripts are Python programs: they always need the user's approval
        for sc in postProcessing.scripts where !sc.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(("Python post-processing script \(sc.name)\(sc.afterSolve ? " (runs after the solve)" : "")", sc.code))
        }
        return out
    }

    /// All custom content as one text, every item in full.
    public var activeContentFullText: String {
        activeContentItems.map { item in
            let code = FoamSettings.codeConstructs(in: item.text)
            let python = item.title.hasPrefix("Python")
            return "=== \(item.title)" + (python ? "   ⚠️ runs Python code" : (code.isEmpty ? "" : "   ⚠️ runs code: \(code.joined(separator: ", "))")) + "\n" + item.text
        }.joined(separator: "\n\n")
    }

    /// OpenFOAM constructs in `text` that compile, load or run code: dictionary directives that
    /// compile C++ or evaluate, coded conditions and function objects, system calls, libraries.
    public static func codeConstructs(in text: String) -> [String] {
        let checks: [(String, String)] = [
            ("#codeStream", "#codestream"), ("#calc", "#calc"), ("#include", "#include"), ("#eval", "#eval"),
            ("systemCall", "systemcall"), ("coded condition or function object", "coded"), ("code block", "code"),
            ("library loading (libs)", "libs"), ("$ variable expansion", "$"),
        ]
        let t = text.lowercased()
        return checks.filter { needle in
            needle.1 == "code" ? t.range(of: #"\bcode(include|options|libs)?\b"#, options: .regularExpression) != nil
                               : t.contains(needle.1)
        }.map(\.0)
    }
}
