import Foundation
import FluidCraftMesh

// OpenFOAM settings beyond the core set in FoamSettings.swift: run control, per-patch
// conditions, thermophysical models, fvOptions, function objects, adaptive refinement and
// post-processing scripts. Everything here is written into OpenFOAM dictionaries; FluidCraft only
// chooses the OpenFOAM keywords and values.

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing or unreadable (old case files).
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? fallback }
}

// MARK: - Run control

/// When OpenFOAM writes time directories (controlDict writeControl).
public enum FoamWriteControl: String, Codable, CaseIterable, Sendable {
    /// Every N steps, or every N × Δt of simulated time with an adjustable time step.
    case automatic
    case timeStep, runTime, adjustableRunTime, clockTime, cpuTime

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (every N steps)"
        case .timeStep: return "Every N time steps"
        case .runTime: return "Every interval of simulated time"
        case .adjustableRunTime: return "Every interval of simulated time (time step adjusted to hit it)"
        case .clockTime: return "Every interval of wall-clock time"
        case .cpuTime: return "Every interval of CPU time"
        }
    }
}

// MARK: - Per-patch conditions

/// An OpenFOAM boundary condition chosen for one patch instead of the one FluidCraft derives
/// from the Boundary Conditions page.
public enum FoamPatchCondition: String, Codable, CaseIterable, Sendable {
    case automatic
    /// Inlets: volumetric flow rate [m³/s] (flowRateInletVelocity).
    case volumetricFlowRate
    /// Inlets: synthetic eddies for LES/DES inflow (turbulentDFSEMInlet).
    case syntheticTurbulence
    /// Inlets: velocity profile read from a CSV file x,y,z,Ux,Uy,Uz (timeVaryingMappedFixedValue).
    case profileFromFile
    /// Pressure inlets and outlets: pressure from a fan curve (fanPressure).
    case fanCurve
    /// Outlets: non-reflecting (advective, or waveTransmissive for compressible solvers).
    case nonReflecting
    /// Walls: sand-grain roughness (nutkRoughWallFunction).
    case roughWall

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (from the Boundary Conditions page)"
        case .volumetricFlowRate: return "Volumetric flow rate (flowRateInletVelocity)"
        case .syntheticTurbulence: return "Synthetic turbulent inflow for LES (turbulentDFSEMInlet)"
        case .profileFromFile: return "Velocity profile from a CSV file (timeVaryingMappedFixedValue)"
        case .fanCurve: return "Fan curve (fanPressure)"
        case .nonReflecting: return "Non-reflecting outlet (advective / waveTransmissive)"
        case .roughWall: return "Sand-grain rough wall (nutkRoughWallFunction)"
        }
    }

    /// The patch kinds the condition applies to.
    public func applies(to kind: ZoneKind) -> Bool {
        switch self {
        case .automatic: return true
        case .volumetricFlowRate, .syntheticTurbulence, .profileFromFile: return kind == .velocityInlet || kind == .massFlowInlet
        case .fanCurve: return kind == .pressureInlet || kind == .pressureOutlet
        case .nonReflecting: return kind == .pressureOutlet || kind == .pressureFarField
        case .roughWall: return kind == .wall
        }
    }
}

public struct FoamPatchOptions: Codable, Sendable, Equatable {
    public var condition: FoamPatchCondition = .automatic
    /// volumetricFlowRate [m³/s].
    public var volumetricFlowRate = 0.0
    /// Synthetic turbulence: intensity (fraction of the inlet speed), integral length scale [m]
    /// and the inflow's characteristic height δ [m] (boundary-layer or channel half height).
    public var turbulenceIntensity = 0.05
    public var lengthScale = 0.01
    public var delta = 0.1
    /// Profile file: CSV with columns x, y, z, Ux, Uy, Uz (a header line is skipped).
    public var profileFile = ""
    /// Fan curve: (volume flow [m³/s], total-pressure rise [Pa]) points, flow increasing.
    public var fanCurve: [[Double]] = [[0, 300], [0.05, 200], [0.1, 0]]
    /// Non-reflecting: distance to the far-field state [m] (lInf; 0 = purely advective).
    public var farFieldDistance = 0.0
    /// Rough wall: sand-grain roughness height Ks [m] and roughness constant Cs.
    public var roughnessHeight = 0.0
    public var roughnessConstant = 0.5

    public init(condition: FoamPatchCondition = .automatic) { self.condition = condition }

    private enum K: String, CodingKey {
        case condition, volumetricFlowRate, turbulenceIntensity, lengthScale, delta, profileFile, fanCurve, farFieldDistance, roughnessHeight, roughnessConstant
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamPatchOptions()
        condition = c.lenient(.condition, z.condition)
        volumetricFlowRate = c.lenient(.volumetricFlowRate, z.volumetricFlowRate)
        turbulenceIntensity = c.lenient(.turbulenceIntensity, z.turbulenceIntensity)
        lengthScale = c.lenient(.lengthScale, z.lengthScale)
        delta = c.lenient(.delta, z.delta)
        profileFile = c.lenient(.profileFile, z.profileFile)
        fanCurve = c.lenient(.fanCurve, z.fanCurve)
        farFieldDistance = c.lenient(.farFieldDistance, z.farFieldDistance)
        roughnessHeight = c.lenient(.roughnessHeight, z.roughnessHeight)
        roughnessConstant = c.lenient(.roughnessConstant, z.roughnessConstant)
    }
}

// MARK: - Thermophysical models

/// Temperature-dependent properties and real-gas equations of state for thermophysical
/// solvers (constant/thermophysicalProperties). `automatic` keeps what the Materials page
/// gives (constant or Sutherland viscosity, constant Cp, the density method).
public struct FoamThermoSettings: Codable, Sendable, Equatable {
    public enum Transport: String, Codable, CaseIterable, Sendable { case automatic, const, sutherland, polynomial }
    public enum Thermo: String, Codable, CaseIterable, Sendable { case hConst, janaf, hPolynomial }
    public enum EquationOfState: String, Codable, CaseIterable, Sendable {
        case automatic, perfectGas, incompressiblePerfectGas, rhoConst, perfectFluid, PengRobinsonGas, icoPolynomial, Boussinesq
    }

    public var transport: Transport = .automatic
    public var thermo: Thermo = .hConst
    public var equationOfState: EquationOfState = .automatic

    /// JANAF (NASA 7-coefficient) Cp/R polynomials and their temperature ranges [K].
    public var janafTlow = 200.0
    public var janafThigh = 3500.0
    public var janafTcommon = 1000.0
    public var highCpCoeffs: [Double] = FoamThermoSettings.airJanafHigh
    public var lowCpCoeffs: [Double] = FoamThermoSettings.airJanafLow
    /// hPolynomial: Cp(T) = Σ aᵢ Tⁱ [J/(kg K)], formation enthalpy and entropy.
    public var cpCoeffs: [Double] = [1005, 0, 0, 0, 0, 0, 0, 0]
    public var formationEnthalpy = 0.0
    public var formationEntropy = 0.0
    /// polynomial transport: μ(T) [Pa s] and κ(T) [W/(m K)] coefficients.
    public var muCoeffs: [Double] = [1.8e-5, 0, 0, 0, 0, 0, 0, 0]
    public var kappaCoeffs: [Double] = [0.0262, 0, 0, 0, 0, 0, 0, 0]
    /// Peng–Robinson: critical temperature [K], pressure [Pa], molar volume [m³/kmol], acentric factor.
    public var criticalTemperature = 132.5
    public var criticalPressure = 3.77e6
    public var criticalVolume = 0.0883
    public var acentricFactor = 0.035
    /// icoPolynomial density ρ(T) [kg/m³] coefficients.
    public var rhoCoeffs: [Double] = [1000, 0, 0, 0, 0, 0, 0, 0]
    /// perfectFluid: ρ = ρ₀ + p/(R T); R [J/(kg K)], ρ₀ [kg/m³].
    public var perfectFluidR = 3000.0
    public var perfectFluidRho0 = 1027.0

    public init() {}
    public var isAutomatic: Bool { transport == .automatic && thermo == .hConst && equationOfState == .automatic }

    /// NASA polynomials for air, as in OpenFOAM's bubbleColumnEvaporating tutorial.
    public static let airJanafHigh = [3.57304, -7.24383e-04, 1.67022e-06, -1.26501e-10, -4.20580e-13, -1047.41, 3.12431]
    public static let airJanafLow = [3.09589, 1.22835e-03, -4.14267e-07, 6.56910e-11, -3.87021e-15, -983.191, 5.34161]

    /// thermoType combinations compiled into OpenFOAM v2606 (pureMixture, specie):
    /// "transport,energy,thermo,equationOfState".
    public static let rhoThermoTypes: Set<String> = [
        "const,sensibleEnthalpy,hConst,Boussinesq", "const,sensibleEnthalpy,hConst,incompressiblePerfectGas", "const,sensibleEnthalpy,hConst,perfectFluid",
        "const,sensibleEnthalpy,hConst,perfectGas", "const,sensibleEnthalpy,hConst,rhoConst", "const,sensibleInternalEnergy,hConst,Boussinesq",
        "const,sensibleInternalEnergy,hConst,incompressiblePerfectGas", "const,sensibleInternalEnergy,hConst,perfectFluid", "const,sensibleInternalEnergy,hConst,perfectGas",
        "const,sensibleInternalEnergy,hConst,rhoConst",
        "polynomial,sensibleEnthalpy,hPolynomial,PengRobinsonGas", "polynomial,sensibleEnthalpy,hPolynomial,icoPolynomial", "polynomial,sensibleEnthalpy,hPolynomial,incompressiblePerfectGas",
        "polynomial,sensibleEnthalpy,hPolynomial,perfectGas", "polynomial,sensibleEnthalpy,janaf,PengRobinsonGas", "polynomial,sensibleInternalEnergy,hPolynomial,icoPolynomial",
        "sutherland,sensibleEnthalpy,hConst,Boussinesq", "sutherland,sensibleEnthalpy,hConst,PengRobinsonGas", "sutherland,sensibleEnthalpy,hConst,incompressiblePerfectGas",
        "sutherland,sensibleEnthalpy,hConst,perfectGas", "sutherland,sensibleEnthalpy,janaf,Boussinesq", "sutherland,sensibleEnthalpy,janaf,incompressiblePerfectGas",
        "sutherland,sensibleEnthalpy,janaf,perfectGas", "sutherland,sensibleInternalEnergy,hConst,Boussinesq", "sutherland,sensibleInternalEnergy,hConst,incompressiblePerfectGas",
        "sutherland,sensibleInternalEnergy,hConst,perfectGas", "sutherland,sensibleInternalEnergy,janaf,Boussinesq", "sutherland,sensibleInternalEnergy,janaf,incompressiblePerfectGas",
        "sutherland,sensibleInternalEnergy,janaf,perfectGas",
    ]
    public static let psiThermoTypes: Set<String> = [
        "const,sensibleEnthalpy,hConst,perfectGas", "const,sensibleInternalEnergy,hConst,perfectGas",
        "polynomial,sensibleEnthalpy,hPolynomial,PengRobinsonGas", "polynomial,sensibleEnthalpy,janaf,PengRobinsonGas",
        "sutherland,sensibleEnthalpy,hConst,PengRobinsonGas", "sutherland,sensibleEnthalpy,hConst,perfectGas", "sutherland,sensibleEnthalpy,janaf,PengRobinsonGas",
        "sutherland,sensibleEnthalpy,janaf,perfectGas", "sutherland,sensibleInternalEnergy,hConst,perfectGas", "sutherland,sensibleInternalEnergy,janaf,PengRobinsonGas",
        "sutherland,sensibleInternalEnergy,janaf,perfectGas",
    ]

    private enum K: String, CodingKey {
        case transport, thermo, equationOfState, janafTlow, janafThigh, janafTcommon, highCpCoeffs, lowCpCoeffs, cpCoeffs, formationEnthalpy, formationEntropy
        case muCoeffs, kappaCoeffs, criticalTemperature, criticalPressure, criticalVolume, acentricFactor, rhoCoeffs, perfectFluidR, perfectFluidRho0
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamThermoSettings()
        transport = c.lenient(.transport, z.transport); thermo = c.lenient(.thermo, z.thermo)
        equationOfState = c.lenient(.equationOfState, z.equationOfState)
        janafTlow = c.lenient(.janafTlow, z.janafTlow); janafThigh = c.lenient(.janafThigh, z.janafThigh); janafTcommon = c.lenient(.janafTcommon, z.janafTcommon)
        highCpCoeffs = c.lenient(.highCpCoeffs, z.highCpCoeffs); lowCpCoeffs = c.lenient(.lowCpCoeffs, z.lowCpCoeffs)
        cpCoeffs = c.lenient(.cpCoeffs, z.cpCoeffs); formationEnthalpy = c.lenient(.formationEnthalpy, z.formationEnthalpy)
        formationEntropy = c.lenient(.formationEntropy, z.formationEntropy)
        muCoeffs = c.lenient(.muCoeffs, z.muCoeffs); kappaCoeffs = c.lenient(.kappaCoeffs, z.kappaCoeffs)
        criticalTemperature = c.lenient(.criticalTemperature, z.criticalTemperature); criticalPressure = c.lenient(.criticalPressure, z.criticalPressure)
        criticalVolume = c.lenient(.criticalVolume, z.criticalVolume); acentricFactor = c.lenient(.acentricFactor, z.acentricFactor)
        rhoCoeffs = c.lenient(.rhoCoeffs, z.rhoCoeffs); perfectFluidR = c.lenient(.perfectFluidR, z.perfectFluidR)
        perfectFluidRho0 = c.lenient(.perfectFluidRho0, z.perfectFluidRho0)
    }
}

// MARK: - fvOptions

/// A blade-element rotor (rotorDisk): lift and drag from airfoil tables applied in a cell zone.
public struct FoamRotorDisk: Codable, Sendable, Equatable {
    public var blades = 3
    public var rpm = 15.0
    public var origin: [Double] = [0, 0, 0]
    /// Rotation axis (right-hand rule), and the blade-angle reference direction (⊥ axis).
    public var axis: [Double] = [1, 0, 0]
    public var referenceDirection: [Double] = [0, 0, 1]
    /// Normalised radius above which lift is zero (tip loss).
    public var tipEffect = 0.96
    /// Collective pitch θ₀ [deg] (fixedTrim).
    public var collectivePitch = 0.0
    /// Blade sections: (radius [m], twist [deg], chord [m]), radius increasing.
    public var sections: [[Double]] = [[5, 20, 3], [20, 8, 2.5], [40, 2, 1.5], [60, 0, 0.8]]
    /// Airfoil table: (angle of attack [deg], Cd, Cl), angle increasing. Default: OpenFOAM's
    /// rotorDisk tutorial profile.
    public var profile: [[Double]] = FoamRotorDisk.tutorialProfile
    public init() {}

    public static let tutorialProfile: [[Double]] = [
        [-90, 0.21, 1.45], [-18, 0.21, 1.45], [-16, 0.165, 1.3], [-14, 0.125, 1.1], [-12, 0.092, 0.95], [-10, 0.07, 0.8],
        [-8, 0.05, 0.64], [-6, 0.04, 0.5], [-4, 0.028, 0.32], [-2, 0.022, 0.18], [0, 0.02, 0], [2, 0.022, 0.18],
        [4, 0.028, 0.32], [6, 0.04, 0.5], [8, 0.05, 0.64], [10, 0.07, 0.8], [12, 0.092, 0.95], [14, 0.125, 1.1],
        [16, 0.165, 1.3], [18, 0.21, 1.45], [90, 0.21, 1.45],
    ]

    private enum K: String, CodingKey { case blades, rpm, origin, axis, referenceDirection, tipEffect, collectivePitch, sections, profile }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamRotorDisk()
        blades = c.lenient(.blades, z.blades); rpm = c.lenient(.rpm, z.rpm); origin = c.lenient(.origin, z.origin)
        axis = c.lenient(.axis, z.axis); referenceDirection = c.lenient(.referenceDirection, z.referenceDirection)
        tipEffect = c.lenient(.tipEffect, z.tipEffect); collectivePitch = c.lenient(.collectivePitch, z.collectivePitch)
        sections = c.lenient(.sections, z.sections); profile = c.lenient(.profile, z.profile)
    }
}

/// An fvOption or fvConstraint that FluidCraft's Cell Zone pages have no model for.
public struct FoamFvOption: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Hold the temperature of a zone fixed (fixedTemperatureConstraint).
        case fixedTemperature
        /// Damp velocities above a limit instead of clipping them (velocityDampingConstraint).
        case velocityDamping
        /// Blade-element rotor (rotorDisk).
        case rotorDisk

        public var displayName: String {
            switch self {
            case .fixedTemperature: return "Fixed temperature (fixedTemperatureConstraint)"
            case .velocityDamping: return "Velocity damping (velocityDampingConstraint)"
            case .rotorDisk: return "Rotor, blade-element model (rotorDisk)"
            }
        }
    }
    public var id: String { name }
    public var name = "option1"
    public var kind: Kind = .fixedTemperature
    /// Cell zone it acts in; empty = the whole domain.
    public var zone = ""
    public var temperature = 300.0
    public var maximumVelocity = 100.0
    public var rotor = FoamRotorDisk()
    public init(name: String = "option1", kind: Kind = .fixedTemperature) { self.name = name; self.kind = kind }

    private enum K: String, CodingKey { case name, kind, zone, temperature, maximumVelocity, rotor }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamFvOption()
        name = c.lenient(.name, z.name); kind = c.lenient(.kind, z.kind); zone = c.lenient(.zone, z.zone)
        temperature = c.lenient(.temperature, z.temperature); maximumVelocity = c.lenient(.maximumVelocity, z.maximumVelocity)
        rotor = c.lenient(.rotor, z.rotor)
    }
}

// MARK: - Function objects

/// Time averaging of transient runs (fieldAverage).
public struct FoamFieldAverage: Codable, Sendable, Equatable {
    /// nil = on when Run Calculation's data sampling is on.
    public var enabled: Bool? = nil
    /// Fields to average (OpenFOAM names, space separated).
    public var fields = "U p"
    /// Also accumulate the variance ⟨φ'φ'⟩ (Reynolds stresses for U).
    public var prime2Mean = true
    /// Start averaging at this time [s] (0 = from the start).
    public var startTime = 0.0
    /// Averaging window [s] (0 = whole run).
    public var window = 0.0
    public init() {}
    private enum K: String, CodingKey { case enabled, fields, prime2Mean, startTime, window }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamFieldAverage()
        enabled = c.lenient(.enabled, z.enabled); fields = c.lenient(.fields, z.fields); prime2Mean = c.lenient(.prime2Mean, z.prime2Mean)
        startTime = c.lenient(.startTime, z.startTime); window = c.lenient(.window, z.window)
    }
}

/// A field computed by OpenFOAM from an expression (exprField), e.g. `mag(U)` or `p + 0.5*magSqr(U)`.
public struct FoamExpressionField: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name = "magU"
    public var expression = "mag(U)"
    /// Evaluate while solving (every write) as well as in post-processing.
    public var duringRun = false
    public init(name: String = "magU", expression: String = "mag(U)") { self.name = name; self.expression = expression }
    private enum K: String, CodingKey { case name, expression, duringRun }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        name = c.lenient(.name, "field"); expression = c.lenient(.expression, ""); duringRun = c.lenient(.duringRun, false)
    }

    /// The expression is written inside quotes: quotes, directives, variables and line breaks
    /// are refused (they could end the string and add dictionary entries).
    public var isSafe: Bool {
        !expression.isEmpty && !expression.contains { "\"#$;{}\\\n\r".contains($0) } && expression.count < 2000
    }

    /// Identifiers the expression reads as fields (not followed by "(").
    public var referencedFields: [String] {
        var out: [String] = [], seen = Set<String>()
        let s = Array(expression)
        var i = 0
        while i < s.count {
            if s[i].isLetter || s[i] == "_" {
                var j = i
                while j < s.count, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "." { j += 1 }
                let word = String(s[i..<j])
                var k = j
                while k < s.count, s[k] == " " { k += 1 }
                let isCall = k < s.count && s[k] == "("
                let isMember = i > 0 && s[i - 1] == "."
                if !isCall && !isMember && !["pi", "true", "false", "e"].contains(word) && seen.insert(word).inserted { out.append(word) }
                i = j
            } else if s[i].isNumber {
                // skip number literals such as 1e-5
                var j = i
                while j < s.count, s[j].isNumber || s[j] == "." || s[j] == "e" || s[j] == "E" || ((s[j] == "-" || s[j] == "+") && j > i && (s[j - 1] == "e" || s[j - 1] == "E")) { j += 1 }
                i = j
            } else { i += 1 }
        }
        return out
    }
}

/// Distribution of a field over the cells (histogram).
public struct FoamHistogram: Codable, Sendable, Equatable, Identifiable {
    public var id: String { field }
    public var field = "p"
    public var bins = 20
    public init(field: String = "p", bins: Int = 20) { self.field = field; self.bins = bins }
    private enum K: String, CodingKey { case field, bins }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); field = c.lenient(.field, "p"); bins = c.lenient(.bins, 20)
    }
}

/// Heat-transfer coefficient on walls (heatTransferCoeff).
public struct FoamHeatTransferCoeff: Codable, Sendable, Equatable {
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// h = q / (T_wall − T_ref) with a fixed reference temperature.
        case fixedReferenceTemperature
        /// h = q / (T_wall − T_cell) with the near-wall cell temperature.
        case localReferenceTemperature
        /// h from the skin friction (Reynolds analogy).
        case ReynoldsAnalogy
    }
    public var enabled = false
    public var model: Model = .fixedReferenceTemperature
    /// Walls (empty = every wall).
    public var patches: [String] = []
    public var referenceTemperature = 293.15
    public init() {}
    private enum K: String, CodingKey { case enabled, model, patches, referenceTemperature }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamHeatTransferCoeff()
        enabled = c.lenient(.enabled, false); model = c.lenient(.model, z.model); patches = c.lenient(.patches, [])
        referenceTemperature = c.lenient(.referenceTemperature, z.referenceTemperature)
    }
}

// MARK: - Adaptive mesh refinement

/// Refine and unrefine hexahedral cells during a transient run where a field lies in a band
/// (dynamicRefineFvMesh).
public struct FoamAdaptiveRefinement: Codable, Sendable, Equatable {
    public var enabled = false
    /// A scalar field name (e.g. `p`, `T`, `k`) or an expression such as `mag(U)`.
    public var field = "mag(U)"
    /// Refine cells with lowerLevel ≤ field ≤ upperLevel; unrefine below unrefineLevel.
    public var lowerLevel = 0.5
    public var upperLevel = 1e9
    public var unrefineLevel = 0.1
    public var refineInterval = 10
    public var maxRefinement = 2
    public var maxCells = 2_000_000
    public var bufferLayers = 1
    public init() {}

    /// The field is an expression rather than a field name.
    public var isExpression: Bool { !field.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } }

    private enum K: String, CodingKey { case enabled, field, lowerLevel, upperLevel, unrefineLevel, refineInterval, maxRefinement, maxCells, bufferLayers }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self), z = FoamAdaptiveRefinement()
        enabled = c.lenient(.enabled, false); field = c.lenient(.field, z.field); lowerLevel = c.lenient(.lowerLevel, z.lowerLevel)
        upperLevel = c.lenient(.upperLevel, z.upperLevel); unrefineLevel = c.lenient(.unrefineLevel, z.unrefineLevel)
        refineInterval = c.lenient(.refineInterval, z.refineInterval); maxRefinement = c.lenient(.maxRefinement, z.maxRefinement)
        maxCells = c.lenient(.maxCells, z.maxCells); bufferLayers = c.lenient(.bufferLayers, z.bufferLayers)
    }
}

// MARK: - Post-processing scripts

/// A Python script run on the solution with FluidCraft's `fluidcraft_post` module (numpy arrays of
/// every field, patch geometry, function-object output, reports back to FluidCraft, new fields
/// written back into the case). Scripts are the user's own code: they run only when the user
/// runs them, or after the solve once the case content has been approved.
public struct FoamPostScript: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name = "script1"
    public var code = ""
    /// Run after each solve (with the OpenFOAM post-processing).
    public var afterSolve = false
    public init(name: String = "script1", code: String = "") { self.name = name; self.code = code }
    private enum K: String, CodingKey { case name, code, afterSolve }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        name = c.lenient(.name, "script"); code = c.lenient(.code, ""); afterSolve = c.lenient(.afterSolve, false)
    }

    /// A file name for the script (letters, digits, `_` and `-` only).
    public var fileName: String {
        let base = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(60))
        return (base.isEmpty ? "script" : base) + ".py"
    }
    /// Name of the script's output folder (and the key of its last result).
    public var outputName: String { String(fileName.dropLast(3)) }
}
