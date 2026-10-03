import SwiftUI
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver
import CurlewPost

@main
struct CurlewApp: App {
    @State private var ws = Workspace()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Curlew") {
            ContentView(ws: ws)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.ws = ws }
        }
        .defaultSize(width: 1560, height: 980)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Case") { ws.newCase() }.keyboardShortcut("n")
                Button("Open Case…") { ws.openCase() }.keyboardShortcut("o")
                Divider()
                Button("Import Mesh…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.allowedContentTypes = ["msh", "cas", "crlmesh"].compactMap { UTType(filenameExtension: $0) } + [.folder]
                    if p.runModal() == .OK, let u = p.url { ws.importMesh(url: u) }
                }
                .keyboardShortcut("i")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Case & Data") { ws.saveCase(as: false) }.keyboardShortcut("s")
                Button("Save Case & Data As…") { ws.saveCase(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu("Export") {
                    Button("Solution to ParaView (.vtu)…") { ws.exportVTK() }
                    Button("Cell Data (CSV)…") { ws.exportCSV() }
                    Button("Mesh as Fluent .msh…") { ws.exportFluentMesh() }
                    Button("OpenFOAM Case…") { ws.exportFoamCase() }
                }
                .disabled(ws.mesh == nil)
            }
            CommandMenu("Solve") {
                Button("Initialize") { ws.initialize() }.disabled(ws.mesh == nil || ws.isRunning)
                Button("Calculate") { ws.calculate() }.disabled(ws.mesh == nil || ws.isRunning)
                Button("Stop") { ws.stop() }.disabled(!ws.isRunning).keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("Tutorials") {
                ForEach(TutorialCatalog.all) { t in
                    Button(t.title) { ws.loadTutorial(t) }.disabled(t.needsGmsh && !GmshDriver.isAvailable)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Curlew Help") { ws.selection = .validation; ws.execute("help") }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var ws: Workspace?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        if u.pathExtension == "curlew" { ws?.openCase(url: u) } else { ws?.importMesh(url: u) }
    }
}

struct SettingsView: View {
    @AppStorage("curlew.threads") private var threads = 0
    var body: some View {
        Form {
            LabeledContent("Gmsh", value: GmshDriver.executable?.path ?? "not found")
            LabeledContent("Metal GPU", value: MTLCreateSystemDefaultDevice()?.name ?? "none")
            Text("Curlew uses every performance core for assembly and AMG; parallel reductions are deterministic.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 460)
    }
}

import Metal
