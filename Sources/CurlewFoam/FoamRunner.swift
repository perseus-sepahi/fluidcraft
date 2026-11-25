import Foundation
import CurlewMesh
import CurlewSolver

// MARK: - Locations

public enum FoamLocations {
    /// `~/CurlewFoam/<title>` — the home directory, not Application Support, because OpenFOAM
    /// cannot run in a path containing spaces.
    public static func defaultCaseDirectory(title: String) -> URL {
        let word = String(title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CurlewFoam")
            .appendingPathComponent(word.isEmpty || word == "Untitled" ? "case" : word)
    }

    public static func caseDirectory(for setup: CaseSetup) -> URL {
        let custom = setup.openfoam.caseDirectory.trimmingCharacters(in: .whitespaces)
        if custom.isEmpty { return defaultCaseDirectory(title: setup.title) }
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    }

    public static func validate(_ dir: URL) throws {
        if dir.path.contains(" ") {
            throw SolverError("OpenFOAM cannot run in a path that contains spaces:\n\(dir.path)\nChoose another case directory (OpenFOAM settings › Case directory).")
        }
        // Never clean or overwrite a folder that holds something other than an OpenFOAM case.
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: dir.path), !items.filter({ !$0.hasPrefix(".") }).isEmpty,
           !fm.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path) {
            throw SolverError("\(dir.path) is not empty and is not an OpenFOAM case; choose an empty or new case directory.")
        }
    }

    /// The configured installation, or the best one found.
    public static func installation(for setup: CaseSetup) throws -> FoamInstallation {
        let path = setup.openfoam.installation.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty {
            guard let inst = FoamDiscovery.installation(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
                throw SolverError("\(path) is not an OpenFOAM installation (expected an OpenFOAM .app, a tree with etc/bashrc, or the bashrc itself)")
            }
            return inst
        }
        guard let inst = FoamDiscovery.discover().first else { throw FoamSolveError.noInstallation }
        return inst
    }
}

// MARK: - Plan

public struct FoamStage: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var command: String
    public var arguments: [String]
    public var parallel: Bool
    public var logName: String
    /// The solver itself (its residuals drive the charts).
    public var isSolver = false
    /// User-defined stage: this program must be an OpenFOAM application (found in
    /// FOAM_APPBIN, FOAM_SITE_APPBIN or FOAM_USER_APPBIN) or the stage is refused.
    public var requiredApplication: String? = nil
}

public enum FoamRunPlan {
    public static func stages(report: FoamCaseReport, setup: CaseSetup, freshMesh: Bool) -> [FoamStage] {
        let o = setup.openfoam
        let cores = max(1, o.cores)
        let par = cores > 1
        var st: [FoamStage] = []
        let multi = report.isMultiRegion
        if !o.baffles.isEmpty && freshMesh && !multi {
            st.append(FoamStage(id: "createBaffles", title: "Create baffles (\(o.baffles.map(\.name).joined(separator: ", ")))",
                                command: "createBaffles", arguments: ["-overwrite"], parallel: false, logName: "createBaffles"))
        }
        if o.checkMesh && freshMesh {
            if multi {
                for r in report.regions {
                    st.append(FoamStage(id: "checkMesh.\(r)", title: "Check mesh (\(r))", command: "checkMesh", arguments: ["-region", r, "-constant"], parallel: false, logName: "checkMesh.\(r)"))
                }
            } else {
                st.append(FoamStage(id: "checkMesh", title: "Check mesh", command: "checkMesh",
                                    arguments: ["-constant"] + (o.preProcessing.fullMeshCheck ? ["-allGeometry", "-allTopology"] : []), parallel: false, logName: "checkMesh"))
            }
        }
        if !multi && !o.continueFromLatestTime { st += preProcessingStages(o.preProcessing) }
        if par {
            st.append(FoamStage(id: "decomposePar", title: "Decompose (\(cores) subdomains)", command: "decomposePar",
                                arguments: (multi ? ["-allRegions"] : []) + (o.continueFromLatestTime ? ["-force", "-latestTime"] : ["-force"]),
                                parallel: false, logName: "decomposePar"))
        }
        if report.runsPotentialFoam {
            st.append(FoamStage(id: "potentialFoam", title: "Potential-flow initialisation", command: "potentialFoam",
                                arguments: ["-writephi"], parallel: par, logName: "potentialFoam"))
        }
        func custom(_ phase: FoamCustomStage.Phase) -> [FoamStage] {
            o.customStages.filter { $0.phase == phase && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated().map { i, c in
                let words = c.words
                let name = words.first ?? ""
                let safeLog = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
                var stage = FoamStage(id: "custom.\(phase.rawValue).\(i)", title: c.command, command: name, arguments: Array(words.dropFirst()),
                                      parallel: c.parallel && par, logName: "\(safeLog).\(phase.rawValue).\(i)")
                stage.requiredApplication = name
                return stage
            }
        }
        st += custom(.beforeSolve)
        var solver = FoamStage(id: "solver", title: "Solve (\(report.application.rawValue))", command: report.application.rawValue,
                               arguments: [], parallel: par, logName: report.application.rawValue)
        solver.isSolver = true
        st.append(solver)
        if par {
            st.append(FoamStage(id: "reconstructPar", title: "Reconstruct", command: "reconstructPar", arguments: (multi ? ["-allRegions"] : []) + ["-latestTime"], parallel: false, logName: "reconstructPar"))
        }
        st += custom(.afterSolve)
        if !multi && o.postProcessing.afterSolve { st += postProcessingStages(o.postProcessing, application: report.application) }
        return st
    }

    /// mapFields, setFields, applyBoundaryLayer (serial, on the undecomposed case).
    public static func preProcessingStages(_ pre: FoamPreProcessing) -> [FoamStage] {
        var st: [FoamStage] = []
        if !pre.mapFieldsSource.isEmpty {
            st.append(FoamStage(id: "mapFields", title: "Map fields from \((pre.mapFieldsSource as NSString).lastPathComponent)", command: "mapFields",
                                arguments: [pre.mapFieldsSource] + (pre.mapFieldsConsistent ? ["-consistent"] : []) + ["-sourceTime", "latestTime"],
                                parallel: false, logName: "mapFields"))
        }
        if !pre.setFieldsRegions.isEmpty {
            st.append(FoamStage(id: "setFields", title: "Set fields (\(pre.setFieldsRegions.count) regions)", command: "setFields", arguments: [], parallel: false, logName: "setFields"))
        }
        if let y = pre.boundaryLayerThickness, y > 0 {
            st.append(FoamStage(id: "applyBoundaryLayer", title: "Initial boundary layer", command: "applyBoundaryLayer",
                                arguments: ["-ybl", String(y)], parallel: false, logName: "applyBoundaryLayer"))
        }
        return st
    }

    /// The post-processing function objects (through the solver, so its models are loaded) and exports.
    public static func postProcessingStages(_ post: FoamPostProcessing, application: FoamApplication) -> [FoamStage] {
        var st: [FoamStage] = []
        if post.runsOpenFOAMFunctions {
            st.append(FoamStage(id: "postProcess", title: "Post-process (latest time)", command: application.rawValue,
                                arguments: ["-postProcess", "-latestTime", "-dict", "system/curlewPostProcess"], parallel: false, logName: "postProcess"))
        }
        if post.exportVTK { st.append(FoamStage(id: "foamToVTK", title: "Export VTK", command: "foamToVTK", arguments: ["-latestTime"], parallel: false, logName: "foamToVTK")) }
        if post.exportEnsight { st.append(FoamStage(id: "foamToEnsight", title: "Export EnSight", command: "foamToEnsight", arguments: ["-latestTime"], parallel: false, logName: "foamToEnsight")) }
        return st
    }
}

// MARK: - Runner

/// Runs an OpenFOAM case stage by stage in an activated environment, streaming log lines and
/// parsed events. One instance per run; `cancel()` stops the current stage and skips the rest.
public final class FoamRunner: @unchecked Sendable {
    public enum Event: Sendable {
        case stage(FoamStage)
        case line(String)
        /// One solver time step / iteration finished: initial residuals by Curlew equation name,
        /// live report values by Curlew report name.
        case step(iteration: Int, time: Double, residuals: [String: Double], reports: [String: Double])
        case stageFinished(FoamStage, exitCode: Int32, seconds: Double)
    }

    public let environment: FoamEnvironment
    public let caseDirectory: URL
    public let report: FoamCaseReport
    public private(set) var metrics = FoamRunMetrics()
    private let lock = NSLock()
    private var current: FoamProcess?
    private var cancelled = false

    public init(environment: FoamEnvironment, caseDirectory: URL, report: FoamCaseReport) {
        self.environment = environment
        self.caseDirectory = caseDirectory
        self.report = report
    }

    public func cancel() {
        lock.lock(); cancelled = true; let p = current; lock.unlock()
        p?.terminate()
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Curlew's names for OpenFOAM's residual fields.
    public static func curlewName(forField f: String) -> String {
        switch f {
        case "Ux": return "x-velocity"
        case "Uy": return "y-velocity"
        case "Uz": return "z-velocity"
        case "p", "p_rgh", "Phi": return "continuity"
        case "h", "e", "T": return "energy"
        case "nuTilda": return "nut"
        default: return f
        }
    }

    /// Run all stages (blocking). Returns nil on success, otherwise the reason it stopped.
    public func run(_ stages: [FoamStage], onEvent: @escaping (Event) -> Void) -> String? {
        for stage in stages {
            if isCancelled { return FoamSolveError.cancelled.description }
            onEvent(.stage(stage))
            let started = Date()
            var command = stage.command
            var args = stage.arguments
            if stage.parallel {
                args = ["-np", "\(report.cores)", command] + args + ["-parallel"]
                command = "mpirun"
            }
            let proc = FoamProcess(environment: environment, caseDirectory: caseDirectory, command: command, arguments: args,
                                   logURL: caseDirectory.appendingPathComponent("log.\(stage.logName)"),
                                   requiredApplication: stage.requiredApplication)
            lock.lock(); current = proc; lock.unlock()
            var parser = FoamLogParser()
            var stepResiduals: [String: Double] = [:]
            var stepTime = 0.0
            var steps = 0
            var inStep = false
            let live = report.liveReports
            let flush: () -> Void = { [self] in
                guard inStep, stage.isSolver else { return }
                var rep: [String: Double] = [:]
                for r in live {
                    if let d = r.direction {
                        if let v = metrics.functionVectors[r.key] { rep[r.report] = r.scale * dot(v, d) + r.offset }
                    } else if let v = metrics.functionValues[r.key] {
                        rep[r.report] = r.scale * v + r.offset
                    }
                }
                let it = report.application.isTransient ? steps : Int(stepTime.rounded())
                onEvent(.step(iteration: it, time: stepTime, residuals: stepResiduals, reports: rep))
            }
            let code = proc.run { [self] line in
                onEvent(.line(line))
                for e in parser.parse(line) {
                    if case .time(let t) = e {
                        flush()
                        stepResiduals.removeAll(); stepTime = t; steps += 1; inStep = true
                    }
                    // explicit (diagonal) solves report zero residuals with no iterations
                    if case .residual(let f, let initial, _, let n) = e, !(n == 0 && initial == 0) {
                        let name = FoamRunner.curlewName(forField: f)
                        if stepResiduals[name] == nil { stepResiduals[name] = max(initial, 1e-30) }
                    }
                    lock.lock(); metrics.apply(e); lock.unlock()
                }
            }
            flush()
            lock.lock(); current = nil; lock.unlock()
            onEvent(.stageFinished(stage, exitCode: code, seconds: Date().timeIntervalSince(started)))
            if isCancelled { return FoamSolveError.cancelled.description }
            if code != 0 {
                var hint = metrics.fatal.map { String($0.prefix(1200)) } ?? "See log.\(stage.logName) in \(caseDirectory.path)."
                if code == 97 { hint = "The OpenFOAM environment (etc/bashrc) could not be sourced." }
                if code == 96 { hint = "Custom stages may only run OpenFOAM applications (programs in FOAM_APPBIN, FOAM_SITE_APPBIN or FOAM_USER_APPBIN); '\(stage.requiredApplication ?? stage.command)' is not one." }
                if stage.id.hasPrefix("checkMesh") { hint = "checkMesh reported a failure; see log.checkMesh. Disable the mesh check in the OpenFOAM settings to run anyway." }
                return "\(stage.title) failed (exit \(code)). \(hint)"
            }
        }
        FileManager.default.createFile(atPath: caseDirectory.appendingPathComponent("case.foam").path, contents: Data())
        return nil
    }
}

// MARK: - Case preparation

public enum FoamCasePreparation {
    /// Remove results, processor directories and logs so a fresh run starts from 0/.
    public static func clean(_ dir: URL) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let isTime = Double(item).map { $0 > 0 } ?? false
            if isTime || item.hasPrefix("processor") || item.hasPrefix("log.") || item == "postProcessing" || item == "dynamicCode" {
                try? fm.removeItem(at: dir.appendingPathComponent(item))
            }
        }
        try? fm.removeItem(at: dir.appendingPathComponent("0"))
    }
}
