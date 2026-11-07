import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver
import CurlewPost
import CurlewFoam

/// Workspace state saved alongside a case (surfaces, display settings).
struct WorkspaceExtras: Codable {
    var namedSurfaces: [NamedSurface]
    var displayField: String
    var colormap: Colormap
    var module: AppModule? = nil
    var moduleParameters: ModuleParameters? = nil
}

extension Workspace {
    // MARK: Tutorials

    func loadTutorial(_ t: Tutorial) {
        guard !isRunning else { return }
        isMeshing = true
        statusText = "Preparing \(t.title)…"
        log("Loading tutorial: \(t.title)", .command)
        let build = t.build
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (mesh, setup) = try build()
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    self.setup = setup
                    self.setMesh(mesh, source: t.title)
                    self.setup = setup
                    self.setup.adopt(mesh: mesh)
                    self.display.field = t.suggestedField
                    self.display.surfaces = []
                    self.namedSurfaces = []
                    self.documentURL = nil
                    self.log(t.summary)
                    self.log("Next: review Setup, then Solution › Run Calculation (⌘R). Results › Contours shows \(t.suggestedField).")
                    self.selection = .boundaries
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    // MARK: Case files

    func newCase() {
        guard !isRunning else { return }
        mesh = nil; solver = nil; post = nil; initialized = false
        setup = CaseSetup()
        residuals = ResidualHistory(); reportHistory = ReportHistory()
        namedSurfaces = []; xyPlot = nil; documentURL = nil
        scene = SceneContent()
        selection = .meshGeneration
        log("New case.", .command)
    }

    func saveCase(as: Bool) {
        guard let mesh else { log("Nothing to save — no mesh.", .warning); return }
        var url = documentURL
        if url == nil || `as` {
            let p = NSSavePanel()
            p.allowedContentTypes = [UTType(filenameExtension: "curlew") ?? .package]
            p.nameFieldStringValue = (setup.title == "Untitled" ? "case" : setup.title.replacingOccurrences(of: "/", with: "-")) + ".curlew"
            guard p.runModal() == .OK, let u = p.url else { return }
            url = u
        }
        guard let dir = url else { return }
        do {
            let withData = (initialized && !isRunning) ? solver : nil
            try CasePackage.write(to: dir, mesh: mesh, setup: setup, solver: withData)
            let extras = WorkspaceExtras(namedSurfaces: namedSurfaces, displayField: display.field, colormap: display.colormap,
                                         module: activeModule, moduleParameters: moduleParams)
            try JSONEncoder().encode(extras).write(to: dir.appendingPathComponent("workspace.json"))
            documentURL = dir
            isDirty = false
            log("Wrote case\(initialized ? " and data" : "") to \(dir.path)")
        } catch { log("Save failed: \(error)", .error) }
    }

    func openCase() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "curlew") ?? .package, .folder]
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        if p.runModal() == .OK, let u = p.url { openCase(url: u) }
    }

    func openCase(url dir: URL) {
        guard !isRunning else { return }
        do {
            let pkg = try CasePackage.read(dir)
            let s = pkg.setup, m = pkg.mesh
            setMesh(m, source: dir.lastPathComponent)
            setup = s
            setup.adopt(mesh: m)
            if let e = try? JSONDecoder().decode(WorkspaceExtras.self, from: Data(contentsOf: dir.appendingPathComponent("workspace.json"))) {
                namedSurfaces = e.namedSurfaces; display.field = e.displayField; display.colormap = e.colormap
                if let m = e.module { activeModule = m }
                if let p = e.moduleParameters { moduleParams = p }
            }
            documentURL = dir
            foamUnapprovedContent = s.openfoam.activeContent
            if !foamUnapprovedContent.isEmpty {
                log("This case has \(foamUnapprovedContent.count) custom OpenFOAM item(s) (stages, function objects, dictionary text or files); you will be asked to approve them before OpenFOAM runs.", .warning)
            }
            if pkg.hasData, let solver = ensureSolver() {
                try CasePackage.restore(dir, into: solver)
                residuals = solver.residuals; reportHistory = solver.reportHistory
                initialized = true
                currentIteration = solver.iteration
                flowTime = solver.state.time
                display.mode = .contours
                refreshDisplay()
                log("Read data: iteration \(solver.iteration)\(setup.general.time == .transient ? String(format: ", flow time %.5g s", solver.state.time) : "")")
            }
            isDirty = false
            selection = .general
        } catch { log("Open failed: \(error)", .error) }
    }

    // MARK: Export

    func exportVTK() {
        guard let s = solver, initialized else { log("Initialize or solve first.", .warning); return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "vtu") ?? .data]
        p.nameFieldStringValue = "solution.vtu"
        if p.runModal() == .OK, let u = p.url {
            do { try VTKExport.write(solver: s, to: u); log("Wrote \(u.path) (open in ParaView)") } catch { log("\(error)", .error) }
        }
    }

    func exportCSV() {
        guard let s = solver, initialized else { log("Initialize or solve first.", .warning); return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "cells.csv"
        if p.runModal() == .OK, let u = p.url {
            do { try VTKExport.writeCSV(solver: s, fields: FieldCatalog.available(for: s), to: u); log("Wrote \(u.path)") } catch { log("\(error)", .error) }
        }
    }

    func exportFluentMesh() {
        guard let m = mesh else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "msh") ?? .data]
        p.nameFieldStringValue = "mesh.msh"
        if p.runModal() == .OK, let u = p.url {
            do { try MeshWriters.fluentMesh(m).write(to: u, atomically: true, encoding: .utf8); log("Wrote Fluent mesh \(u.path)") } catch { log("\(error)", .error) }
        }
    }

    func exportFoamCase() {
        guard let m = mesh else { return }
        guard approveFoamContent() else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Export Here"
        p.message = "Choose an empty folder for the OpenFOAM case"
        if p.runModal() == .OK, let u = p.url {
            do {
                let r = try FoamCaseWriter.write(mesh: m, setup: setup, to: u)
                for w in r.warnings { log(w, .warning) }
                log("Wrote OpenFOAM case to \(u.path) (\(r.application.rawValue); run ./Allrun there)")
            } catch { log("\(error)", .error) }
        }
    }
}
