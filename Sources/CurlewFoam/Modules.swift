import Foundation
import CurlewMesh
import CurlewSolver

/// The big groups shown along the top of the window. Each module belongs to exactly one.
public enum ModuleCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case windEnergy, electronicsCooling, generalCFD, processing, machineLearning

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .windEnergy: return "Wind Energy"
        case .electronicsCooling: return "Electronics Cooling"
        case .generalCFD: return "General CFD & CAD"
        case .processing: return "Pre & Post-Processing"
        case .machineLearning: return "AI & Machine Learning"
        }
    }
    public var symbol: String {
        switch self {
        case .windEnergy: return "wind"
        case .electronicsCooling: return "cpu"
        case .generalCFD: return "cube.transparent"
        case .processing: return "slider.horizontal.below.square.and.square.filled"
        case .machineLearning: return "brain"
        }
    }
    public var modules: [AppModule] { AppModule.allCases.filter { $0.category == self } }
}

/// A selectable, configurable application module.
public enum AppModule: String, CaseIterable, Codable, Sendable, Identifiable {
    case windFarm, windTurbineRotor
    case airCooledHeatSink, liquidColdPlate
    case cadAnalysis, tutorials, customCase
    case preProcessing, postProcessing
    case pinn, aiAssistant

    /// Older saved names (the CAD analysis types were three modules once).
    public init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        if let m = AppModule(rawValue: raw) { self = m; return }
        self = ["cadExternal", "cadInternal", "cadConjugate"].contains(raw) ? .cadAnalysis : .customCase
    }

    public var id: String { rawValue }
    public var category: ModuleCategory {
        switch self {
        case .windFarm, .windTurbineRotor: return .windEnergy
        case .airCooledHeatSink, .liquidColdPlate: return .electronicsCooling
        case .cadAnalysis, .tutorials, .customCase: return .generalCFD
        case .preProcessing, .postProcessing: return .processing
        case .pinn, .aiAssistant: return .machineLearning
        }
    }
    public var title: String {
        switch self {
        case .windFarm: return "Wind Farm (actuator disks)"
        case .windTurbineRotor: return "Wind-Turbine Rotor (MRF)"
        case .airCooledHeatSink: return "Air-Cooled Heat Sink"
        case .liquidColdPlate: return "Liquid Cold Plate"
        case .cadAnalysis: return "CAD Import & Analysis"
        case .tutorials: return "Tutorials & Validation"
        case .customCase: return "Custom Case"
        case .preProcessing: return "Pre-Processing (OpenFOAM utilities)"
        case .postProcessing: return "Post-Processing (OpenFOAM utilities)"
        case .pinn: return "Physics-Informed Neural Network"
        case .aiAssistant: return "AI Assistant"
        }
    }
    public var symbol: String {
        switch self {
        case .windFarm: return "wind"
        case .windTurbineRotor: return "fanblades"
        case .airCooledHeatSink: return "fan"
        case .liquidColdPlate: return "drop.degreesign"
        case .cadAnalysis: return "cube.transparent"
        case .tutorials: return "book"
        case .customCase: return "slider.horizontal.3"
        case .preProcessing: return "square.and.arrow.down.on.square"
        case .postProcessing: return "chart.xyaxis.line"
        case .pinn: return "point.3.connected.trianglepath.dotted"
        case .aiAssistant: return "sparkles"
        }
    }
    public var summary: String {
        switch self {
        case .windFarm: return "A grid of turbines as actuator disks (OpenFOAM actuationDiskSource) in a neutral atmospheric boundary layer over rough terrain. Wake losses per turbine."
        case .windTurbineRotor: return "A resolved rotor (lofted NACA blades and hub) turning in a cylindrical MRF zone: torque, power coefficient and thrust."
        case .airCooledHeatSink: return "A chip on a circuit board under a plate-fin heat sink in an air duct: conjugate heat transfer (chtMultiRegionSimpleFoam)."
        case .liquidColdPlate: return "A chip under a cold plate with parallel coolant channels and manifolds: chip temperature, coolant temperature rise and pressure drop."
        case .cadAnalysis: return "Import your CAD model (STEP, IGES, STL, …) or a sample, choose external aerodynamics, internal flow or a conjugate heat sink, and get a meshed, ready-to-run OpenFOAM case."
        case .tutorials: return "Ready-to-run textbook cases and the validation benchmarks."
        case .customCase: return "Build a case step by step: mesh generation or import, then the Setup and Solution pages."
        case .preProcessing: return "OpenFOAM utilities run before the solver: map a solution from another case (mapFields), set initial fields in regions (setFields), a near-wall initial profile (applyBoundaryLayer), extra mesh checks."
        case .postProcessing: return "OpenFOAM post-processing on the solution: derived fields (vorticity, Q, λ₂, y⁺, wall shear, Courant…), line samples into the XY plot, iso-surfaces, streamlines, VTK and EnSight export."
        case .pinn: return "Train a neural network on the case's equations and boundary conditions (PyTorch), optionally with the OpenFOAM solution as data, and view its prediction like any solution."
        case .aiAssistant: return "Ask Claude (or another AI provider) about the open case: setup review, convergence problems, physics and post-processing."
        }
    }
    /// Modules that build a case from their parameters.
    public var buildsCase: Bool { [.windFarm, .windTurbineRotor, .airCooledHeatSink, .liquidColdPlate].contains(self) }
    public var needsGmsh: Bool { [.windTurbineRotor, .cadAnalysis].contains(self) }
}

/// Every module's parameters (stored with the workspace).
public struct ModuleParameters: Codable, Sendable, Equatable {
    public var windFarm = WindFarmModule()
    public var rotor = WindTurbineRotorModule()
    public var airCooling = AirCooledHeatSinkModule()
    public var liquidCooling = LiquidColdPlateModule()
    public var pinn = PINNSettings()
    public init() {}

    private enum K: String, CodingKey { case windFarm, rotor, airCooling, liquidCooling, pinn }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        windFarm = (try? c.decodeIfPresent(WindFarmModule.self, forKey: .windFarm)) ?? WindFarmModule()
        rotor = (try? c.decodeIfPresent(WindTurbineRotorModule.self, forKey: .rotor)) ?? WindTurbineRotorModule()
        airCooling = (try? c.decodeIfPresent(AirCooledHeatSinkModule.self, forKey: .airCooling)) ?? AirCooledHeatSinkModule()
        liquidCooling = (try? c.decodeIfPresent(LiquidColdPlateModule.self, forKey: .liquidCooling)) ?? LiquidColdPlateModule()
        pinn = (try? c.decodeIfPresent(PINNSettings.self, forKey: .pinn)) ?? PINNSettings()
    }

    /// Build the case of a case-building module.
    public func build(_ m: AppModule) throws -> (Mesh, CaseSetup) {
        switch m {
        case .windFarm: return try windFarm.build()
        case .windTurbineRotor: return try rotor.build()
        case .airCooledHeatSink: return try airCooling.build()
        case .liquidColdPlate: return try liquidCooling.build()
        default: throw SolverError("\(m.title) does not build a case from parameters")
        }
    }
}
