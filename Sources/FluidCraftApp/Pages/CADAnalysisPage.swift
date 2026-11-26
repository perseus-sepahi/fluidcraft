import SwiftUI
import UniformTypeIdentifiers
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftFoam

/// "Import CAD for Analysis": pick a CAD file (or a built-in sample) and an analysis type;
/// FluidCraft meshes it and sets up materials, boundary conditions, turbulence model, reference
/// values and reports, ready for OpenFOAM.
struct CADAnalysisPage: View {
    @Bindable var ws: Workspace

    var body: some View {
        Form {
            Section("Samples") {
                ForEach(CADSample.allCases) { s in
                    Button {
                        ws.chooseCADSample(s)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).fontWeight(.medium)
                            Text(s.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(ws.isMeshing || !GmshDriver.isAvailable)
                }
                Text("Each sample is an OpenCASCADE model saved as STEP in \(CADSample.directory.path), so it behaves exactly like a file exported from a CAD system.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Geometry") {
                HStack {
                    Text(ws.cadSpec.path.isEmpty ? "No file" : (ws.cadSpec.path as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose CAD File…") { ws.chooseCADFileForAnalysis() }
                }
                if let f = CADFormat.detect(URL(fileURLWithPath: ws.cadSpec.path)) {
                    LabeledContent("Format", value: f.displayName + (f.isBRep ? " — exact geometry" : " — triangulated surface"))
                }
                Toggle("Use the file's units when it declares them (STEP from SolidWorks, SolidCraft, …)", isOn: $ws.cadSpec.unitFromFile)
                Picker("File units", selection: $ws.cadSpec.unit) {
                    ForEach(CADUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("SolidWorks: export STEP (AP214/AP242), IGES or STL (File › Save As). SolidCraft: open its .sc design directly (SolidCraft's own tool writes STEP\(SolidCraftBridge.isAvailable ? ", found" : "; not found on this Mac") ) or export STEP, 3MF or STL. Native .sldprt and Parasolid files need a converter (Settings › General).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ws.cadSpec.kind != .internalFlow {
                Section("Region to simulate") {
                    let m = Binding(get: { ws.cadSpec.domainMargins ?? CADAnalysisSpec.defaultMargins(ws.cadSpec.kind) },
                                    set: { ws.cadSpec.domainMargins = $0 })
                    let labels = ["Upstream", "Downstream", "Beside (each side)", "Below", "Above"]
                    ForEach(0..<5, id: \.self) { i in
                        if !(i == 3 && (ws.cadSpec.onGround || ws.cadSpec.kind == .conjugateHeatSink)) {
                            NumberField(label: labels[i], value: Binding(get: { m.wrappedValue[safe: i] ?? 0 },
                                                                         set: { var a = m.wrappedValue; while a.count < 5 { a.append(0) }; a[i] = $0; m.wrappedValue = a }),
                                        unit: "body lengths")
                        }
                    }
                    if ws.cadSpec.kind == .externalAerodynamics {
                        Toggle("The body stands on the ground (cars, buildings, wind-tunnel models)", isOn: $ws.cadSpec.onGround)
                        if ws.cadSpec.onGround { Toggle("Moving ground at the free-stream speed (rolling road)", isOn: $ws.cadSpec.movingGround) }
                    }
                    Toggle("Refine a region (e.g. the wake)", isOn: Binding(get: { ws.cadSpec.refinementBox != nil }, set: { on in
                        ws.cadSpec.refinementBox = on ? [0, -0.5, -0.5, 1, 0.5, 0.5] : nil
                    }))
                    if ws.cadSpec.refinementBox != nil {
                        let rb = Binding(get: { ws.cadSpec.refinementBox ?? [0, 0, 0, 1, 1, 1] }, set: { ws.cadSpec.refinementBox = $0 })
                        VectorField(label: "Minimum corner", value: Binding(get: { Array(rb.wrappedValue.prefix(3)) }, set: { rb.wrappedValue = $0 + Array(rb.wrappedValue.suffix(3)) }), unit: "m")
                        VectorField(label: "Maximum corner", value: Binding(get: { Array(rb.wrappedValue.suffix(3)) }, set: { rb.wrappedValue = Array(rb.wrappedValue.prefix(3)) + $0 }), unit: "m")
                        NumberField(label: "Cell size there (0 = twice the wall size)", value: $ws.cadSpec.refinementSize, unit: "m")
                    }
                    Text("The flow domain is a box around the model, sized in body lengths; corners of the refinement box are in metres (model coordinates after units). Gmsh and snappyHexMesh mesh exactly this region.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Analysis") {
                Picker("Type", selection: $ws.cadSpec.kind) {
                    ForEach(CADAnalysisSpec.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Flow direction", selection: $ws.cadSpec.flowAxis) {
                    Text("+x").tag(0); Text("+y").tag(1); Text("+z").tag(2)
                }
                .pickerStyle(.segmented)
                NumberField(label: ws.cadSpec.kind == .internalFlow ? "Inlet velocity" : "Free-stream speed", value: $ws.cadSpec.speed, unit: "m/s")
                Picker("Fluid", selection: $ws.cadSpec.fluid) {
                    ForEach(fluids, id: \.self) { Text($0).tag($0) }
                }
                NumberField(label: "Inlet temperature", value: $ws.cadSpec.inletTemperature, unit: "K")
                if ws.cadSpec.kind == .conjugateHeatSink {
                    Picker("Solid", selection: $ws.cadSpec.solid) {
                        ForEach(solids, id: \.self) { Text($0).tag($0) }
                    }
                    NumberField(label: "Heat load", value: $ws.cadSpec.heatLoad, unit: "W")
                }
                Text(kindHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section("Mesh") {
                Picker("Mesher", selection: $ws.cadSpec.mesher) {
                    Text("Gmsh — tetrahedra + prism layers").tag(CADAnalysisSpec.Mesher.gmsh)
                    Text("snappyHexMesh — hex-dominant (OpenFOAM)").tag(CADAnalysisSpec.Mesher.snappyHexMesh)
                }
                .disabled(ws.cadSpec.kind == .conjugateHeatSink)
                Picker("Resolution", selection: $ws.cadSpec.level) {
                    ForEach(CADAnalysisSpec.Level.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Prism (boundary) layers on walls", isOn: $ws.cadSpec.prismLayers)
                Text("Cell sizes follow the model size and the Reynolds number; the turbulence model (laminar or k-ω SST) and the first-layer height are chosen from it. Conjugate cases are meshed with Gmsh, with a conformal solid–fluid interface.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Run") {
                IntField(label: "OpenFOAM cores", value: $ws.cadSpec.cores)
                HStack {
                    Button(ws.isMeshing ? "Building…" : "Build Case") { ws.buildCADAnalysis(run: false) }
                    Button("Build and Run") { ws.buildCADAnalysis(run: true) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(ws.cadSpec.path.isEmpty || ws.isMeshing || ws.isRunning || !GmshDriver.isAvailable)
                if !GmshDriver.isAvailable {
                    Label("Gmsh is needed (install Gmsh.app).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    var fluids: [String] {
        let names = MaterialLibrary.all.filter { $0.kind == .fluid }.map(\.name)
        return names.contains(ws.cadSpec.fluid) ? names : [ws.cadSpec.fluid] + names
    }
    var solids: [String] {
        let names = MaterialLibrary.all.filter { $0.kind == .solid }.map(\.name)
        return names.contains(ws.cadSpec.solid) ? names : [ws.cadSpec.solid] + names
    }

    var kindHelp: String {
        switch ws.cadSpec.kind {
        case .externalAerodynamics:
            return "The body sits in a box (3 lengths upstream, 8 downstream): inlet and outlet across the flow direction, symmetry on the other faces. Reports: drag and lift coefficients and the drag force."
        case .internalFlow:
            return "The model is the fluid volume. Flat openings are found automatically: inlet on the upstream end, outlets on the others. Reports: mass flow through each opening and the inlet pressure (pressure drop)."
        case .conjugateHeatSink:
            return "The solid sits on the floor of an air duct and is heated through its lowest face. Fluid and solid are separate regions with a coupled interface. Reports: maximum solid temperature, base temperature, heat into the air and the duct pressure drop."
        }
    }
}

extension Workspace {
    func chooseCADFileForAnalysis() {
        let p = NSOpenPanel()
        p.allowedContentTypes = CADFormat.extensions.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a CAD model to analyse: STEP, IGES, BREP (exact) or STL, OBJ, PLY, 3MF, glTF (triangulated)"
        if p.runModal() == .OK, let u = p.url {
            cadSpec.path = u.path
            if cadSpec.unitFromFile {
                if CADFormat.detect(u) == .solidcraft { cadSpec.unit = .millimetre }
                else if let du = CADConversion.declaredUnit(u.path) { cadSpec.unit = du; log("\(u.lastPathComponent) declares \(du.rawValue).") }
            }
            if let f = CADFormat.detect(u), !f.isBRep, f != .threeMF,
               let surf = try? SurfaceReader.read(url: u) {
                let (lo, hi) = surf.bounds
                if max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) > 50 {
                    cadSpec.unit = .millimetre
                    log("\(u.lastPathComponent): large coordinates — assuming millimetres (change File units if not).")
                }
            }
            selectModule(.cadAnalysis)
        }
    }

    /// Build (if needed) a sample's STEP file and pre-fill the analysis for it.
    func chooseCADSample(_ s: CADSample) {
        statusText = "Building sample \(s.rawValue)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try s.export(to: CADSample.directory)
                DispatchQueue.main.async {
                    var spec = CADAnalysisSpec.sample(s, path: url.path)
                    spec.cores = self.cadSpec.cores
                    self.cadSpec = spec
                    self.statusText = "Ready"
                    self.selectModule(.cadAnalysis)
                    self.log("Sample \(s.title): \(url.path). \(s.summary)")
                }
            } catch {
                DispatchQueue.main.async { self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    /// Mesh the CAD, set up the case and optionally run it with OpenFOAM.
    func buildCADAnalysis(run: Bool) {
        guard !isMeshing, !isRunning, !cadSpec.path.isEmpty else { return }
        let spec = cadSpec
        let base = setup
        isMeshing = true
        statusText = "Meshing \((spec.path as NSString).lastPathComponent)…"
        log("CAD analysis: \(spec.kind.displayName) of \((spec.path as NSString).lastPathComponent)", .command)
        let stem = URL(fileURLWithPath: spec.path).deletingPathExtension().lastPathComponent
        let work = FoamLocations.defaultCaseDirectory(title: "cad-" + stem)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let env = spec.mesher == .snappyHexMesh && spec.kind != .conjugateHeatSink
                    ? try FoamLocations.installation(for: base).resolve() : nil
                let built = try CADAnalysis.build(spec, workDir: work.appendingPathComponent("mesh"), environment: env, log: { t in
                    let line = t.trimmingCharacters(in: .newlines)
                    if !line.isEmpty { DispatchQueue.main.async { self.log(line) } }
                })
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    var s = built.setup
                    s.openfoam.installation = base.openfoam.installation
                    s.openfoam.caseDirectory = work.appendingPathComponent("run").path
                    s.openfoam.cores = max(1, spec.cores)
                    self.setMesh(built.mesh, source: "CAD analysis (\((spec.path as NSString).lastPathComponent))")
                    self.setup = s
                    self.setup.adopt(mesh: built.mesh)
                    self.display.field = spec.kind == .conjugateHeatSink ? "temperature" : "velocity-magnitude"
                    self.namedSurfaces = []
                    self.documentURL = nil
                    self.log(built.summary)
                    for r in s.reports { self.log("  report \(r.name)") }
                    if run {
                        self.calculate()
                    } else {
                        self.selection = .boundaries
                        self.log("Next: review Setup, then Solution › Run Calculation (⌘R).")
                    }
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }
}
