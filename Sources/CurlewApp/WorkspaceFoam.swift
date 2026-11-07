import Foundation
import AppKit
import CurlewMesh
import CurlewSolver
import CurlewPost
import CurlewFoam

/// OpenFOAM backend: running cases in an installed OpenFOAM, loading the results back, and
/// meshing CAD with snappyHexMesh.
extension Workspace {

    // MARK: Installations

    func refreshFoamInstallations() {
        DispatchQueue.global(qos: .utility).async {
            let found = FoamDiscovery.discover()
            DispatchQueue.main.async {
                self.foamInstallations = found
                if let first = found.first {
                    self.log("OpenFOAM found: \(first.name) (\(first.version ?? "?"))\(found.count > 1 ? " and \(found.count - 1) more" : "")")
                }
            }
        }
    }

    /// Mount/activate the selected installation and run a trivial command through it.
    func probeFoam() {
        let s = setup
        foamProbe = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do {
                let inst = try FoamLocations.installation(for: s)
                let p = try inst.resolve().probe()
                text = (p.ok ? "✓ " : "✗ ") + p.message
            } catch { text = "✗ \(error)" }
            DispatchQueue.main.async { self.foamProbe = text }
        }
    }

    var foamCaseDirectory: URL { FoamLocations.caseDirectory(for: setup) }

    /// Ask before writing or running custom OpenFOAM content that came from a case file.
    /// Content the user typed in this session is never in the list.
    func approveFoamContent() -> Bool {
        // only items still present (the user may have removed some)
        let current = Set(setup.openfoam.activeContent)
        let pending = foamUnapprovedContent.filter { current.contains($0) }
        guard !pending.isEmpty else { foamUnapprovedContent = []; return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Run custom OpenFOAM content from this case file?"
        a.informativeText = "The case you opened adds the following to the OpenFOAM run. OpenFOAM stages, function objects (systemCall), #codeStream and coded boundary conditions can run programs on this Mac. Only continue if you trust where the case came from.\n\n"
            + pending.prefix(12).map { "• " + $0 }.joined(separator: "\n") + (pending.count > 12 ? "\n… and \(pending.count - 12) more" : "")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Run It")
        guard a.runModal() == .alertSecondButtonReturn else { log("OpenFOAM run cancelled: custom case content not approved (OpenFOAM page › Extra Files and Stages).", .warning); return false }
        foamUnapprovedContent = []
        return true
    }

    // MARK: Calculate

    /// Write the case, run it in OpenFOAM and load the latest time into Curlew.
    func calculateWithOpenFOAM() {
        guard !isRunning else { return }
        guard let mesh else { log("No mesh loaded.", .error); return }
        do { try FoamLocations.validate(foamCaseDirectory) } catch { log("\(error)", .error); return }
        guard approveFoamContent() else { return }
        isRunning = true
        foamCancel = false
        statusText = "OpenFOAM: preparing…"
        var s = setup
        s.adopt(mesh: mesh)
        let current = (initialized ? solver : nil)
        let startResiduals = residuals, startReports = reportHistory
        let interval = setup.run.reportingInterval
        log("Calculating with OpenFOAM (\(FoamCaseWriter.resolvedApplication(s).rawValue))…", .command)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Initial fields: the current Curlew solution, or Curlew's own initialization.
            var initial: FlowState? = nil
            if s.openfoam.initialFields == .curlew && !s.openfoam.continueFromLatestTime {
                if let cur = current {
                    initial = cur.state
                    DispatchQueue.main.async { self.log("Initial fields: current Curlew solution (iteration \(cur.iteration)).") }
                } else {
                    do {
                        let starter = try PressureBasedSolver(mesh: mesh, setup: s)
                        starter.log = { _ in }
                        try starter.initialize()
                        initial = starter.state
                        DispatchQueue.main.async { self.log("Initial fields: Curlew \(s.initialization.method.rawValue) initialization.") }
                    } catch {
                        DispatchQueue.main.async { self.log("Curlew initialization failed (\(error)); OpenFOAM starts from uniform fields.", .warning) }
                    }
                }
            }
            let job = FoamSolve(mesh: mesh, setup: s)
            DispatchQueue.main.async { self.foamJob = job; if self.foamCancel { job.cancel() } }
            let transient = FoamCaseWriter.resolvedApplication(s).isTransient
            do {
                let out = try job.run(initial: initial, residuals: startResiduals, reports: startReports, reportingInterval: interval,
                                      log: { line in DispatchQueue.main.async { self.log(line) } },
                                      progress: { res, rep, it, time in
                                          DispatchQueue.main.async {
                                              self.residuals = res; self.reportHistory = rep
                                              self.currentIteration = it; self.flowTime = time
                                              self.statusText = transient ? String(format: "OpenFOAM t = %.5g s", time) : "OpenFOAM iteration \(it)"
                                          }
                                      })
                DispatchQueue.main.async { self.finishFoam(out) }
            } catch {
                DispatchQueue.main.async {
                    self.foamJob = nil
                    self.isRunning = false
                    self.statusText = "Ready"
                    self.log("\(error)", .error)
                }
            }
        }
    }

    private func finishFoam(_ out: FoamSolve.Outcome) {
        foamJob = nil
        isRunning = false
        statusText = "Ready"
        foamLastCase = out.caseDirectory
        residuals = out.residuals
        reportHistory = out.reports
        if let f = out.failure { log(f, f.contains("cancelled") ? .warning : .error) }
        else { log(String(format: "OpenFOAM finished in %.1f s (%@).", out.seconds, out.report.application.rawValue)) }
        if let s = out.solver {
            adoptExternalSolver(s)
            for rep in setup.reports {
                log(String(format: "  %@ = %.8g", rep.name, Reports.evaluate(rep, solver: s)))
            }
        }
        foamStatus = out.loadedTime.map { "Results loaded from time \($0) in \(out.caseDirectory.path)" } ?? "No results loaded"
        if !setup.openfoam.postProcessing.lineSamples.isEmpty, let samples = try? FoamPostResults.lineSamples(in: out.caseDirectory) { showLineSamples(samples) }
        isDirty = true
    }

    /// Make a solver holding external fields the current solution.
    private func adoptExternalSolver(_ s: PressureBasedSolver) {
        s.log = { [weak self] msg in DispatchQueue.main.async { self?.log(msg) } }
        solver = s
        post = PostProcessor(solver: s)
        initialized = true
        currentIteration = s.iteration
        flowTime = s.state.time
        if display.mode == .mesh { display.mode = .contours }
        refreshDisplay()
    }

    /// Write the OpenFOAM case without running it.
    func writeFoamCase() {
        guard let mesh else { log("No mesh loaded.", .error); return }
        guard approveFoamContent() else { return }
        let dir = foamCaseDirectory
        do {
            try FoamLocations.validate(dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FoamCasePreparation.clean(dir)
            let initial = (initialized && setup.openfoam.initialFields == .curlew) ? solver?.state : nil
            let r = try FoamCaseWriter.write(mesh: mesh, setup: setup, to: dir, initial: initial)
            for w in r.warnings { log(w, .warning) }
            foamLastCase = dir
            log("Wrote \(r.application.rawValue) case (\(r.files.count) files) to \(dir.path). Run ./Allrun there, or Calculate.")
        } catch { log("\(error)", .error) }
    }

    /// Read the latest time of the case directory into Curlew (e.g. after running Allrun by hand).
    func loadFoamResults() {
        guard let mesh else { log("No mesh loaded.", .error); return }
        let dir = foamCaseDirectory, s = setup
        let res = residuals, rep = reportHistory
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (solver, time) = try FoamSolve.load(caseDirectory: dir, mesh: mesh, setup: s)
                solver.restoreHistory(residuals: res, reports: rep)
                DispatchQueue.main.async {
                    self.adoptExternalSolver(solver)
                    self.foamStatus = "Results loaded from time \(time) in \(dir.path)"
                    self.log("Loaded OpenFOAM results at time \(time) from \(dir.path).")
                }
            } catch {
                DispatchQueue.main.async { self.log("Could not load OpenFOAM results: \(error)", .error) }
            }
        }
    }

    func cleanFoamCase() {
        let dir = foamCaseDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path) else {
            log("\(dir.path) is not an OpenFOAM case.", .warning); return
        }
        FoamCasePreparation.clean(dir)
        log("Removed results, processor directories and logs from \(dir.path).")
    }

    func revealFoamCase() {
        let dir = foamCaseDirectory
        if FileManager.default.fileExists(atPath: dir.path) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        else { log("\(dir.path) does not exist yet — write or run the case first.", .warning) }
    }

    /// Open the case in ParaView (built-in OpenFOAM reader via a `.foam` stub).
    func openFoamInParaView() {
        let dir = foamCaseDirectory
        let stub = dir.appendingPathComponent("case.foam")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path) else {
            log("Write or run the OpenFOAM case first.", .warning); return
        }
        if !FileManager.default.fileExists(atPath: stub.path) { FileManager.default.createFile(atPath: stub.path, contents: Data()) }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        guard let pv = apps.filter({ $0.lowercased().hasPrefix("paraview") && $0.hasSuffix(".app") }).sorted().last else {
            log("ParaView.app not found in /Applications.", .warning); return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([stub], withApplicationAt: URL(fileURLWithPath: "/Applications/" + pv), configuration: cfg) { _, err in
            if let err { DispatchQueue.main.async { self.log("ParaView: \(err.localizedDescription)", .error) } }
        }
        log("Opening \(stub.path) in \(pv)")
    }

    // MARK: snappyHexMesh

    func meshWithSnappy(_ s: SnappySettings) {
        guard !isMeshing, !isRunning else { return }
        isMeshing = true
        statusText = "snappyHexMesh…"
        log("Meshing \((s.path as NSString).lastPathComponent) with snappyHexMesh…", .command)
        let stem = URL(fileURLWithPath: s.path).deletingPathExtension().lastPathComponent
        let base = foamCaseDirectory
        let dir = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "_mesh_" + String(stem.map { $0.isLetter || $0.isNumber ? $0 : "_" }))
        let setupCopy = setup
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let env = try FoamLocations.installation(for: setupCopy).resolve()
                let r = try SnappyMesher.mesh(s, workDir: dir, environment: env, log: { t in
                    DispatchQueue.main.async { self.log(t.trimmingCharacters(in: .newlines)) }
                })
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    self.log(r.summary)
                    self.setMesh(r.mesh, source: "snappyHexMesh (\((s.path as NSString).lastPathComponent))")
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }
}
