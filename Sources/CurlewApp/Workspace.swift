import Foundation
import SwiftUI
import Observation
import CurlewMesh
import CurlewSolver
import CurlewPost
import CurlewFoam

enum OutlineItem: Hashable, Identifiable {
    // Meshing
    case module
    case meshGeneration, cadAnalysis, meshInfo
    // Setup
    case general, models, materials, cellZones, boundaries, expressions, referenceValues
    // Solution
    case methods, controls, reportDefinitions, monitors, initialization, openfoam, runCalculation
    // Results
    case surfaces, graphicsMesh, contours, vectors, pathlines, xyPlot, reports
    // Help
    case validation

    var id: Self { self }

    var title: String {
        switch self {
        case .module: return "Module"
        case .meshGeneration: return "Mesh Generation"
        case .cadAnalysis: return "CAD Analysis"
        case .meshInfo: return "Mesh & Quality"
        case .general: return "General"
        case .models: return "Models"
        case .materials: return "Materials"
        case .cellZones: return "Cell Zone Conditions"
        case .boundaries: return "Boundary Conditions"
        case .expressions: return "Named Expressions"
        case .referenceValues: return "Reference Values"
        case .methods: return "Methods"
        case .controls: return "Controls"
        case .reportDefinitions: return "Report Definitions"
        case .monitors: return "Monitors"
        case .initialization: return "Initialization"
        case .openfoam: return "OpenFOAM"
        case .runCalculation: return "Run Calculation"
        case .surfaces: return "Surfaces"
        case .graphicsMesh: return "Mesh Display"
        case .contours: return "Contours"
        case .vectors: return "Vectors"
        case .pathlines: return "Pathlines"
        case .xyPlot: return "XY Plot"
        case .reports: return "Reports"
        case .validation: return "Validation Suite"
        }
    }

    var symbol: String {
        switch self {
        case .module: return "square.stack.3d.up"
        case .meshGeneration: return "square.grid.3x3.square"
        case .cadAnalysis: return "cube.transparent"
        case .meshInfo: return "checkmark.seal"
        case .general: return "gearshape"
        case .models: return "wind"
        case .materials: return "drop"
        case .cellZones: return "cube"
        case .boundaries: return "square.dashed"
        case .expressions: return "function"
        case .referenceValues: return "ruler"
        case .methods: return "slider.horizontal.3"
        case .controls: return "dial.medium"
        case .reportDefinitions: return "list.bullet.rectangle"
        case .monitors: return "waveform.path.ecg"
        case .initialization: return "sparkles"
        case .openfoam: return "terminal"
        case .runCalculation: return "play.circle"
        case .surfaces: return "square.on.square.dashed"
        case .graphicsMesh: return "grid"
        case .contours: return "circle.lefthalf.filled"
        case .vectors: return "arrow.up.right"
        case .pathlines: return "point.topleft.down.to.point.bottomright.curvepath"
        case .xyPlot: return "chart.xyaxis.line"
        case .reports: return "doc.text.magnifyingglass"
        case .validation: return "checkmark.circle"
        }
    }
}

enum GraphicsTab: String, CaseIterable, Identifiable {
    case viewport = "Graphics", residuals = "Scaled Residuals", reports = "Report Plots", xy = "XY Plot"
    var id: String { rawValue }
}

struct ConsoleLine: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var kind: Kind
    enum Kind { case info, command, warning, error }
}

/// User-defined surfaces (planes, iso-surfaces) for post-processing.
struct NamedSurface: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var definition: SurfaceDefinition
}

/// What the graphics window is drawing.
struct DisplaySettings: Equatable {
    enum Mode: String, CaseIterable { case mesh = "Mesh", contours = "Contours", vectors = "Vectors", pathlines = "Pathlines" }
    var mode: Mode = .mesh
    var field = "velocity-magnitude"
    var surfaces: [String] = []          // surface names (zones or named surfaces); empty = default
    var autoRange = true
    var minValue = 0.0
    var maxValue = 1.0
    var colormap: Colormap = .rainbow
    var bands = 0                       // 0 = smooth
    var showEdges = false
    var showOutline = true
    var vectorScale = 1.0
    var vectorSkip = 0
    var pathlineSeeds = ""              // zone name
    var pathlineCount = 40
    var pathlineSteps = 2000
}

@Observable
final class Workspace {
    var mesh: Mesh?
    var setup = CaseSetup()
    /// The current flow solution: OpenFOAM results read back, or initial fields after Initialize.
    var solver: Solution?
    /// `solver` holds OpenFOAM results (not just initial fields).
    var hasResults = false
    var post: PostProcessor?
    var selection: OutlineItem? = .module
    var console: [ConsoleLine] = []
    var isRunning = false
    var isMeshing = false
    var initialized = false
    var residuals = ResidualHistory()
    var reportHistory = ReportHistory()
    var graphicsTab: GraphicsTab = .viewport
    var documentURL: URL?
    var isDirty = false
    var meshQuality: MeshQualityReport?
    var meshSource = ""
    var display = DisplaySettings()
    var scene = SceneContent()
    var namedSurfaces: [NamedSurface] = []
    var xyPlot: XYPlotData?
    var lastReportText = ""
    var statusText = "Ready"
    var currentIteration = 0
    var flowTime = 0.0
    var validationResults: [ValidationRow] = []
    var cameraResetToken = 0
    // OpenFOAM
    var foamInstallations: [FoamInstallation] = []
    /// OpenFOAM settings from a case opened from disk that run something beyond the generated
    /// case (stages, raw function objects, dictionary text, extra files); shown to the user and
    /// approved before the case is first written or run.
    var foamUnapprovedContent: [String] = []
    /// Module selected in the ribbon, and every module's parameters.
    var activeModule: AppModule = .windFarm
    var moduleParams = ModuleParameters()
    var moduleCores = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    // PINN
    var pinnJob: PINNJob?
    var pinnStatus = ""
    var pinnLoss: [(epoch: Int, loss: Double)] = []
    var pinnBusy = false
    // AI assistant
    var aiConversation: [AIMessage] = []
    var aiBusy = false
    var aiError = ""
    /// CAD Analysis page: file, analysis type and options.
    var cadSpec = CADAnalysisSpec()
    var foamProbe = ""
    var foamStatus = ""
    var foamLastCase: URL?
    /// Python post-processing: last result per script name, and the script running now.
    var postScriptResults: [String: PostScriptResult] = [:]
    var postScriptRunning: String?
    @ObservationIgnored var postScriptJob: PostScriptRun?
    @ObservationIgnored var foamJob: FoamSolve?
    @ObservationIgnored var foamCancel = false
    @ObservationIgnored weak var viewController: ViewController?

    init() {
        log("Curlew \(Workspace.version) — CFD for macOS: setup, meshing, pre- and post-processing; OpenFOAM solves", .info)
        log("Start with Mesh Generation (blockMesh, Gmsh, snappyHexMesh), or File > Import Mesh (Fluent .msh, Gmsh .msh, OpenFOAM polyMesh).", .info)
        if let exe = GmshDriver.executable { log("Gmsh found: \(exe.path)", .info) }
        else { log("Gmsh not found — CAD meshing templates need Gmsh.app in /Applications.", .warning) }
        refreshFoamInstallations()
        // Test hook: CURLEW_SCRIPT="cmd1; cmd2; ..." runs console commands after launch.
        if let script = ProcessInfo.processInfo.environment["CURLEW_SCRIPT"] {
            let cmds = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.runScript(cmds) }
        }
    }

    func runScript(_ cmds: [String]) {
        guard let first = cmds.first else { return }
        if isRunning || isMeshing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.runScript(cmds) }
            return
        }
        execute(first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.runScript(Array(cmds.dropFirst())) }
    }

    static let version = "1.0"

    // MARK: Console

    func log(_ s: String, _ kind: ConsoleLine.Kind = .info) {
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            console.append(ConsoleLine(text: String(line), kind: kind))
        }
        if console.count > 5000 { console.removeFirst(console.count - 5000) }
    }

    // MARK: Mesh

    func setMesh(_ m: Mesh, source: String) {
        if meshEditingBlocked { return }
        mesh = m
        meshSource = source
        setup.adopt(mesh: m)
        solver = nil
        post = nil
        initialized = false
        hasResults = false
        residuals = ResidualHistory()
        reportHistory = ReportHistory()
        meshQuality = MeshQuality.report(m)
        isDirty = true
        log("Mesh loaded from \(source): \(m.summary)")
        let shapes = m.cellShapeHistogram().sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        log("  cells: \(shapes)")
        for z in m.boundaryZones { log("  zone \(z.name) (\(z.kind.displayName)): \(z.count) faces") }
        if let q = meshQuality {
            log(String(format: "  minimum orthogonal quality = %.4f, maximum aspect ratio = %.3g", q.minOrthogonalQuality, q.maxAspectRatio))
            if q.negativeVolumes > 0 { log("  \(q.negativeVolumes) cells have non-positive volume!", .error) }
        }
        display.mode = .mesh
        display.surfaces = []
        refreshDisplay()
        cameraResetToken += 1
        graphicsTab = .viewport
    }

    func importMesh(url: URL) {
        let depth = 1.0
        statusText = "Reading \(url.lastPathComponent)…"
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let m = try MeshIO.read(url: URL(fileURLWithPath: path), depth2D: depth)
                DispatchQueue.main.async { self.setMesh(m, source: url.lastPathComponent); self.statusText = "Ready" }
            } catch {
                DispatchQueue.main.async { self.log("\(error)", .error); self.statusText = "Ready" }
            }
        }
    }

    func generateMesh(_ settings: MeshingSettings, setupHook: ((Mesh, inout CaseSetup) -> Void)? = nil) {
        isMeshing = true
        statusText = settings.inflation3D != nil ? "Meshing with Gmsh, layers with snappyHexMesh…" : "Meshing with Gmsh…"
        log("Running Gmsh…", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try FoamGmsh.generate(settings, log: { line in
                    if line.hasPrefix("Adding ") || line.contains("FOAM FATAL") { DispatchQueue.main.async { self.log(line) } }
                })
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    let lines = r.log.split(separator: "\n").filter { !$0.hasPrefix("snappyHexMesh layers:") }
                    self.log(lines.suffix(4).joined(separator: "\n"))
                    if let l = r.layers { self.log(l) }
                    self.setMesh(r.mesh, source: "Gmsh")
                    if let hook = setupHook { hook(r.mesh, &self.setup) }
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    /// Block and O-grid meshes are generated by OpenFOAM's blockMesh.
    func buildBlockMesh(_ source: String, _ build: @escaping () throws -> Mesh) {
        guard !isMeshing else { return }
        isMeshing = true
        statusText = "blockMesh…"
        log("Meshing with blockMesh…", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let m = try build()
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.setMesh(m, source: source) }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    // MARK: Solution

    /// The current solution object, created on demand (initial fields or loaded results).
    @discardableResult
    func ensureSolver() -> Solution? {
        guard let mesh else { log("No mesh loaded.", .error); return nil }
        do {
            if let s = solver {
                try s.updateSetup(setup)
                return s
            }
            let s = try Solution(mesh: mesh, setup: setup)
            solver = s
            post = PostProcessor(solver: s)
            return s
        } catch {
            log("\(error)", .error)
            return nil
        }
    }

    /// Compute the initial fields OpenFOAM will start from, so they can be inspected (contours,
    /// reports) before the calculation. Hybrid initialization is potentialFoam, run as the
    /// first stage of the calculation; until then the fields shown are the uniform values.
    func initialize() {
        guard !isRunning else { return }
        solver = nil
        guard let s = ensureSolver() else { return }
        s.loadInitialFields()
        initialized = true
        hasResults = false
        residuals = s.residuals
        reportHistory = s.reportHistory
        currentIteration = 0
        flowTime = 0
        if setup.initialization.method == .hybrid {
            log("Initial fields: uniform values from the inlets; potentialFoam computes the potential-flow velocity at the start of the calculation.")
        } else {
            log("Initialization complete (standard\(setup.initialization.patches.isEmpty ? "" : ", \(setup.initialization.patches.count) patch(es)")). These fields are written as OpenFOAM's 0/ fields.")
        }
        refreshDisplay()
    }

    /// Calculate: write the case, run it in OpenFOAM, read the results back.
    func calculate() {
        if foamInstallations.isEmpty && FoamDiscovery.discover().isEmpty {
            log("No OpenFOAM installation found. Curlew solves with OpenFOAM: install OpenFOAM for macOS from openfoam.com (or point the OpenFOAM page › Installation at one).", .error)
            return
        }
        calculateWithOpenFOAM()
    }

    func stop() {
        guard let job = foamJob else { return }
        foamCancel = true
        job.cancel()
        log("Stopping OpenFOAM…", .warning)
    }

    // MARK: Display

    func refreshDisplay() {
        guard let mesh else { scene = SceneContent(); return }
        if isRunning && display.mode != .mesh { return }
        if display.mode != .mesh, initialized, let post {
            scene = SceneBuilder.build(post: post, mesh: mesh, settings: display, named: namedSurfaces)
        } else {
            scene = SceneBuilder.meshScene(mesh: mesh, settings: display)
        }
    }

    func availableFields() -> [String] {
        if let s = solver { return FieldCatalog.available(for: s) }
        return ["pressure", "velocity-magnitude", "x-velocity", "y-velocity", "z-velocity"]
    }

    func surfaceNames() -> [String] {
        var out: [String] = []
        if mesh?.isTwoDimensional == true { out.append("2D domain") }
        out += (mesh?.boundaryZones.filter { $0.kind != .empty }.map(\.name) ?? [])
        out += namedSurfaces.map(\.name)
        return out
    }

    func surfaceDefinition(named n: String) -> SurfaceDefinition {
        if n == "2D domain" { return .twoDimensionalDomain }
        if let s = namedSurfaces.first(where: { $0.name == n }) { return s.definition }
        return .zone(n)
    }
}

struct XYPlotData: Equatable {
    var title: String
    var xLabel: String
    var yLabel: String
    var series: [Series]
    struct Series: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var points: [XYPoint]
    }
}
struct XYPoint: Equatable, Identifiable { var id: Int; var x: Double; var y: Double }

struct ValidationRow: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var quantity: String
    var reference: String
    var computed: String
    var passed: Bool
}
