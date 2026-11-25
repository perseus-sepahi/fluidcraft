import SwiftUI
import AppKit
import CurlewMesh
import CurlewSolver
import CurlewFoam

// MARK: - Workspace actions

extension Workspace {
    /// Run the post-processing settings on the existing OpenFOAM case (latest time).
    func runPostProcessingNow() {
        guard !isRunning else { return }
        let dir = foamLastCase ?? foamCaseDirectory
        let s = setup
        isRunning = true
        statusText = "OpenFOAM post-processing…"
        log("Post-processing \(dir.path) (latest time)", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let env = try FoamLocations.installation(for: s).resolve()
                let samples = try FoamSolve.postProcess(caseDirectory: dir, setup: s, environment: env, log: { l in DispatchQueue.main.async { self.log(l) } })
                DispatchQueue.main.async {
                    self.isRunning = false; self.statusText = "Ready"
                    self.showLineSamples(samples)
                    self.log("Post-processing done: results in \(dir.appendingPathComponent("postProcessing").path)\(s.openfoam.postProcessing.exportVTK ? " and VTK/" : "").")
                }
            } catch {
                DispatchQueue.main.async { self.isRunning = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    /// Show OpenFOAM line samples in the XY plot (every column against distance).
    func showLineSamples(_ samples: [FoamPostResults.LineSample]) {
        guard let first = samples.first, first.columns.count > 1 else { return }
        var series: [XYPlotData.Series] = []
        for smp in samples {
            for (ci, name) in smp.columns.enumerated().dropFirst() {
                series.append(.init(name: samples.count > 1 ? "\(smp.name): \(name)" : name,
                                    points: smp.rows.enumerated().map { XYPoint(id: $0.offset, x: $0.element[0], y: $0.element[ci]) }))
            }
        }
        xyPlot = XYPlotData(title: "OpenFOAM line samples (time \(first.time))", xLabel: "Distance along line (m)", yLabel: "value", series: series)
        graphicsTab = .xy
        log("Line samples (\(samples.map(\.name).joined(separator: ", "))) are in the XY Plot tab.")
    }

    /// Run one Python post-processing script on the latest time of the OpenFOAM case.
    func runPostScript(_ script: FoamPostScript) {
        guard postScriptRunning == nil else { return }
        // scripts saved in a case opened from disk run code: ask first, like any custom case content
        guard approveFoamContent() else { return }
        let dir = foamLastCase ?? foamCaseDirectory
        let s = setup
        postScriptRunning = script.name
        log("Python script \(script.name) on \(dir.path)", .command)
        let job = PostScriptRun()
        postScriptJob = job
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try job.run(script, caseDirectory: dir, setup: s, log: { l in DispatchQueue.main.async { self.log(l) } })
                DispatchQueue.main.async {
                    self.postScriptRunning = nil; self.postScriptJob = nil
                    self.postScriptResults[script.outputName] = r
                    if r.succeeded { self.log(String(format: "%@ finished (%.1f s): %d reports, %d figures%@", script.name, r.seconds, r.reports.count, r.figures.count,
                                                     r.fields.isEmpty ? "" : ", fields " + r.fields.joined(separator: ", "))) }
                    else { self.log("\(script.name) failed (exit \(r.exitCode)). " + (r.log.last ?? ""), .error) }
                }
            } catch {
                DispatchQueue.main.async { self.postScriptRunning = nil; self.postScriptJob = nil; self.log("\(error)", .error) }
            }
        }
    }

    func openFoamFolder(_ sub: String) {
        let dir = (foamLastCase ?? foamCaseDirectory).appendingPathComponent(sub)
        if FileManager.default.fileExists(atPath: dir.path) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        else { log("\(dir.path) does not exist yet.", .warning) }
    }
}

// MARK: - Pages

struct PreProcessingPage: View {
    @Bindable var ws: Workspace
    var pre: Binding<FoamPreProcessing> { $ws.setup.openfoam.preProcessing }
    var body: some View {
        Form {
            Section("Start from another solution (mapFields)") {
                HStack {
                    TextField("OpenFOAM case folder", text: pre.mapFieldsSource, prompt: Text("off"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        p.message = "Choose an OpenFOAM case folder (with a solution time)"
                        if p.runModal() == .OK, let u = p.url { ws.setup.openfoam.preProcessing.mapFieldsSource = u.path }
                    }
                }
                Toggle("Same geometry and patch names (-consistent)", isOn: pre.mapFieldsConsistent)
                Text("The latest time of that case is interpolated onto this mesh before the run (e.g. a coarse-mesh solution onto a refined mesh).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Initial values in regions (setFields)") {
                ForEach(Array(ws.setup.openfoam.preProcessing.setFieldsRegions.enumerated()), id: \.offset) { i, _ in
                    let r = Binding<FoamSetFieldsRegion>.element(pre.setFieldsRegions, i, fallback: FoamSetFieldsRegion())
                    DisclosureGroup(r.wrappedValue.name) {
                        TextField("Name", text: r.name).textFieldStyle(.roundedBorder)
                        Picker("Shape", selection: r.shape) { ForEach(FoamSetFieldsRegion.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        switch r.wrappedValue.shape {
                        case .box: VectorField(label: "Minimum corner", value: r.a, unit: "m"); VectorField(label: "Maximum corner", value: r.b, unit: "m")
                        case .sphere: VectorField(label: "Centre", value: r.a, unit: "m"); NumberField(label: "Radius", value: r.radius, unit: "m")
                        case .cylinder: VectorField(label: "Axis start", value: r.a, unit: "m"); VectorField(label: "Axis end", value: r.b, unit: "m"); NumberField(label: "Radius", value: r.radius, unit: "m")
                        }
                        ForEach(Array(r.wrappedValue.values.enumerated()), id: \.offset) { j, _ in
                            let v = Binding<FoamFieldValue>.element(r.values, j, fallback: FoamFieldValue())
                            HStack {
                                TextField("field", text: v.field).textFieldStyle(.roundedBorder).frame(width: 90)
                                Toggle("vector", isOn: Binding(get: { v.wrappedValue.isVector }, set: { v.wrappedValue.vector = $0 ? [0, 0, 0] : nil })).toggleStyle(.checkbox)
                                if v.wrappedValue.isVector {
                                    VectorField(label: "", value: Binding(get: { v.wrappedValue.vector ?? [0, 0, 0] }, set: { v.wrappedValue.vector = $0 }))
                                } else {
                                    NumberField(label: "", value: v.scalar)
                                }
                                Button(role: .destructive) { r.wrappedValue.values.remove(at: j) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Button("Add Value") { r.wrappedValue.values.append(FoamFieldValue(field: "T", scalar: 300)) }
                            Button("Remove Region", role: .destructive) { ws.setup.openfoam.preProcessing.setFieldsRegions.remove(at: i) }
                        }
                    }
                }
                Button("Add Region") {
                    var nr = FoamSetFieldsRegion(name: "region\(ws.setup.openfoam.preProcessing.setFieldsRegions.count + 1)")
                    if let m = ws.mesh { nr.a = [m.bounds.min.x, m.bounds.min.y, m.bounds.min.z]; let c = 0.5 * (m.bounds.min + m.bounds.max); nr.b = [c.x, c.y, c.z] }
                    ws.setup.openfoam.preProcessing.setFieldsRegions.append(nr)
                }
                Text("OpenFOAM field names (U, p, p_rgh, T, k, omega, …) in SI units; pressures are converted to kinematic for incompressible solvers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Near-wall initial profile (applyBoundaryLayer)") {
                Toggle("Apply a boundary-layer profile to the initial velocity", isOn: Binding(get: { ws.setup.openfoam.preProcessing.boundaryLayerThickness != nil },
                                                                                               set: { ws.setup.openfoam.preProcessing.boundaryLayerThickness = $0 ? 0.01 : nil }))
                if ws.setup.openfoam.preProcessing.boundaryLayerThickness != nil {
                    NumberField(label: "Boundary-layer thickness", value: Binding(get: { ws.setup.openfoam.preProcessing.boundaryLayerThickness ?? 0.01 },
                                                                                  set: { ws.setup.openfoam.preProcessing.boundaryLayerThickness = $0 }), unit: "m")
                }
            }
            Section("Mesh check") {
                Toggle("Full checkMesh (-allGeometry -allTopology)", isOn: pre.fullMeshCheck)
                Text("Other pre-processing lives where it belongs: baffles, periodic patches and the velocity limiter on the OpenFOAM page, potential-flow initial fields on Initialization, decomposition on OpenFOAM › Parallel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { Text("These run as OpenFOAM stages before the solver, on the undecomposed case.").font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

struct PostProcessingPage: View {
    @Bindable var ws: Workspace
    var post: Binding<FoamPostProcessing> { $ws.setup.openfoam.postProcessing }
    var body: some View {
        Form {
            Section("Derived fields (function objects)") {
                ForEach(FoamPostProcessing.availableFunctions, id: \.name) { f in
                    Toggle(f.title, isOn: Binding(get: { ws.setup.openfoam.postProcessing.functions.contains(f.name) },
                                                  set: { on in
                                                      ws.setup.openfoam.postProcessing.functions.removeAll { $0 == f.name }
                                                      if on { ws.setup.openfoam.postProcessing.functions.append(f.name) }
                                                  }))
                }
                Text("Written into the latest time directory; they show up in Results › Contours once loaded and in ParaView.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Line samples → XY plot (sets)") {
                ForEach(Array(ws.setup.openfoam.postProcessing.lineSamples.enumerated()), id: \.offset) { i, _ in
                    let l = Binding<FoamLineSample>.element(post.lineSamples, i, fallback: FoamLineSample())
                    DisclosureGroup(l.wrappedValue.name) {
                        TextField("Name", text: l.name).textFieldStyle(.roundedBorder)
                        VectorField(label: "Start", value: l.start, unit: "m")
                        VectorField(label: "End", value: l.end, unit: "m")
                        IntField(label: "Points", value: l.points)
                        TextField("Fields (blank: U p T)", text: l.fields).textFieldStyle(.roundedBorder)
                        Button("Remove", role: .destructive) { ws.setup.openfoam.postProcessing.lineSamples.remove(at: i) }
                    }
                }
                Button("Add Line Sample") {
                    var nl = FoamLineSample(name: "line\(ws.setup.openfoam.postProcessing.lineSamples.count + 1)")
                    if let m = ws.mesh { let c = 0.5 * (m.bounds.min + m.bounds.max); nl.start = [m.bounds.min.x, c.y, c.z]; nl.end = [m.bounds.max.x, c.y, c.z] }
                    ws.setup.openfoam.postProcessing.lineSamples.append(nl)
                }
            }
            Section("Iso-surfaces (VTK)") {
                ForEach(Array(ws.setup.openfoam.postProcessing.isoSurfaces.enumerated()), id: \.offset) { i, _ in
                    let s = Binding<FoamIsoSurface>.element(post.isoSurfaces, i, fallback: FoamIsoSurface())
                    HStack {
                        TextField("name", text: s.name).textFieldStyle(.roundedBorder).frame(width: 90)
                        TextField("field", text: s.field).textFieldStyle(.roundedBorder).frame(width: 90)
                        NumberField(label: "value", value: s.value)
                        Button(role: .destructive) { ws.setup.openfoam.postProcessing.isoSurfaces.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Iso-Surface") { ws.setup.openfoam.postProcessing.isoSurfaces.append(FoamIsoSurface(name: "iso\(ws.setup.openfoam.postProcessing.isoSurfaces.count + 1)")) }
            }
            Section("Streamlines (VTK)") {
                Toggle("Streamlines seeded along a line", isOn: Binding(get: { ws.setup.openfoam.postProcessing.streamlineSeedStart != nil },
                                                                        set: { on in
                                                                            if on, let m = ws.mesh { let c = 0.5 * (m.bounds.min + m.bounds.max)
                                                                                ws.setup.openfoam.postProcessing.streamlineSeedStart = [m.bounds.min.x, m.bounds.min.y, c.z]
                                                                                ws.setup.openfoam.postProcessing.streamlineSeedEnd = [m.bounds.min.x, m.bounds.max.y, c.z]
                                                                            } else { ws.setup.openfoam.postProcessing.streamlineSeedStart = on ? [0, 0, 0] : nil } }))
                if ws.setup.openfoam.postProcessing.streamlineSeedStart != nil {
                    VectorField(label: "Seed line start", value: Binding(get: { ws.setup.openfoam.postProcessing.streamlineSeedStart ?? [0, 0, 0] }, set: { ws.setup.openfoam.postProcessing.streamlineSeedStart = $0 }), unit: "m")
                    VectorField(label: "Seed line end", value: post.streamlineSeedEnd, unit: "m")
                    IntField(label: "Seeds", value: post.streamlineSeeds)
                }
            }
            Section("Expression fields (exprField)") {
                ForEach(Array(ws.setup.openfoam.postProcessing.expressionFields.enumerated()), id: \.offset) { i, _ in
                    let e = Binding<FoamExpressionField>.element(post.expressionFields, i, fallback: FoamExpressionField())
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("name", text: e.name).textFieldStyle(.roundedBorder).frame(width: 120)
                            TextField("expression", text: e.expression).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                            Button(role: .destructive) { ws.setup.openfoam.postProcessing.expressionFields.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                        Toggle("Also evaluate while solving (each write)", isOn: e.duringRun).font(.caption)
                        if !e.wrappedValue.isSafe { Text("Quotes, #, $, ; and braces are not allowed in an expression.").font(.caption).foregroundStyle(.red) }
                    }
                }
                Button("Add Expression Field") {
                    ws.setup.openfoam.postProcessing.expressionFields.append(FoamExpressionField(name: "field\(ws.setup.openfoam.postProcessing.expressionFields.count + 1)", expression: "mag(U)"))
                }
                Text("OpenFOAM evaluates the expression on every cell: e.g. mag(U), p + 0.5*magSqr(U), pos().y(), T - 293.15, (mag(U) > 2) ? 1 : 0. The new field is written to the time directory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Histograms and heat-transfer coefficient") {
                ForEach(Array(ws.setup.openfoam.postProcessing.histograms.enumerated()), id: \.offset) { i, _ in
                    let h = Binding<FoamHistogram>.element(post.histograms, i, fallback: FoamHistogram())
                    HStack {
                        TextField("field", text: h.field).textFieldStyle(.roundedBorder).frame(width: 120)
                        IntField(label: "bins", value: h.bins)
                        Button(role: .destructive) { ws.setup.openfoam.postProcessing.histograms.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Histogram") { ws.setup.openfoam.postProcessing.histograms.append(FoamHistogram()) }
                Toggle("Wall heat-transfer coefficient (heatTransferCoeff, heat transfer)", isOn: post.heatTransferCoeff.enabled)
                if ws.setup.openfoam.postProcessing.heatTransferCoeff.enabled {
                    Picker("Reference temperature", selection: post.heatTransferCoeff.model) {
                        Text("Fixed: h = q / (T_wall − T_ref)").tag(FoamHeatTransferCoeff.Model.fixedReferenceTemperature)
                        Text("Near-wall cell: h = q / (T_wall − T_cell)").tag(FoamHeatTransferCoeff.Model.localReferenceTemperature)
                        Text("Reynolds analogy (from skin friction)").tag(FoamHeatTransferCoeff.Model.ReynoldsAnalogy)
                    }
                    if ws.setup.openfoam.postProcessing.heatTransferCoeff.model == .fixedReferenceTemperature {
                        NumberField(label: "T_ref", value: post.heatTransferCoeff.referenceTemperature, unit: "K")
                    }
                    TextField("Walls (comma separated; blank = all walls)", text: Binding(get: { ws.setup.openfoam.postProcessing.heatTransferCoeff.patches.joined(separator: ", ") },
                                                                                       set: { ws.setup.openfoam.postProcessing.heatTransferCoeff.patches = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            PostScriptsSection(ws: ws)
            Section("Export") {
                Toggle("VTK (foamToVTK)", isOn: post.exportVTK)
                Toggle("EnSight (foamToEnsight)", isOn: post.exportEnsight)
                HStack {
                    Button("Open in ParaView") { ws.openFoamInParaView() }
                    Button("Show postProcessing Folder") { ws.openFoamFolder("postProcessing") }
                }
            }
            Section("Run") {
                Toggle("Run after every OpenFOAM solve", isOn: post.afterSolve)
                Button("Run Post-Processing Now (latest time)") { ws.runPostProcessingNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ws.isRunning || ws.setup.openfoam.postProcessing.isEmpty)
                Text("Runs <solver> -postProcess -latestTime with these function objects, then the exports, on \((ws.foamLastCase ?? ws.foamCaseDirectory).path). Curlew's Results pages (contours, vectors, pathlines, XY plot, reports) work on the loaded solution as well.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Python scripts

/// Python post-processing scripts with Curlew's `curlew_post` module.
struct PostScriptsSection: View {
    @Bindable var ws: Workspace
    var scripts: Binding<[FoamPostScript]> { $ws.setup.openfoam.postProcessing.scripts }
    @State private var showHelp = false

    var body: some View {
        Section("Python scripts (curlew_post programming interface)") {
            ForEach(Array(ws.setup.openfoam.postProcessing.scripts.enumerated()), id: \.offset) { i, _ in
                let sc = Binding<FoamPostScript>.element(scripts, i, fallback: FoamPostScript())
                DisclosureGroup(sc.wrappedValue.name + (sc.wrappedValue.afterSolve ? "  (after the solve)" : "")) {
                    HStack {
                        TextField("Name", text: sc.name).textFieldStyle(.roundedBorder)
                        Toggle("Run after the solve", isOn: sc.afterSolve)
                    }
                    TextEditor(text: sc.code)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        if ws.postScriptRunning == sc.wrappedValue.name {
                            ProgressView().controlSize(.small)
                            Button("Stop") { ws.postScriptJob?.cancel() }
                        } else {
                            Button("Run Now (latest time)") { ws.runPostScript(sc.wrappedValue) }
                                .buttonStyle(.borderedProminent)
                                .disabled(ws.postScriptRunning != nil || sc.wrappedValue.code.isEmpty)
                        }
                        Button("Show Output Folder") { ws.openFoamFolder("curlew-post/out/\(sc.wrappedValue.outputName)") }
                        Spacer()
                        Button("Remove", role: .destructive) { ws.setup.openfoam.postProcessing.scripts.remove(at: i) }
                    }
                    if let r = ws.postScriptResults[sc.wrappedValue.outputName] { PostScriptResultView(result: r) }
                }
            }
            HStack {
                Menu("Add Script") {
                    Button("Blank script") {
                        ws.setup.openfoam.postProcessing.scripts.append(FoamPostScript(name: "script\(ws.setup.openfoam.postProcessing.scripts.count + 1)",
                                                                                     code: "import numpy as np\nimport curlew_post as cp\n\ncase = cp.load()\nprint(case)\n"))
                    }
                    Divider()
                    ForEach(PostScriptTemplates.all, id: \.script.name) { t in
                        Button(t.title) {
                            var s = t.script
                            if ws.setup.openfoam.postProcessing.scripts.contains(where: { $0.name == s.name }) { s.name += "_\(ws.setup.openfoam.postProcessing.scripts.count + 1)" }
                            ws.setup.openfoam.postProcessing.scripts.append(s)
                        }
                    }
                }
                .fixedSize()
                Button(showHelp ? "Hide API" : "Show API") { showHelp.toggle() }
            }
            if showHelp {
                Text(PostScriptsSection.apiSummary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            Text("Scripts run with \(PINNJob.defaultPython) (Settings › Machine Learning), on a NumPy export of the case's time directory. They are your own code: a case opened from disk shows them for approval before anything runs. Command line: curlew post-script.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static let apiSummary = """
    import curlew_post as cp
    case = cp.load()                   time, times, n_cells, centres, volumes, fields
    case["U"]                          (n_cells, 3) array; scalars (n_cells,)
    case.pressure_pa()                 static gauge pressure in Pa
    case.volume_average(f, mask)       also volume_integral
    case.probe(points, f)              nearest-cell values; case.line(a, b, n, f)
    case.patches["inlet"]              .area .normal .centres .area_vectors .field(f)
      .average(f) .integrate(f) .flux("U") .maximum(f) .minimum(f)
    case.function_object("forceCoeffs")  postProcessing/ columns as arrays
    case.residuals()
    case.write_field("name", values)   new field in the time directory
    cp.report("name", value, "unit")   shown in Curlew
    cp.savefig("name")                 Matplotlib figure shown in Curlew
    """
}

struct PostScriptResultView: View {
    let result: PostScriptResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.succeeded ? String(format: "Time %@ · %.1f s", result.time, result.seconds) : "Failed (exit \(result.exitCode))")
                .font(.caption.bold()).foregroundStyle(result.succeeded ? Color.secondary : Color.red)
            if !result.reports.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(result.reports) { r in
                        GridRow {
                            Text(r.name)
                            Text(String(format: "%.6g", r.value)).monospacedDigit().textSelection(.enabled)
                            Text(r.unit).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
            if !result.fields.isEmpty {
                Text("New fields: " + result.fields.joined(separator: ", ") + " (reload the results to contour them)").font(.caption)
            }
            ForEach(result.figures, id: \.self) { url in
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 280)
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .help("Click to open \(url.lastPathComponent)")
                }
            }
            if !result.log.isEmpty {
                ScrollView {
                    Text(result.log.suffix(200).joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(.vertical, 4)
    }
}
