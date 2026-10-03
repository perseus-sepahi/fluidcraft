import SwiftUI
import Charts
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver

struct ContentView: View {
    @Bindable var ws: Workspace
    @StateObject private var viewController = ViewController()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            OutlineSidebar(ws: ws)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            TaskPanel(ws: ws)
                .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 560)
        } detail: {
            VSplitView {
                GraphicsArea(ws: ws, controller: viewController)
                    .frame(minHeight: 420, idealHeight: 700, maxHeight: .infinity)
                ConsoleView(ws: ws)
                    .frame(minHeight: 90, idealHeight: 170, maxHeight: 420)
            }
        }
        .toolbar { toolbar }
        .navigationTitle(ws.setup.title == "Untitled" ? "Curlew" : ws.setup.title)
        .navigationSubtitle(ws.mesh.map { "\($0.nCells) cells · \(ws.statusText)" } ?? ws.statusText)
        .onChange(of: ws.setup) { _, _ in ws.isDirty = true }
        .environmentObject(viewController)
        .onAppear { ws.viewController = viewController }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(TutorialCatalog.all) { t in
                    Button(t.title) { ws.loadTutorial(t) }.disabled(t.needsGmsh && !GmshDriver.isAvailable)
                }
            } label: { Label("Tutorials", systemImage: "book") }
            .help("Load a ready-to-run case")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ws.selection = .meshGeneration } label: { Label("Mesh", systemImage: "square.grid.3x3.square") }.help("Mesh generation")
            Button { ws.selection = .meshInfo } label: { Label("Check", systemImage: "checkmark.seal") }.help("Mesh check and quality").disabled(ws.mesh == nil)
            Button { ws.initialize() } label: { Label("Initialize", systemImage: "sparkles") }.disabled(ws.mesh == nil || ws.isRunning)
            if ws.isRunning {
                Button { ws.stop() } label: { Label("Stop", systemImage: "stop.fill") }.tint(.red)
            } else {
                Button { ws.calculate() } label: { Label("Calculate", systemImage: "play.fill") }.disabled(ws.mesh == nil)
                    .keyboardShortcut("r", modifiers: .command)
            }
            Picker("Display", selection: Binding(get: { ws.display.mode }, set: { m in
                ws.display.mode = m; ws.graphicsTab = .viewport; ws.refreshDisplay()
            })) {
                ForEach(DisplaySettings.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(ws.mesh == nil)
            .help("Graphics display mode")
        }
    }
}

struct OutlineSidebar: View {
    @Bindable var ws: Workspace
    var body: some View {
        List(selection: $ws.selection) {
            Section("Meshing") { rows([.meshGeneration, .meshInfo]) }
            Section("Setup") { rows([.general, .models, .materials, .cellZones, .boundaries, .expressions, .referenceValues]) }
            Section("Solution") { rows([.methods, .controls, .reportDefinitions, .monitors, .initialization, .runCalculation]) }
            Section("Results") { rows([.surfaces, .graphicsMesh, .contours, .vectors, .pathlines, .xyPlot, .reports]) }
            Section("Verification") { rows([.validation]) }
        }
        .listStyle(.sidebar)
    }
    func rows(_ items: [OutlineItem]) -> some View {
        ForEach(items) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
        }
    }
}

struct TaskPanel: View {
    @Bindable var ws: Workspace
    var body: some View {
        VStack(spacing: 0) {
            if let sel = ws.selection {
                PageHeader(title: sel.title, symbol: sel.symbol)
                Divider()
                page(sel)
            } else {
                ContentUnavailableView("Select a Task", systemImage: "sidebar.left")
            }
        }
    }
    @ViewBuilder func page(_ s: OutlineItem) -> some View {
        switch s {
        case .meshGeneration: MeshGenerationPage(ws: ws)
        case .meshInfo: MeshInfoPage(ws: ws)
        case .general: GeneralPage(ws: ws)
        case .models: ModelsPage(ws: ws)
        case .materials: MaterialsPage(ws: ws)
        case .cellZones: CellZonesPage(ws: ws)
        case .boundaries: BoundariesPage(ws: ws)
        case .expressions: ExpressionsPage(ws: ws)
        case .referenceValues: ReferenceValuesPage(ws: ws)
        case .methods: MethodsPage(ws: ws)
        case .controls: ControlsPage(ws: ws)
        case .reportDefinitions: ReportDefinitionsPage(ws: ws)
        case .monitors: MonitorsPage(ws: ws)
        case .initialization: InitializationPage(ws: ws)
        case .runCalculation: RunCalculationPage(ws: ws)
        case .surfaces: SurfacesPage(ws: ws)
        case .graphicsMesh: MeshDisplayPage(ws: ws)
        case .contours: ContoursPage(ws: ws)
        case .vectors: VectorsPage(ws: ws)
        case .pathlines: PathlinesPage(ws: ws)
        case .xyPlot: XYPlotPage(ws: ws)
        case .reports: ReportsPage(ws: ws)
        case .validation: ValidationPage(ws: ws)
        }
    }
}

// MARK: Graphics area

struct GraphicsArea: View {
    @Bindable var ws: Workspace
    @ObservedObject var controller: ViewController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $ws.graphicsTab) {
                    ForEach(GraphicsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Spacer()
                if ws.graphicsTab == .viewport {
                    Menu {
                        ForEach(ViewPreset.allCases) { p in Button(p.rawValue) { controller.apply(p) } }
                        Divider()
                        Button("Toggle Perspective") { controller.toggleProjection() }
                    } label: { Image(systemName: "camera.viewfinder") }
                    .menuStyle(.borderlessButton).frame(width: 40).help("Views")
                    Button { controller.apply(.fit) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless).help("Fit to window")
                    Button { savePicture() } label: { Image(systemName: "photo") }.buttonStyle(.borderless).help("Save picture (PNG)")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ZStack {
                MetalView(scene: ws.scene, resetToken: ws.cameraResetToken, dark: scheme == .dark, controller: controller)
                    .opacity(ws.graphicsTab == .viewport ? 1 : 0)
                if ws.graphicsTab == .viewport {
                    if ws.mesh == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "wind").font(.system(size: 44)).foregroundStyle(.secondary)
                            Text("Curlew").font(.largeTitle.weight(.semibold))
                            Text("Load a tutorial from the toolbar, generate a mesh, or import one.").foregroundStyle(.secondary)
                        }
                    } else {
                        GraphicsOverlay(scene: ws.scene)
                    }
                } else if ws.graphicsTab == .residuals {
                    ResidualChart(history: ws.residuals).padding()
                        .background(Color(nsColor: .textBackgroundColor))
                } else if ws.graphicsTab == .reports {
                    ReportCharts(history: ws.reportHistory, transient: ws.setup.general.time == .transient).padding()
                        .background(Color(nsColor: .textBackgroundColor))
                } else {
                    XYChart(data: ws.xyPlot).padding()
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    func savePicture() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "\(ws.scene.title.isEmpty ? "curlew" : ws.scene.title).png"
        if p.runModal() == .OK, let u = p.url {
            do { try controller.snapshot(to: u); ws.log("Saved picture \(u.path)") } catch { ws.log("\(error)", .error) }
        }
    }
}

/// Colour legend and title over the 3D view (Fluent places the legend on the left).
struct GraphicsOverlay: View {
    var scene: SceneContent
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if let f = scene.colorField {
                    Legend(field: f, range: scene.range, colormap: scene.colormap, bands: scene.bands)
                        .padding(10)
                }
                Spacer()
            }
            Spacer()
            HStack {
                Spacer()
                Text(scene.title).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .allowsHitTesting(false)
    }
}

extension Legend {
    /// Draw the colour legend and title onto an exported picture (CoreGraphics).
    static func composite(_ img: CGImage, scene: SceneContent, dark: Bool) -> CGImage? {
        guard let field = scene.colorField else { return img }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = CGFloat(h) / 900
        let barW = 22 * max(scale, 0.6), barH = CGFloat(h) * 0.45
        let x0 = 24 * max(scale, 0.6), y0 = CGFloat(h) - barH - 40 * max(scale, 0.6)
        let n = 64
        for i in 0..<n {
            var t = (Double(i) + 0.5) / Double(n)
            if scene.bands > 0 { t = (floor(t * Double(scene.bands)) + 0.5) / Double(scene.bands) }
            let c = NSColor(scene.colormap.color(at: t)).usingColorSpace(.deviceRGB) ?? .gray
            ctx.setFillColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
            ctx.fill(CGRect(x: x0, y: y0 + barH * CGFloat(i) / CGFloat(n), width: barW, height: barH / CGFloat(n) + 0.5))
        }
        ctx.setStrokeColor(gray: 0.3, alpha: 1)
        ctx.stroke(CGRect(x: x0, y: y0, width: barW, height: barH))
        let fontSize = max(11 * max(scale, 0.6), 9)
        let textColor: NSColor = dark ? .white : .black
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: textColor]
        for i in 0...10 {
            let v = Double(scene.range.lowerBound) + Double(scene.range.upperBound - scene.range.lowerBound) * Double(i) / 10
            let str = NSAttributedString(string: String(format: "%.3e", v), attributes: attrs)
            str.draw(at: CGPoint(x: x0 + barW + 6, y: y0 + barH * CGFloat(i) / 10 - fontSize * 0.5))
        }
        let tattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize * 1.15, weight: .semibold), .foregroundColor: textColor]
        NSAttributedString(string: field, attributes: tattrs).draw(at: CGPoint(x: x0, y: y0 - fontSize * 2))
        if !scene.title.isEmpty {
            let title = NSAttributedString(string: scene.title, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: textColor.withAlphaComponent(0.7)])
            title.draw(at: CGPoint(x: CGFloat(w) - title.size().width - 16, y: 12))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

struct Legend: View {
    var field: String
    var range: ClosedRange<Float>
    var colormap: Colormap
    var bands: Int
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(LinearGradient(gradient: bands > 0 ? banded : colormap.gradient, startPoint: .bottom, endPoint: .top))
                .frame(width: 18, height: 220)
                .overlay(Rectangle().stroke(.secondary.opacity(0.5), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 0) {
                ForEach((0...10).reversed(), id: \.self) { i in
                    let v = Double(range.lowerBound) + Double(range.upperBound - range.lowerBound) * Double(i) / 10
                    Text(String(format: "%.3e", v)).font(.system(size: 9.5, design: .monospaced))
                    if i > 0 { Spacer(minLength: 0) }
                }
            }
            .frame(height: 226)
            .offset(y: -3)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            Text(field).font(.caption.weight(.medium)).offset(y: 22)
        }
        .padding(.bottom, 22)
    }
    var banded: SwiftUI.Gradient {
        var stops: [SwiftUI.Gradient.Stop] = []
        for k in 0..<bands {
            let c = colormap.color(at: (Double(k) + 0.5) / Double(bands))
            stops.append(.init(color: c, location: Double(k) / Double(bands)))
            stops.append(.init(color: c, location: Double(k + 1) / Double(bands)))
        }
        return SwiftUI.Gradient(stops: stops)
    }
}

// MARK: Charts

struct ResidualChart: View {
    var history: ResidualHistory
    var body: some View {
        if history.iterations.isEmpty {
            ContentUnavailableView("No Residuals Yet", systemImage: "waveform.path.ecg", description: Text("Run the calculation to plot scaled residuals."))
        } else {
            let stride = max(1, history.iterations.count / 1500)
            Chart {
                ForEach(history.names, id: \.self) { name in
                    let s = history.series(name).enumerated().filter { $0.offset % stride == 0 }.map(\.element)
                    ForEach(Array(s.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Iteration", p.0), y: .value("Residual", max(p.1, 1e-16)))
                            .foregroundStyle(by: .value("Equation", name))
                            .interpolationMethod(.linear)
                    }
                }
            }
            .chartYScale(type: .log)
            .chartXAxisLabel("Iterations")
            .chartYAxisLabel("Scaled Residuals")
            .chartLegend(position: .top, alignment: .leading)
        }
    }
}

struct ReportCharts: View {
    var history: ReportHistory
    var transient: Bool
    var body: some View {
        if history.names.isEmpty {
            ContentUnavailableView("No Report Definitions Plotted", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Add report definitions (drag/lift coefficients, mass flow, averages) under Solution."))
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(history.names, id: \.self) { name in
                        let s = history.series(name)
                        VStack(alignment: .leading) {
                            HStack {
                                Text(name).font(.headline)
                                Spacer()
                                if let last = s.last { Text(String(format: "%.6g", last.1)).font(.system(.body, design: .monospaced)) }
                            }
                            let stride = max(1, s.count / 1500)
                            Chart(Array(s.enumerated().filter { $0.offset % stride == 0 }.map(\.element).enumerated()), id: \.offset) { _, p in
                                LineMark(x: .value(transient ? "Flow time" : "Iteration", p.0), y: .value(name, p.1))
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .chartXAxisLabel(transient ? "Flow Time (s)" : "Iterations")
                            .frame(height: 180)
                        }
                    }
                }
            }
        }
    }
}

struct XYChart: View {
    var data: XYPlotData?
    var body: some View {
        if let d = data {
            VStack(alignment: .leading) {
                Text(d.title).font(.headline)
                Chart {
                    ForEach(d.series) { s in
                        ForEach(s.points) { p in
                            LineMark(x: .value(d.xLabel, p.x), y: .value(d.yLabel, p.y)).foregroundStyle(by: .value("Series", s.name))
                            PointMark(x: .value(d.xLabel, p.x), y: .value(d.yLabel, p.y)).symbolSize(8).foregroundStyle(by: .value("Series", s.name))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel(d.xLabel)
                .chartYAxisLabel(d.yLabel)
            }
        } else {
            ContentUnavailableView("No XY Plot", systemImage: "chart.xyaxis.line", description: Text("Create one under Results › XY Plot."))
        }
    }
}

// MARK: Console

struct ConsoleView: View {
    @Bindable var ws: Workspace
    @State private var command = ""
    @State private var history: [String] = []
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(ws.console) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .onChange(of: ws.console.count) { _, _ in
                    if let last = ws.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(">").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                TextField("Command (type help)", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        let c = command
                        command = ""
                        history.append(c)
                        ws.execute(c)
                    }
                if ws.isRunning { ProgressView().controlSize(.mini) }
                Text(ws.statusText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .info: return .primary
        case .command: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: Validation

struct ValidationPage: View {
    @Bindable var ws: Workspace
    @State private var running: ValidationSuite.Case?
    var body: some View {
        Form {
            Section {
                Text("Each benchmark rebuilds its own mesh and case, runs Curlew's solver, and compares with published reference data.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ValidationSuite.Case.allCases, id: \.self) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.rawValue)
                            Text(c.estimate).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if running == c { ProgressView().controlSize(.small) }
                        Button("Run") { run(c) }.disabled(running != nil || ws.isRunning || (c.needsGmsh && !GmshDriver.isAvailable))
                    }
                }
            }
            if !ws.validationResults.isEmpty {
                Section("Results") {
                    ForEach(ws.validationResults) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.passed ? .green : .red)
                                Text(r.quantity).font(.callout)
                            }
                            Text("\(r.name)").font(.caption2).foregroundStyle(.secondary)
                            Text("reference \(r.reference)   ·   Curlew \(r.computed)").font(.system(.caption, design: .monospaced))
                        }
                    }
                    Button("Clear") { ws.validationResults = [] }
                }
            }
        }
        .formStyle(.grouped)
    }
    func run(_ c: ValidationSuite.Case) {
        running = c
        ws.log("Validation: \(c.rawValue)", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rows = try ValidationSuite.run(c) { line in DispatchQueue.main.async { ws.log(line) } }
                DispatchQueue.main.async {
                    for r in rows {
                        ws.validationResults.append(ValidationRow(name: r.benchmark, quantity: r.quantity, reference: r.reference, computed: r.computed, passed: r.passed))
                        ws.log("  \(r.passed ? "PASS" : "FAIL")  \(r.quantity): reference \(r.reference), Curlew \(r.computed)", r.passed ? .info : .warning)
                    }
                    running = nil
                }
            } catch {
                DispatchQueue.main.async { ws.log("\(error)", .error); running = nil }
            }
        }
    }
}
