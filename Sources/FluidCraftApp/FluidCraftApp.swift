import SwiftUI
import UniformTypeIdentifiers
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftPost
import FluidCraftFoam

@main
struct FluidCraftApp: App {
    @State private var ws = Workspace()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("FluidCraft") {
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
                Menu("Open Recent") {
                    ForEach(ws.recentCases, id: \.self) { u in
                        Button(u.deletingPathExtension().lastPathComponent) { ws.openCase(url: u) }
                    }
                    Divider()
                    Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                }
                Divider()
                Button("Import Mesh…") { ws.chooseMeshFile() }
                    .keyboardShortcut("i")
                Button("Import CAD for Analysis…") { ws.chooseCADFileForAnalysis() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(ws.isMeshing || ws.isRunning)
                Menu("CAD Samples") {
                    ForEach(CADSample.allCases) { sm in
                        Button(sm.title) { ws.chooseCADSample(sm) }
                    }
                }
                .disabled(ws.isMeshing || ws.isRunning || !GmshDriver.isAvailable)
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
                Divider()
                Button("Write OpenFOAM Case") { ws.writeFoamCase() }.disabled(ws.mesh == nil || ws.isRunning)
                Button("Load OpenFOAM Results") { ws.loadFoamResults() }.disabled(ws.mesh == nil || ws.isRunning)
                Button("Open OpenFOAM Case in ParaView") { ws.openFoamInParaView() }
            }
            CommandMenu("Tutorials") {
                ForEach(TutorialCatalog.core) { t in
                    Button(t.title) { ws.loadTutorial(t) }.disabled(t.needsGmsh && !GmshDriver.isAvailable)
                }
            }
            HelpCommands(ws: ws)
        }
        Settings {
            SettingsView()
        }
        Window("FluidCraft Guide", id: "guide") {
            GuideView()
        }
        .defaultSize(width: 1000, height: 780)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var ws: Workspace?
    func applicationWillFinishLaunching(_ notification: Notification) { LegacyPreferences.migrate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        if CasePackage.isCase(u) { ws?.openCase(url: u) } else { ws?.importMesh(url: u) }
    }
}

struct SettingsView: View {
    @AppStorage("fluidcraft.settingsTab") private var tab = "general"
    @AppStorage("fluidcraft.cadConverter") private var converter = ""
    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ToolsSettingsView().tabItem { Label("Tools", systemImage: "shippingbox") }.tag("tools")
            AISettingsView().tabItem { Label { Text("AI") } icon: { Image(nsImage: FluidCraftIcons.ai) } }.tag("ai")
            MachineLearningSettingsView().tabItem { Label("Machine Learning", systemImage: "chart.line.downtrend.xyaxis") }.tag("ml")
        }
        .frame(width: 680)
    }
    var general: some View {
        Form {
            Section("Native CAD formats") {
                TextField("Converter command", text: $converter, prompt: Text("/path/to/ExchangerConv -i {input} -e {output}"))
                    .textFieldStyle(.roundedBorder)
                Text("SolidWorks, CATIA, Parasolid, Creo/NX, Inventor, Solid Edge, Rhino, ACIS, JT and IFC files are converted to STEP by this program, run directly without a shell ({input} and {output} are replaced by the file paths; quote words that contain spaces). It is stored in FluidCraft's preferences, never in case files. Leave empty to import STEP/IGES exported from those systems instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Metal GPU (graphics)", value: MTLCreateSystemDefaultDevice()?.name ?? "none")
            Text("OpenFOAM, Gmsh, ParaView and Python are found, checked and installed in the Tools tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 560)
    }
}

import Metal
