import SwiftUI
import AppKit
import CurlewMesh
import CurlewSolver
import CurlewPost
import CurlewFoam

// MARK: - Ribbon

/// Big category buttons along the top of the window, each a dropdown of its modules, and the
/// module selector.
struct ModuleRibbon: View {
    @Bindable var ws: Workspace
    var body: some View {
        HStack(spacing: 6) {
            ForEach(ModuleCategory.allCases) { cat in
                Menu {
                    ForEach(cat.modules) { m in
                        Button { ws.selectModule(m) } label: { Label(m.title, systemImage: m.symbol) }
                            .disabled(m.needsGmsh && !GmshDriver.isAvailable)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: cat.symbol).font(.title2)
                        Text(cat.title).font(.caption).lineLimit(1)
                    }
                    .frame(minWidth: 96, minHeight: 44)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(ws.activeModule.category == cat ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help(cat.modules.map(\.title).joined(separator: " · "))
            }
            Spacer()
            Label(ws.activeModule.title, systemImage: ws.activeModule.symbol).font(.caption)
                .onTapGesture { ws.selection = .module }
            Text(ws.setup.general.backend == .openfoam ? "Solver: OpenFOAM" : "Solver: Curlew")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Workspace actions

extension Workspace {
    func selectModule(_ m: AppModule) {
        activeModule = m
        selection = .module
    }

    /// Build the selected module's case (and run it with the current backend).
    func buildModule(run: Bool) {
        let m = activeModule
        guard m.buildsCase, !isRunning, !isMeshing else { return }
        let params = moduleParams, cores = moduleCores, inst = setup.openfoam.installation
        isMeshing = true
        statusText = "Building \(m.title)…"
        log("Module: \(m.title)", .command)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (mesh, built) = try params.build(m)
                DispatchQueue.main.async {
                    self.isMeshing = false
                    self.statusText = "Ready"
                    var s = built
                    s.openfoam.cores = cores
                    s.openfoam.installation = inst
                    self.setMesh(mesh, source: m.title)
                    self.setup = s
                    self.setup.adopt(mesh: mesh)
                    self.display.field = m == .windFarm ? "x-velocity" : (m == .windTurbineRotor ? "velocity-magnitude" : "temperature")
                    self.display.surfaces = []
                    self.namedSurfaces = []
                    self.documentURL = nil
                    self.log("\(m.title): \(mesh.summary); solver \(s.general.backend == .openfoam ? FoamCaseWriter.resolvedApplication(s).rawValue : "Curlew"), \(cores) core(s)")
                    if run { self.calculate() }
                }
            } catch {
                DispatchQueue.main.async { self.isMeshing = false; self.statusText = "Ready"; self.log("\(error)", .error) }
            }
        }
    }

    // PINN

    func pinnPrepare(train: Bool) {
        guard let mesh, !pinnBusy else { if mesh == nil { log("Build or load a case first (a module, a tutorial or a mesh).", .warning) }; return }
        let job = PINNJob(mesh: mesh, setup: setup, settings: moduleParams.pinn)
        let dir = PINNJob.defaultDirectory(for: setup)
        let sol = initialized ? solver : nil
        let python = PINNJob.defaultPython
        pinnBusy = true; pinnJob = job; pinnLoss = []
        pinnStatus = "Preparing…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let sum = try job.prepare(in: dir, solution: sol)
                DispatchQueue.main.async { self.log(sum.text + " → \(dir.path)"); self.pinnStatus = sum.text }
                guard train else { DispatchQueue.main.async { self.pinnBusy = false; self.pinnJob = nil }; return }
                DispatchQueue.main.async { self.pinnStatus = "Training with \(python)…"; self.log("PINN training (\(python))", .command) }
                try job.run(python: python, in: dir, log: { line in DispatchQueue.main.async { self.log(line) } },
                            progress: { e, l in DispatchQueue.main.async { self.pinnLoss.append((e, l)); self.pinnStatus = String(format: "epoch %d, loss %.3e", e, l) } })
                DispatchQueue.main.async { self.pinnBusy = false; self.pinnJob = nil; self.pinnLoadPrediction() }
            } catch {
                DispatchQueue.main.async { self.pinnBusy = false; self.pinnJob = nil; self.pinnStatus = "\(error)"; self.log("\(error)", .error) }
            }
        }
    }

    func pinnStop() { pinnJob?.cancel() }

    func pinnLoadPrediction() {
        guard let mesh else { return }
        let dir = PINNJob.defaultDirectory(for: setup), s = setup
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let solver = try PINNJob.load(from: dir, mesh: mesh, setup: s)
                DispatchQueue.main.async {
                    solver.log = { [weak self] msg in DispatchQueue.main.async { self?.log(msg) } }
                    self.solver = solver
                    self.post = PostProcessor(solver: solver)
                    self.initialized = true
                    if self.display.mode == .mesh { self.display.mode = .contours }
                    self.refreshDisplay()
                    self.pinnStatus = "Prediction loaded from \(dir.path)"
                    self.log("PINN prediction loaded; Results pages now show it.")
                    for rep in self.setup.reports { self.log(String(format: "  %@ = %.6g", rep.name, Reports.evaluate(rep, solver: solver))) }
                }
            } catch {
                DispatchQueue.main.async { self.log("Could not load the PINN prediction: \(error)", .error) }
            }
        }
    }

    // AI assistant

    /// Last value of each named series (values are stored per series or per row; both handled).
    func latestValues(_ names: [String], _ values: [[Double]]) -> [String: Double] {
        var out: [String: Double] = [:]
        if values.count == names.count {
            for (i, n) in names.enumerated() { if let v = values[i].last(where: { $0.isFinite }) { out[n] = v } }
        } else if let row = values.last, row.count == names.count {
            for (i, n) in names.enumerated() { out[n] = row[i] }
        }
        return out
    }

    func askAI(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !aiBusy else { return }
        let settings = AISettings.load()
        aiConversation.append(AIMessage(role: .user, text: q))
        aiBusy = true; aiError = ""
        let convo = aiConversation
        let ctx = settings.includeCaseContext
            ? AIAssistant.caseContext(mesh: mesh, setup: setup, quality: meshQuality,
                                      residuals: latestValues(residuals.names, residuals.values), reports: latestValues(reportHistory.names, reportHistory.values),
                                      recentLog: console.filter { $0.kind == .warning || $0.kind == .error }.map(\.text))
            : nil
        Task {
            do {
                let r = try await AIAssistant.reply(to: convo, context: ctx, settings: settings)
                await MainActor.run { self.aiConversation.append(AIMessage(role: .assistant, text: r)); self.aiBusy = false }
            } catch {
                await MainActor.run { self.aiError = "\(error)"; self.aiBusy = false }
            }
        }
    }
}

// MARK: - Module page

struct ModulePage: View {
    @Bindable var ws: Workspace
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(ws.activeModule.category.title) › \(ws.activeModule.title)", systemImage: ws.activeModule.symbol).font(.headline)
                Text(ws.activeModule.summary).font(.caption).foregroundStyle(.secondary)
                Text("Choose another module from the category buttons along the top.").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            switch ws.activeModule {
            case .windFarm: WindFarmForm(ws: ws)
            case .windTurbineRotor: RotorForm(ws: ws)
            case .airCooledHeatSink: AirCoolingForm(ws: ws)
            case .liquidColdPlate: LiquidCoolingForm(ws: ws)
            case .cadAnalysis: CADAnalysisPage(ws: ws)
            case .pinn: PINNPage(ws: ws)
            case .aiAssistant: AIAssistantPage(ws: ws)
            case .tutorials: TutorialsPage(ws: ws)
            case .preProcessing: PreProcessingPage(ws: ws)
            case .postProcessing: PostProcessingPage(ws: ws)
            case .customCase:
                Form {
                    Section("Build a case yourself") {
                        Button("Mesh Generation") { ws.selection = .meshGeneration }
                        Button("Import a Mesh…") { ws.selection = .meshGeneration }
                        Button("Boundary Conditions") { ws.selection = .boundaries }
                        Button("OpenFOAM Settings") { ws.selection = .openfoam }
                        Button("Run Calculation") { ws.selection = .runCalculation }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

/// Build / Build and Run, with the core count, shared by the case-building modules.
struct ModuleRunSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Run") {
            Picker("Solver", selection: $ws.setup.general.backend) {
                ForEach(SolverBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            IntField(label: "OpenFOAM cores", value: $ws.moduleCores)
            HStack {
                Button(ws.isMeshing ? "Building…" : "Build Case") { ws.buildModule(run: false) }
                Button("Build and Run") { ws.buildModule(run: true) }.buttonStyle(.borderedProminent)
            }
            .disabled(ws.isMeshing || ws.isRunning || (ws.activeModule.needsGmsh && !GmshDriver.isAvailable))
            if ws.foamInstallations.isEmpty {
                Label("No OpenFOAM installation found yet (OpenFOAM page › Installation). Without one, Curlew's own solver is used.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Every setting the module makes can be changed afterwards on the Setup, Solution and OpenFOAM pages before running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func materials(_ kind: CellZoneKind) -> [String] { MaterialLibrary.all.filter { $0.kind == kind }.map(\.name) }

struct TurbulencePicker: View {
    var label = "Turbulence model"
    @Binding var model: ViscousModel
    var body: some View {
        Picker(label, selection: $model) {
            ForEach(ViscousModel.allCases.filter { $0 != .inviscid }, id: \.self) { Text($0.displayName).tag($0) }
        }
    }
}

struct WindFarmForm: View {
    @Bindable var ws: Workspace
    var p: Binding<WindFarmModule> { $ws.moduleParams.windFarm }
    var body: some View {
        let w = ws.moduleParams.windFarm
        let a = 0.5 * (1 - sqrt(max(0, 1 - w.thrustCoefficient)))
        Form {
            Section("Layout") {
                IntField(label: "Rows (across the wind)", value: p.rows)
                IntField(label: "Turbines per row (along the wind)", value: p.columns)
                NumberField(label: "Spacing along the wind", value: p.streamwiseSpacing, unit: "D")
                NumberField(label: "Spacing across the wind", value: p.lateralSpacing, unit: "D")
                LabeledContent("Turbines", value: "\(w.turbineCount)")
            }
            Section("Turbine") {
                NumberField(label: "Rotor diameter D", value: p.diameter, unit: "m")
                NumberField(label: "Hub height", value: p.hubHeight, unit: "m")
                NumberField(label: "Thrust coefficient Ct", value: p.thrustCoefficient)
                NumberField(label: "Power coefficient Cp", value: p.powerCoefficient)
                LabeledContent("Ideal wind speed at the first rotor", value: String(format: "%.2f m/s (induction a = %.3f)", w.windSpeed * (1 - a), a))
            }
            Section("Wind (neutral atmospheric boundary layer)") {
                NumberField(label: "Wind speed at hub height", value: p.windSpeed, unit: "m/s")
                NumberField(label: "Terrain roughness z₀", value: p.roughnessLength, unit: "m")
                Text("Open sea ≈ 0.0002 m, grassland 0.03, crops 0.1, forest or suburbs 0.5–1 m.").font(.caption).foregroundStyle(.secondary)
                TurbulencePicker(model: p.turbulence)
            }
            Section("Domain and mesh") {
                NumberField(label: "Upstream", value: p.upstream, unit: "D")
                NumberField(label: "Downstream of the last turbine", value: p.downstream, unit: "D")
                NumberField(label: "Beside the outer rows", value: p.lateralMargin, unit: "D")
                NumberField(label: "Height", value: p.height, unit: "D")
                NumberField(label: "Cells per rotor diameter", value: p.cellsPerDiameter)
                IntField(label: "Iterations", value: p.iterations)
            }
            ModuleRunSection(ws: ws)
        }
        .formStyle(.grouped)
    }
}

struct RotorForm: View {
    @Bindable var ws: Workspace
    var p: Binding<WindTurbineRotorModule> { $ws.moduleParams.rotor }
    var body: some View {
        let r = ws.moduleParams.rotor
        Form {
            Section("Rotor") {
                NumberField(label: "Radius R", value: p.radius, unit: "m")
                IntField(label: "Blades", value: p.blades)
                TextField("NACA 4-digit aerofoil", text: p.airfoil)
                NumberField(label: "Design angle of attack", value: p.angleOfAttack, unit: "°")
                NumberField(label: "Hub radius", value: p.hubRadius, unit: "R")
                Text("Blades are lofted through six sections with chord ∝ 1/r (capped at 0.12 R) and the twist that gives the design angle of attack at the design tip-speed ratio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Operating point") {
                NumberField(label: "Wind speed", value: p.windSpeed, unit: "m/s")
                NumberField(label: "Tip-speed ratio λ", value: p.tipSpeedRatio)
                LabeledContent("Rotor speed", value: String(format: "%.4g rad/s (%.4g rpm), tip %.4g m/s", r.omega, r.omega * 60 / (2 * .pi), r.omega * r.radius))
                TurbulencePicker(model: p.turbulence)
            }
            Section("Domain and mesh (Gmsh)") {
                NumberField(label: "Upstream", value: p.upstream, unit: "R")
                NumberField(label: "Downstream", value: p.downstream, unit: "R")
                NumberField(label: "Beside the rotor", value: p.lateral, unit: "R")
                NumberField(label: "Cell size at the blades", value: p.bladeCellSize, unit: "R")
                NumberField(label: "Cell size far away", value: p.farCellSize, unit: "R")
                IntField(label: "Iterations", value: p.iterations)
            }
            ModuleRunSection(ws: ws)
        }
        .formStyle(.grouped)
    }
}

struct AirCoolingForm: View {
    @Bindable var ws: Workspace
    var p: Binding<AirCooledHeatSinkModule> { $ws.moduleParams.airCooling }
    var body: some View {
        let a = ws.moduleParams.airCooling
        Form {
            Section("Chip and board") {
                NumberField(label: "Chip power", value: p.power, unit: "W")
                NumberField(label: "Chip size", value: p.chipSize, unit: "m")
                NumberField(label: "Chip height", value: p.chipHeight, unit: "m")
                NumberField(label: "Board length (along the flow)", value: p.boardLength, unit: "m")
                NumberField(label: "Board width", value: p.boardWidth, unit: "m")
                NumberField(label: "Board thickness", value: p.boardThickness, unit: "m")
                Picker("Board material", selection: p.boardMaterial) { ForEach(materials(.solid), id: \.self) { Text($0).tag($0) } }
            }
            Section("Heat sink") {
                NumberField(label: "Footprint (square)", value: p.heatSinkSize, unit: "m")
                NumberField(label: "Base thickness", value: p.baseThickness, unit: "m")
                IntField(label: "Fins", value: p.finCount)
                NumberField(label: "Fin thickness", value: p.finThickness, unit: "m")
                NumberField(label: "Fin height", value: p.finHeight, unit: "m")
                Picker("Material", selection: p.heatSinkMaterial) { ForEach(materials(.solid), id: \.self) { Text($0).tag($0) } }
            }
            Section("Air") {
                NumberField(label: "Duct height above the board", value: p.ductHeight, unit: "m")
                NumberField(label: "Inlet velocity", value: p.inletVelocity, unit: "m/s")
                NumberField(label: "Inlet temperature", value: p.inletTemperature, unit: "K")
                TurbulencePicker(model: p.turbulence)
                LabeledContent("Air temperature rise (energy balance)", value: String(format: "%.2f K", a.power / max(1e-12, 1.225 * 1006.43 * a.inletVelocity * a.boardWidth * a.ductHeight)))
            }
            Section("Mesh") {
                NumberField(label: "Cell size", value: p.cellSize, unit: "m")
                IntField(label: "Iterations", value: p.iterations)
            }
            ModuleRunSection(ws: ws)
        }
        .formStyle(.grouped)
    }
}

struct LiquidCoolingForm: View {
    @Bindable var ws: Workspace
    var p: Binding<LiquidColdPlateModule> { $ws.moduleParams.liquidCooling }
    var body: some View {
        let l = ws.moduleParams.liquidCooling
        let cool = MaterialLibrary.lookup(l.coolant)
        let mdot = (cool?.density ?? 998) * l.flowRateLitresPerMinute / 60_000
        Form {
            Section("Chip and board") {
                NumberField(label: "Chip power", value: p.power, unit: "W")
                NumberField(label: "Chip size", value: p.chipSize, unit: "m")
                NumberField(label: "Board thickness", value: p.boardThickness, unit: "m")
                Picker("Board material", selection: p.boardMaterial) { ForEach(materials(.solid), id: \.self) { Text($0).tag($0) } }
            }
            Section("Cold plate") {
                NumberField(label: "Length (along the flow)", value: p.plateLength, unit: "m")
                NumberField(label: "Width", value: p.plateWidth, unit: "m")
                IntField(label: "Channels", value: p.channelCount)
                NumberField(label: "Channel width", value: p.channelWidth, unit: "m")
                NumberField(label: "Channel height", value: p.channelHeight, unit: "m")
                NumberField(label: "Floor thickness", value: p.floorThickness, unit: "m")
                NumberField(label: "Lid thickness", value: p.lidThickness, unit: "m")
                NumberField(label: "Manifold length", value: p.manifoldLength, unit: "m")
                Picker("Material", selection: p.plateMaterial) { ForEach(materials(.solid), id: \.self) { Text($0).tag($0) } }
            }
            Section("Coolant") {
                Picker("Coolant", selection: p.coolant) { ForEach(materials(.fluid), id: \.self) { Text($0).tag($0) } }
                NumberField(label: "Inlet velocity", value: p.inletVelocity, unit: "m/s")
                NumberField(label: "Inlet temperature", value: p.inletTemperature, unit: "K")
                LabeledContent("Flow rate", value: String(format: "%.3g L/min", l.flowRateLitresPerMinute))
                LabeledContent("Coolant temperature rise (energy balance)", value: String(format: "%.2f K", l.power / max(1e-12, mdot * (cool?.specificHeat ?? 4182))))
            }
            Section("Mesh") {
                NumberField(label: "Cell size", value: p.cellSize, unit: "m")
                IntField(label: "Iterations", value: p.iterations)
            }
            ModuleRunSection(ws: ws)
        }
        .formStyle(.grouped)
    }
}

// MARK: - PINN

struct PINNPage: View {
    @Bindable var ws: Workspace
    var p: Binding<PINNSettings> { $ws.moduleParams.pinn }
    var body: some View {
        Form {
            Section("Problem") {
                Picker("Mode", selection: p.mode) { ForEach(PINNSettings.Mode.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                Toggle("Energy equation (when the case has one)", isOn: p.energy)
                Text("The network learns u, p (and T) of the open case: steady incompressible Navier–Stokes with the case's boundary conditions, in non-dimensional form (Re from the inlet speed and domain size). Hybrid and surrogate modes also fit samples of the current solution, e.g. an OpenFOAM run. Fluid regions only.")
                    .font(.caption).foregroundStyle(.secondary)
                if ws.mesh == nil { Label("Build or load a case first.", systemImage: "info.circle").font(.caption) }
            }
            Section("Network") {
                IntField(label: "Hidden layers", value: p.hiddenLayers)
                IntField(label: "Neurons per layer", value: p.neurons)
                Picker("Activation", selection: p.activation) { ForEach(PINNSettings.Activation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                IntField(label: "Fourier features (0 = off)", value: p.fourierFeatures)
                NumberField(label: "Fourier scale", value: p.fourierScale)
            }
            Section("Training") {
                IntField(label: "Adam epochs", value: p.adamEpochs)
                NumberField(label: "Learning rate", value: p.learningRate)
                NumberField(label: "Decay per 1000 epochs", value: p.learningRateDecay)
                IntField(label: "L-BFGS iterations", value: p.lbfgsIterations)
                IntField(label: "Interior points per step", value: p.interiorBatch)
                IntField(label: "Boundary points per step", value: p.boundaryBatch)
                IntField(label: "Data points (hybrid/surrogate)", value: p.dataPoints)
                NumberField(label: "Weight: equations", value: p.weightPDE)
                NumberField(label: "Weight: boundary conditions", value: p.weightBC)
                NumberField(label: "Weight: data", value: p.weightData)
                Picker("Device", selection: p.device) { ForEach(PINNSettings.Device.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                IntField(label: "Random seed", value: p.seed)
                IntField(label: "Log every n epochs", value: p.logEvery)
            }
            Section("Python and PyTorch") {
                PyTorchEnvironmentPanel()
            }
            Section("Run") {
                HStack {
                    Button("Write Problem Files") { ws.pinnPrepare(train: false) }
                    Button("Train") { ws.pinnPrepare(train: true) }.buttonStyle(.borderedProminent)
                    Button("Stop") { ws.pinnStop() }.disabled(!ws.pinnBusy)
                    Button("Load Prediction") { ws.pinnLoadPrediction() }
                }
                .disabled(ws.mesh == nil)
                if !ws.pinnStatus.isEmpty { Text(ws.pinnStatus).font(.caption).textSelection(.enabled) }
                if let last = ws.pinnLoss.last { LabeledContent("Loss", value: String(format: "%.3e at epoch %d", last.loss, last.epoch)) }
                Text("Files: \(PINNJob.defaultDirectory(for: ws.setup).path) (config.json, points.csv, boundary.csv, data.csv, train.py, prediction.csv, model.pt).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI assistant

struct AIAssistantPage: View {
    @Bindable var ws: Workspace
    @State private var draft = ""
    @State private var settings = AISettings.load()
    let quick = ["Review my case setup", "Why is my run not converging?", "Explain the last error", "How should I refine the mesh?", "Which OpenFOAM settings would you change?"]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(settings.provider.displayName) · \(settings.model.isEmpty ? "no model" : settings.model)", systemImage: "sparkles").font(.caption)
                Spacer()
                Toggle("Send case summary", isOn: Binding(get: { settings.includeCaseContext }, set: { settings.includeCaseContext = $0; settings.save() }))
                    .toggleStyle(.checkbox).font(.caption)
                SettingsLink { Text("AI Settings…").font(.caption) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if ws.aiConversation.isEmpty {
                            Text("Ask about the open case. With “Send case summary” on, each question includes the setup, mesh statistics, latest residuals, reports and recent warnings — nothing else from your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(quick, id: \.self) { q in Button(q) { ws.askAI(q) }.buttonStyle(.link).disabled(ws.aiBusy) }
                        }
                        ForEach(ws.aiConversation) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.role == .user ? "You" : "Assistant").font(.caption.weight(.semibold)).foregroundStyle(m.role == .user ? Color.accentColor : .secondary)
                                Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                                    .textSelection(.enabled)
                            }
                            .id(m.id)
                        }
                        if ws.aiBusy { ProgressView().controlSize(.small) }
                        if !ws.aiError.isEmpty { Label(ws.aiError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
                    }
                    .padding(12)
                }
                .onChange(of: ws.aiConversation.count) { _, _ in if let l = ws.aiConversation.last { proxy.scrollTo(l.id, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask about this case…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Send") { send() }.keyboardShortcut(.return, modifiers: .command).disabled(ws.aiBusy || draft.isEmpty)
                Button { ws.aiConversation = []; ws.aiError = "" } label: { Image(systemName: "trash") }.help("Clear the conversation")
            }
            .padding(10)
        }
        .onAppear { settings = AISettings.load() }
    }
    func send() { let t = draft; draft = ""; ws.askAI(t) }
}

// MARK: - Settings

struct AISettingsView: View {
    @State private var s = AISettings.load()
    @State private var key = ""
    @State private var status = ""
    var body: some View {
        Form {
            Picker("Provider", selection: $s.provider) { ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) } }
                .onChange(of: s.provider) { _, p in s.model = p.defaultModel; s.baseURL = ""; key = "" }
            HStack {
                TextField("Model", text: $s.model).textFieldStyle(.roundedBorder)
                if !s.provider.suggestedModels.isEmpty {
                    Menu("Models") { ForEach(s.provider.suggestedModels, id: \.self) { m in Button(m) { s.model = m } } }.fixedSize()
                }
            }
            TextField("Endpoint", text: $s.baseURL, prompt: Text(s.provider.defaultBaseURL)).textFieldStyle(.roundedBorder)
            if s.provider.needsKey {
                HStack {
                    SecureField(AIKeychain.hasStoredKey(s.provider) ? "API key (stored in Keychain)" : "API key", text: $key).textFieldStyle(.roundedBorder)
                    Button("Save Key") { status = AIKeychain.setKey(key, for: s.provider) ? (key.isEmpty ? "Key removed." : "Key saved in your Keychain.") : "Could not save the key."; key = "" }
                }
                if let v = s.provider.keyEnvironmentVariable { Text("Without a stored key, \(v) from the environment is used.").font(.caption).foregroundStyle(.secondary) }
            }
            if s.provider == .anthropic {
                Picker("Effort", selection: $s.effort) { ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) } }
                Toggle("Retry declined requests on Anthropic's recommended model (server-side fallback)", isOn: $s.serverFallback)
            }
            IntField(label: "Max tokens per reply", value: $s.maxTokens)
            Toggle("Send a summary of the open case with each question", isOn: $s.includeCaseContext)
            HStack {
                Button("Save") { s.save(); status = "Saved." }
                Button("Test Connection") {
                    s.save(); status = "Testing…"
                    let cfg = s
                    Task {
                        do {
                            let r = try await AIAssistant.reply(to: [AIMessage(role: .user, text: "Reply with the single word OK.")], context: nil, settings: cfg)
                            await MainActor.run { status = "✓ \(r.prefix(60))" }
                        } catch { await MainActor.run { status = "✗ \(error)" } }
                    }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            Text("Questions go to the provider's API only when you send them. Keys are kept in the macOS Keychain and never written to case files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onDisappear { s.save() }
    }
}

struct MachineLearningSettingsView: View {
    var body: some View {
        Form { PyTorchEnvironmentPanel() }
            .formStyle(.grouped)
            .padding()
    }
}

/// The Python interpreter used for training, its PyTorch status, and Install / Repair.
struct PyTorchEnvironmentPanel: View {
    @AppStorage("curlew.python") private var python = ""
    @State private var status: PINNJob.EnvironmentStatus?
    @State private var busy = false
    @State private var progress: [String] = []
    @State private var error = ""

    var interpreter: String { python.isEmpty ? PINNJob.defaultPython : python }

    var body: some View {
        Group {
            TextField("Python interpreter", text: $python, prompt: Text(PINNJob.defaultPython)).textFieldStyle(.roundedBorder)
            HStack(alignment: .firstTextBaseline) {
                if busy { ProgressView().controlSize(.small) }
                else if let st = status { Image(systemName: st.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(st.ok ? .green : .red) }
                Text(status?.text ?? "Not checked yet.").font(.caption).textSelection(.enabled)
            }
            HStack {
                Button("Check") { check() }.disabled(busy)
                Button(status?.ok == true ? "Reinstall / Update PyTorch…" : "Install PyTorch…") { install() }.disabled(busy)
                if !python.isEmpty && python != PINNJob.environmentDirectory.appendingPathComponent("bin/python").path {
                    Button("Use Curlew's Environment") { python = ""; check() }.disabled(busy)
                }
            }
            if !progress.isEmpty {
                ScrollView {
                    Text(progress.suffix(14).joined(separator: "\n")).font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 110).border(.quaternary)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Training runs train.py with this interpreter, directly and without a shell. Install creates (or repairs) \(PINNJob.environmentDirectory.path) and installs PyTorch and NumPy into it. The interpreter is a Curlew preference, never stored in case files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if status == nil { check() } }
    }

    func check() {
        let py = interpreter
        busy = true; error = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let st = PINNJob.checkEnvironment(python: py)
            DispatchQueue.main.async { status = st; busy = false }
        }
    }

    func install() {
        let a = NSAlert()
        a.messageText = "Install PyTorch for Curlew?"
        a.informativeText = "Curlew creates (or repairs) a Python environment in \(PINNJob.environmentDirectory.path) and installs PyTorch and NumPy from the Python Package Index. The first install downloads several hundred MB."
        a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Install")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        busy = true; error = ""; progress = []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let py = try PINNJob.createEnvironment(log: { l in DispatchQueue.main.async { progress.append(l) } })
                let st = PINNJob.checkEnvironment(python: py)
                DispatchQueue.main.async { python = ""; status = st; busy = false }
            } catch let e {
                DispatchQueue.main.async { error = "\(e)"; busy = false; status = PINNJob.checkEnvironment(python: interpreter) }
            }
        }
    }
}

/// The textbook cases and the validation suite.
struct TutorialsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Tutorials") {
                ForEach(TutorialCatalog.core) { t in
                    Button {
                        ws.loadTutorial(t)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title).fontWeight(.medium)
                                if t.needsGmsh { Text("Gmsh").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                            }
                            Text(t.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(ws.isRunning || ws.isMeshing || (t.needsGmsh && !GmshDriver.isAvailable))
                }
            }
            Section("Validation") {
                Button("Open the Validation Suite") { ws.selection = .validation }
                Text("Wind-farm, rotor and electronics-cooling cases are modules (category buttons at the top).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
