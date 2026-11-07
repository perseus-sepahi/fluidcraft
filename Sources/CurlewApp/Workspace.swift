import Foundation
import SwiftUI
import Observation
import CurlewMesh
import CurlewLinear
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
    var solver: PressureBasedSolver?
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
    // OpenFOAM backend
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
    @ObservationIgnored var foamJob: FoamSolve?
    @ObservationIgnored var foamCancel = false
    @ObservationIgnored weak var viewController: ViewController?

    init() {
        log("Curlew \(Workspace.version) — finite-volume CFD for macOS", .info)
        log("Start with Mesh Generation (built-in block/O-grid meshers or Gmsh), or File > Import Mesh (Fluent .msh, Gmsh .msh, OpenFOAM polyMesh).", .info)
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
        statusText = "Meshing with Gmsh…"
        log("Running Gmsh…", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try GmshDriver.generate(settings)
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    let lines = r.log.split(separator: "\n").filter { !$0.hasPrefix("Inflation:") }
                    self.log(lines.suffix(4).joined(separator: "\n"))
                    if let inf = r.inflation { self.log(inf.description) }
                    self.setMesh(r.mesh, source: "Gmsh")
                    if let hook = setupHook { hook(r.mesh, &self.setup) }
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    func buildBlockMesh(_ spec: BlockMeshSpec) {
        do { setMesh(try spec.build(), source: "block mesher") } catch { log("\(error)", .error) }
    }

    // MARK: Solver

    @discardableResult
    func ensureSolver() -> PressureBasedSolver? {
        guard let mesh else { log("No mesh loaded.", .error); return nil }
        do {
            if let s = solver {
                try s.updateSetup(setup)
                return s
            }
            let s = try PressureBasedSolver(mesh: mesh, setup: setup)
            s.log = { [weak self] msg in DispatchQueue.main.async { self?.log(msg) } }
            solver = s
            post = PostProcessor(solver: s)
            return s
        } catch {
            log("\(error)", .error)
            return nil
        }
    }

    func initialize() {
        guard !isRunning, let s = ensureSolver() else { return }
        do {
            try s.initialize()
            initialized = true
            residuals = s.residuals
            reportHistory = s.reportHistory
            currentIteration = 0
            flowTime = 0
            log("Initialization complete (\(setup.initialization.method.rawValue)).")
            refreshDisplay()
        } catch { log("\(error)", .error) }
    }

    func calculate() {
        if setup.general.backend == .openfoam {
            if foamInstallations.isEmpty && FoamDiscovery.discover().isEmpty {
                log("No OpenFOAM installation found (install openfoam.com's OpenFOAM for macOS, or set it on the OpenFOAM page); solving with Curlew's built-in solver instead.", .warning)
            } else {
                calculateWithOpenFOAM(); return
            }
        }
        guard !isRunning, let s = ensureSolver() else { return }
        if !initialized { initialize() }
        guard initialized else { return }
        isRunning = true
        statusText = "Calculating…"
        let transient = setup.general.time == .transient
        log(transient ? "Advancing \(setup.run.numberOfTimeSteps) time steps (Δt = \(setup.run.timeStepSize) s)…" : "Iterating \(setup.run.iterations) iterations…", .command)
        let iterations = setup.run.iterations
        let steps = setup.run.numberOfTimeSteps
        let autoUpdate = display.mode != .mesh
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var last = Date.distantPast
            var lastScene = Date()
            let t0 = Date()
            let result = s.run(iterations: iterations, timeSteps: steps) { solver, r in
                let now = Date()
                if now.timeIntervalSince(last) > 0.12 {
                    last = now
                    let res = solver.residuals, rep = solver.reportHistory
                    let it = solver.iteration, time = solver.state.time
                    let line = solver.formatResiduals(r)
                    DispatchQueue.main.async {
                        self?.residuals = res; self?.reportHistory = rep
                        self?.currentIteration = it; self?.flowTime = time
                        self?.statusText = transient ? String(format: "t = %.5g s, iteration %d", time, it) : "Iteration \(it)"
                        if self?.graphicsTab != .viewport || !autoUpdate { self?.log(line) }
                    }
                }
                if autoUpdate && now.timeIntervalSince(lastScene) > 1.5 {
                    lastScene = now
                    // build the scene on the solver thread (fields are consistent here)
                    if let ws = self {
                        let (settings, named, post) = DispatchQueue.main.sync { (ws.display, ws.namedSurfaces, ws.post) }
                        if let p = post {
                            let sc = SceneBuilder.build(post: p, mesh: solver.mesh, settings: settings, named: named)
                            DispatchQueue.main.async { ws.scene = sc }
                        }
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.residuals = s.residuals
                self.reportHistory = s.reportHistory
                self.currentIteration = s.iteration
                self.flowTime = s.state.time
                self.isDirty = true
                if let r = s.residuals.values.last {
                    self.log(s.formatResiduals(Dictionary(uniqueKeysWithValues: zip(s.residuals.names, r))))
                }
                if result.diverged { self.log("Divergence detected — check boundary conditions, under-relaxation and mesh quality.", .error) }
                else if result.converged && !transient { self.log("Solution converged after \(result.iterations) iterations (\(String(format: "%.1f", elapsed)) s).") }
                else if result.stopped { self.log("Calculation interrupted by user.", .warning) }
                else { self.log("Calculation complete: \(result.iterations) iterations in \(String(format: "%.1f", elapsed)) s.") }
                self.statusText = "Ready"
                self.refreshDisplay()
            }
        }
    }

    func stop() {
        if let job = foamJob { foamCancel = true; job.cancel(); log("Stopping OpenFOAM…", .warning); return }
        solver?.stopRequested = true
        log("Interrupt requested…", .warning)
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
