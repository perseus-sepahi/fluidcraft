import Foundation
import CurlewMesh
import CurlewSolver

/// One OpenFOAM calculation of a Curlew case: write the case, run it in the selected
/// installation, and read the latest time back into a `PressureBasedSolver` so Curlew's
/// post-processing works on the OpenFOAM solution. Shared by the app and the CLI.
public final class FoamSolve: @unchecked Sendable {
    public struct Outcome: Sendable {
        /// A Curlew solver holding the OpenFOAM fields (nil when loading was off or failed).
        public var solver: PressureBasedSolver?
        public var report: FoamCaseReport
        public var caseDirectory: URL
        public var residuals: ResidualHistory
        public var reports: ReportHistory
        /// nil on success, otherwise why the run stopped.
        public var failure: String?
        public var seconds: Double
        public var loadedTime: String?
        public var metrics: FoamRunMetrics
        /// Python post-processing scripts run after the solve ("after the solve" scripts).
        public var scripts: [PostScriptResult] = []
    }

    public let mesh: Mesh
    public let setup: CaseSetup
    private let lock = NSLock()
    private var runner: FoamRunner?
    private var cancelled = false

    public init(mesh: Mesh, setup: CaseSetup) {
        self.mesh = mesh
        var s = setup
        s.adopt(mesh: mesh)
        self.setup = s
    }

    public func cancel() {
        lock.lock(); cancelled = true; let r = runner; lock.unlock()
        r?.cancel()
    }

    /// Blocking; call from a worker thread.
    /// - Parameters:
    ///   - initial: nonuniform initial fields (Curlew initialization or solution) or nil.
    ///   - residuals/reports: histories to continue (a restarted run appends to them).
    ///   - log: progress text (stage titles, warnings, periodic residual lines, errors).
    ///   - progress: called after every solver step with the updated histories.
    public func run(initial: FlowState?, residuals startResiduals: ResidualHistory = ResidualHistory(),
                    reports startReports: ReportHistory = ReportHistory(), reportingInterval: Int = 1,
                    log: @escaping (String) -> Void,
                    progress: @escaping (ResidualHistory, ReportHistory, Int, Double) -> Void) throws -> Outcome {
        let t0 = Date()
        let o = setup.openfoam
        let dir = FoamLocations.caseDirectory(for: setup)
        try FoamLocations.validate(dir)
        let inst = try FoamLocations.installation(for: setup)
        log("OpenFOAM: \(inst.name) (\(inst.version ?? "?")) at \(inst.location.path)")
        let env = try inst.resolve()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let latest = FoamTimes.latest(dir)
        let hasMesh = FileManager.default.fileExists(atPath: dir.appendingPathComponent("constant/polyMesh/faces").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("constant/regionProperties").path)
        let continuing = o.continueFromLatestTime && hasMesh && (latest?.value ?? 0) > 0
        let report: FoamCaseReport
        var residuals = startResiduals, reports = startReports
        if continuing, let latest {
            report = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir, writeMesh: false, writeFields: false, startTime: latest.value)
            log("Continuing from time \(latest.name) in \(dir.path)")
        } else {
            FoamCasePreparation.clean(dir)
            report = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir, initial: initial)
            residuals = ResidualHistory(); reports = ReportHistory()
            log("Wrote \(report.application.rawValue) case (\(report.turbulence.rawValue)) to \(dir.path)")
        }
        for w in report.warnings { log("Warning: \(w)") }

        let stages = FoamRunPlan.stages(report: report, setup: setup, freshMesh: !continuing)
        let r = FoamRunner(environment: env, caseDirectory: dir, report: report)
        lock.lock(); runner = r; let stop = cancelled; lock.unlock()
        if stop { r.cancel() }
        let transient = report.application.isTransient
        let offset = residuals.iterations.last ?? 0
        var lastLogged = Date.distantPast
        var lastProgress = Date.distantPast
        let failure = r.run(stages) { e in
            switch e {
            case .stage(let st):
                log("— \(st.title)\(st.parallel ? " on \(report.cores) cores" : "")")
            case .line(let line):
                if line.contains("allowSystemOperations") { break }
                if line.hasPrefix("--> FOAM Warning") || line.hasPrefix("--> FOAM FATAL") || line.hasPrefix("    Mesh OK")
                    || line.hasPrefix("Mesh OK") || line.contains("Failed ") && line.contains("mesh checks")
                    || line.hasPrefix("SIMPLE solution converged") || line.hasPrefix("PIMPLE: converged") {
                    log(line)
                }
            case .step(let it, let time, let res, let rep):
                let iteration = transient ? offset + it : it
                if !res.isEmpty { residuals.record(iteration: iteration, res) }
                if !rep.isEmpty { reports.record(x: transient ? time : Double(iteration), rep) }
                let now = Date()
                if now.timeIntervalSince(lastLogged) > 2 || (reportingInterval > 0 && iteration % max(reportingInterval, 50) == 0) {
                    lastLogged = now
                    let order = ["continuity", "x-velocity", "y-velocity", "z-velocity", "energy", "k", "omega", "epsilon", "nut"]
                    let keys = res.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
                    let text = keys.map { String(format: "%@ %.3e", $0 as NSString, res[$0]!) }.joined(separator: "  ")
                    log((transient ? String(format: "t = %.6g s  ", time) : "iter \(iteration)  ") + text)
                }
                if now.timeIntervalSince(lastProgress) > 0.15 {
                    lastProgress = now
                    progress(residuals, reports, iteration, time)
                }
            case .stageFinished(let st, let code, let sec):
                if code == 0 { log(String(format: "  %@ finished (%.1f s)", st.title as NSString, sec)) }
            }
        }
        progress(residuals, reports, residuals.iterations.last ?? 0, r.metrics.currentTime)
        if let f = r.metrics.fatal { log(f) }

        var outcome = Outcome(solver: nil, report: report, caseDirectory: dir, residuals: residuals, reports: reports,
                              failure: failure, seconds: Date().timeIntervalSince(t0), loadedTime: nil, metrics: r.metrics)
        let hasResults = (FoamTimes.latest(dir)?.value ?? 0) > 0
        let refined = o.adaptiveRefinement.enabled && transient
        if refined && o.loadResults && hasResults {
            log("Adaptive refinement changed the mesh: open the results in ParaView or with a Python script (they read the refined mesh); Curlew's pages keep the original mesh.")
        }
        if o.loadResults && hasResults && !refined {
            do {
                let (solver, time) = try FoamSolve.load(caseDirectory: dir, mesh: mesh, setup: setup)
                solver.restoreHistory(residuals: residuals, reports: reports)
                if transient { solver.state.iteration = residuals.iterations.last ?? (offset + r.metrics.timeSteps) }
                outcome.solver = solver
                outcome.loadedTime = time
                log("Loaded OpenFOAM results at time \(time).")
            } catch {
                log("Could not load OpenFOAM results: \(error)")
            }
        }
        if failure == nil && hasResults && setup.openfoam.postProcessing.scripts.contains(where: { $0.afterSolve }) {
            // the case content (scripts included) was approved before the run started
            outcome.scripts = PostScriptRun.runAfterSolve(setup: setup, caseDirectory: dir, log: log)
        }
        return outcome
    }

    /// Read a time directory of a case written for `mesh` into a new Curlew solver.
    public static func load(caseDirectory dir: URL, mesh: Mesh, setup: CaseSetup, time: String? = nil) throws -> (PressureBasedSolver, String) {
        let loaded = try FoamResults.load(caseDirectory: dir, mesh: mesh, setup: setup, time: time)
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.load(external: loaded.solution)
        return (solver, loaded.timeName)
    }
}
