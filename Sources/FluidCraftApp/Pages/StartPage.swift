import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftFoam

/// The first page: start a case, reopen one, learn with a tutorial, or pick a module.
/// Also says whether the programs FluidCraft needs are installed.
struct StartPage: View {
    @Bindable var ws: Workspace
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fluidcraft.settingsTab") private var settingsTab = "general"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to FluidCraft").font(.title2.weight(.semibold))
                    Text("Set up a CFD case, mesh it with blockMesh, Gmsh or snappyHexMesh, solve it with OpenFOAM, and look at the results here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if !ws.openFOAMSummary.installed || !GmshDriver.isAvailable {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ws.openFOAMSummary.installed ? "Gmsh is not installed" : "OpenFOAM is not installed").fontWeight(.medium)
                            Text("FluidCraft solves with OpenFOAM and meshes CAD with Gmsh. Settings › Tools installs them with one click.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Settings › Tools") { settingsTab = "tools"; openSettings() }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section("Start") {
                action("New Case", "doc.badge.plus", "An empty case: generate or import a mesh, then set it up.") { ws.newCase() }
                action("Open Case…", "folder", "A .fluidcraft case saved earlier (older .curlew cases open too).") { ws.openCase() }
                action("Import Mesh…", "square.and.arrow.down", "Fluent .msh/.cas, Gmsh .msh or an OpenFOAM case.") { ws.chooseMeshFile() }
                action("Analyse a CAD Model…", "cube.transparent", "STEP, IGES, STL…: FluidCraft sizes the domain, meshes and sets up the run.") { ws.chooseCADFileForAnalysis() }
            }

            let recent = ws.recentCases.prefix(6)
            if !recent.isEmpty {
                Section("Recent Cases") {
                    ForEach(Array(recent), id: \.self) { u in
                        action(u.deletingPathExtension().lastPathComponent, "clock", u.deletingLastPathComponent().path) { ws.openCase(url: u) }
                    }
                }
            }

            Section("Learn with a Tutorial") {
                ForEach(TutorialCatalog.core.prefix(6)) { t in
                    action(t.title, "book", t.summary) { ws.loadTutorial(t) }
                        .disabled(ws.isRunning || ws.isMeshing || (t.needsGmsh && !GmshDriver.isAvailable))
                }
                Button("All tutorials and the validation suite…") { ws.selectModule(.tutorials) }
                    .buttonStyle(.link)
            }

            Section("Modules") {
                ForEach(ModuleCategory.allCases) { cat in
                    HStack(alignment: .firstTextBaseline) {
                        SymbolLabel(cat.title, symbol: cat.symbol).frame(width: 190, alignment: .leading)
                        HStack(spacing: 10) {
                            ForEach(cat.modules) { m in
                                Button(shortTitle(m)) { ws.selectModule(m) }.buttonStyle(.link)
                                    .disabled(m.needsGmsh && !GmshDriver.isAvailable)
                            }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("FluidCraft Guide") { openWindow(id: "guide") }
                    Text("Getting started, the workflow, modules, files and troubleshooting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    func action(_ title: String, _ symbol: String, _ detail: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ws.isRunning)
    }

    /// Module names without the bracketed detail, for the compact list.
    func shortTitle(_ m: AppModule) -> String {
        m.title.components(separatedBy: " (").first ?? m.title
    }
}

extension Workspace {
    func chooseMeshFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowedContentTypes = ["msh", "cas", "crlmesh"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        p.message = "Choose a Fluent or Gmsh .msh file, or an OpenFOAM case folder"
        if p.runModal() == .OK, let u = p.url { importMesh(url: u) }
    }
}
