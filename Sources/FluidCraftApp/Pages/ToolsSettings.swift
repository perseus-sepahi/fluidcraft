import SwiftUI
import AppKit
import FluidCraftMesh
import FluidCraftFoam

/// Settings › Tools: the programs FluidCraft drives, whether each is installed, and how to get it.
struct ToolsSettingsView: View {
    @State private var status: [ExternalTool: ExternalTool.Status] = [:]
    @State private var checking = false
    @State private var installing: ExternalTool?
    @State private var progress: [String] = []
    @State private var message = ""
    @AppStorage("fluidcraft.gmsh") private var gmshPath = ""

    var body: some View {
        Form {
            Section {
                Text("FluidCraft is the interface, case setup and pre/post-processing; these programs do the solving and meshing. Required tools must be installed before running cases.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ExternalTool.allCases) { t in
                Section { row(t) } header: {
                    HStack {
                        Text(t.name)
                        Text(t.required ? "Required" : "Optional")
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(t.required ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            if !progress.isEmpty || !message.isEmpty {
                Section(installing.map { "Installing \($0.name)…" } ?? "Install log") {
                    if !progress.isEmpty {
                        ScrollView {
                            Text(progress.suffix(40).joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(height: 140)
                    }
                    if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                }
            }
            Section {
                HStack {
                    Button("Check Again") { refresh() }.disabled(checking || installing != nil)
                    if checking { ProgressView().controlSize(.small) }
                }
                Text("Installs run Homebrew (brew) directly, without a shell, and only when you click Install. Paths and choices are FluidCraft preferences, never stored in case files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onAppear { if status.isEmpty { refresh() } }
    }

    @ViewBuilder func row(_ t: ExternalTool) -> some View {
        let st = status[t]
        Text(t.role).font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline) {
            if let st {
                Image(systemName: st.found ? "checkmark.circle.fill" : (t.required ? "xmark.octagon.fill" : "minus.circle"))
                    .foregroundStyle(st.found ? .green : (t.required ? .red : .secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.found ? [st.version.map { "Version \($0)" }, st.location].compactMap { $0 }.joined(separator: " — ") : "Not found")
                        .font(.caption).textSelection(.enabled)
                    if let d = st.detail { Text(d).font(.caption2).foregroundStyle(.secondary) }
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption)
            }
            Spacer()
        }
        if t == .gmsh {
            HStack {
                TextField("Gmsh executable", text: $gmshPath, prompt: Text("found automatically")).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseGmsh() }
                if !gmshPath.isEmpty { Button("Clear") { gmshPath = ""; refresh() } }
            }
        }
        HStack {
            if t == .python {
                Text("PyTorch: Machine Learning tab").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Download Page") { NSWorkspace.shared.open(t.website) }
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.terminalCommand, forType: .string)
                message = "Copied: \(t.terminalCommand) — paste it into Terminal."
            }
            .help(t.terminalCommand)
            // only offered when missing: an existing copy may not come from Homebrew
            if t.brewArguments != nil, st?.found == false {
                Button("Install…") { install(t) }
                    .disabled(installing != nil || status[.homebrew]?.found != true)
                    .help(status[.homebrew]?.found == true ? "brew " + (t.brewArguments ?? []).joined(separator: " ") : "Install Homebrew first, or use the download page")
            }
        }
    }

    func refresh() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [ExternalTool: ExternalTool.Status] = [:]
            for t in ExternalTool.allCases { out[t] = t.detect() }
            DispatchQueue.main.async { status = out; checking = false }
        }
    }

    func chooseGmsh() {
        let p = NSOpenPanel()
        p.message = "Choose the gmsh program (inside Gmsh.app: Contents/MacOS/gmsh)"
        p.canChooseFiles = true; p.canChooseDirectories = false
        p.treatsFilePackagesAsDirectories = true
        guard p.runModal() == .OK, let u = p.url else { return }
        var path = u.path
        if u.pathExtension == "app" { path = u.appendingPathComponent("Contents/MacOS/gmsh").path }
        guard FileManager.default.isExecutableFile(atPath: path) else { message = "\(path) is not an executable program."; return }
        gmshPath = path
        refresh()
    }

    func install(_ t: ExternalTool) {
        let a = NSAlert()
        a.messageText = "Install \(t.name) with Homebrew?"
        a.informativeText = "FluidCraft runs “\(t.terminalCommand)”, which downloads \(t.downloadSize) from \(t == .openfoam ? "GitHub (gerlero/openfoam tap)" : "Homebrew") and installs it. You can follow the output here."
        a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Install")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        installing = t; progress = []; message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try t.install(log: { l in DispatchQueue.main.async { progress.append(l) } }) } catch { err = "\(error)" }
            let st = t.detect()
            DispatchQueue.main.async {
                installing = nil
                status[t] = st
                message = err ?? (st.found ? "\(t.name) is installed\(st.version.map { " (\($0))" } ?? "")." : "Homebrew finished, but \(t.name) was not found; use Check Again or the download page.")
            }
        }
    }
}
