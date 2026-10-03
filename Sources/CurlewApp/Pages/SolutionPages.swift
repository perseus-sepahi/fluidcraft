import SwiftUI
import CurlewMesh
import CurlewLinear
import CurlewSolver

struct MethodsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Pressure-Velocity Coupling") {
                Picker("Scheme", selection: $ws.setup.methods.coupling) {
                    ForEach(PVCoupling.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if ws.setup.methods.coupling == .piso {
                    Stepper("Neighbour corrections: \(ws.setup.methods.pisoCorrectors)", value: $ws.setup.methods.pisoCorrectors, in: 1...4)
                }
            }
            Section("Spatial Discretization") {
                Picker("Gradient", selection: $ws.setup.methods.gradient) {
                    Text("Least Squares Cell Based").tag(GradientScheme.leastSquares)
                    Text("Green-Gauss Cell Based").tag(GradientScheme.greenGauss)
                }
                Picker("Pressure", selection: $ws.setup.methods.pressure) {
                    Text("Standard").tag(PressureInterpolation.standard)
                    Text("Second Order").tag(PressureInterpolation.secondOrder)
                    Text("Body Force Weighted").tag(PressureInterpolation.bodyForceWeighted)
                }
                schemePicker("Momentum", $ws.setup.methods.momentum)
                if ws.setup.models.viscous.isTurbulent { schemePicker(ws.setup.models.viscous == .spalartAllmaras ? "Modified Turbulent Viscosity" : "Turbulence", $ws.setup.methods.turbulence) }
                if ws.setup.models.energy { schemePicker("Energy", $ws.setup.methods.energy) }
                if !ws.setup.models.passiveScalars.isEmpty { schemePicker("User Scalars", $ws.setup.methods.scalars) }
                Toggle("Bounded (TVD) higher-order momentum & energy", isOn: $ws.setup.methods.limitMomentum)
                if ws.setup.models.viscous.isTurbulent {
                    Toggle("Transpose turbulent stress term", isOn: $ws.setup.methods.transposeStress)
                }
            }
            if ws.setup.general.time == .transient {
                Section("Transient Formulation") {
                    Picker("Formulation", selection: $ws.setup.methods.transient) {
                        Text("First Order Implicit").tag(TransientFormulation.firstOrderImplicit)
                        Text("Bounded Second Order Implicit").tag(TransientFormulation.secondOrderImplicit)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    func schemePicker(_ label: String, _ b: Binding<ConvectionScheme>) -> some View {
        Picker(label, selection: b) { ForEach(ConvectionScheme.allCases, id: \.self) { Text($0.displayName).tag($0) } }
    }
}

struct ControlsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Under-Relaxation Factors") {
                NumberField(label: "Pressure", value: $ws.setup.controls.urf.pressure)
                NumberField(label: "Density", value: $ws.setup.controls.urf.density)
                NumberField(label: "Body Forces", value: $ws.setup.controls.urf.bodyForces)
                NumberField(label: "Momentum", value: $ws.setup.controls.urf.momentum)
                if ws.setup.models.viscous.isTurbulent {
                    if ws.setup.models.viscous == .spalartAllmaras {
                        NumberField(label: "Modified Turbulent Viscosity", value: $ws.setup.controls.urf.modifiedTurbulentViscosity)
                    } else {
                        NumberField(label: "Turbulent Kinetic Energy", value: $ws.setup.controls.urf.turbulentKineticEnergy)
                        if ws.setup.models.viscous.usesOmega { NumberField(label: "Specific Dissipation Rate", value: $ws.setup.controls.urf.specificDissipationRate) }
                        else { NumberField(label: "Turbulent Dissipation Rate", value: $ws.setup.controls.urf.dissipationRate) }
                    }
                    NumberField(label: "Turbulent Viscosity", value: $ws.setup.controls.urf.turbulentViscosity)
                }
                if ws.setup.models.energy { NumberField(label: "Energy", value: $ws.setup.controls.urf.energy) }
                if ws.setup.methods.coupling != .simple {
                    Text("SIMPLEC/PISO apply the full pressure correction (pressure factor treated as 1).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Linear Solvers (AMG)") {
                linear("Pressure", $ws.setup.controls.linear.pressure)
                linear("Momentum", $ws.setup.controls.linear.momentum)
                if ws.setup.models.viscous.isTurbulent { linear("Turbulence", $ws.setup.controls.linear.turbulence) }
                if ws.setup.models.energy { linear("Energy", $ws.setup.controls.linear.energy) }
                Toggle("Metal GPU acceleration for pressure (mixed precision)", isOn: $ws.setup.controls.linear.useGPU)
            }
            Section("Limits") {
                NumberField(label: "Minimum absolute temperature", value: $ws.setup.controls.limits.minimumTemperature, unit: "K")
                NumberField(label: "Maximum absolute temperature", value: $ws.setup.controls.limits.maximumTemperature, unit: "K")
                NumberField(label: "Minimum turbulent kinetic energy", value: $ws.setup.controls.limits.minimumK, unit: "m²/s²")
                NumberField(label: "Maximum turbulent viscosity ratio", value: $ws.setup.controls.limits.maximumViscosityRatio)
            }
        }
        .formStyle(.grouped)
    }
    func linear(_ label: String, _ b: Binding<LinearSolverSettings>) -> some View {
        DisclosureGroup(label) {
            Picker("Method", selection: b.method) {
                Text("AMG-preconditioned flexible CG").tag(LinearMethod.amgCG)
                Text("AMG-preconditioned BiCGStab").tag(LinearMethod.amgBiCGStab)
                Text("AMG cycles").tag(LinearMethod.amg)
                Text("Gauss-Seidel").tag(LinearMethod.gaussSeidel)
            }
            Picker("Cycle", selection: b.cycle) { ForEach(AMGCycle.allCases, id: \.self) { Text($0.rawValue + "-cycle").tag($0) } }
            NumberField(label: "Termination criterion", value: b.relTol)
            IntField(label: "Max cycles", value: b.maxIterations)
        }
    }
}

struct ReportDefinitionsPage: View {
    @Bindable var ws: Workspace
    @State private var selected: String?
    @State private var newKind: ReportKind = .dragCoefficient
    var body: some View {
        VStack(spacing: 0) {
            List(ws.setup.reports, id: \.name, selection: $selected) { r in
                HStack { Text(r.name); Spacer(); Text(r.kind.displayName).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(minHeight: 100, maxHeight: 180)
            HStack {
                Picker("", selection: $newKind) { ForEach(ReportKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.labelsHidden()
                Button("New") {
                    var r = ReportDefinition(name: "report-def-\(ws.setup.reports.count + 1)", kind: newKind)
                    if [.force, .dragCoefficient, .liftCoefficient, .momentCoefficient].contains(newKind) {
                        r.zones = ws.mesh?.boundaryZones.filter { $0.kind == .wall }.map(\.name) ?? []
                        if newKind == .liftCoefficient { r.direction = [0, 1, 0] }
                        if newKind == .momentCoefficient { r.direction = [0, 0, 1] }
                    }
                    if newKind == .massFlowRate { r.zones = ws.mesh?.boundaryZones.filter { $0.kind == .pressureOutlet }.map(\.name) ?? [] }
                    ws.setup.reports.append(r); selected = r.name
                }
                Button("Delete") { ws.setup.reports.removeAll { $0.name == selected }; selected = nil }.disabled(selected == nil)
            }
            .padding(8)
            Divider()
            if let i = ws.setup.reports.firstIndex(where: { $0.name == selected }) {
                ReportEditor(ws: ws, report: $ws.setup.reports[i])
            } else { Spacer() }
        }
    }
}

struct ReportEditor: View {
    @Bindable var ws: Workspace
    @Binding var report: ReportDefinition
    var body: some View {
        Form {
            Section(report.kind.displayName) {
                TextField("Name", text: $report.name)
                switch report.kind {
                case .areaWeightedAverage, .massWeightedAverage, .integral, .volumeAverage, .volumeMaximum, .volumeMinimum:
                    Picker("Field", selection: $report.field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                case .force, .dragCoefficient, .liftCoefficient, .momentCoefficient:
                    VectorField(label: report.kind == .momentCoefficient ? "Moment axis" : "Force vector", value: $report.direction)
                    if report.kind == .momentCoefficient { VectorField(label: "Moment centre", value: $report.momentCentre, unit: "m") }
                case .expression:
                    TextField("Expression", text: $report.expression)
                default: EmptyView()
                }
                Toggle("Plot", isOn: $report.plot)
                Toggle("Print to console", isOn: $report.print)
            }
            if ![.volumeAverage, .volumeMaximum, .volumeMinimum, .expression].contains(report.kind), let m = ws.mesh {
                Section("Zones") {
                    MultiSelectList(items: m.boundaryZones.filter { $0.kind != .empty }.map(\.name), selection: $report.zones, emptyMeaning: "all zones")
                }
            }
            if let s = ws.solver, ws.initialized {
                Section("Current Value") {
                    Text(String(format: "%.6g", Reports.evaluate(report, solver: s))).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MonitorsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Residual Monitors — absolute criteria") {
                Toggle("Check convergence", isOn: $ws.setup.residuals.checkConvergence)
                NumberField(label: "continuity", value: $ws.setup.residuals.continuity)
                NumberField(label: "velocity", value: $ws.setup.residuals.velocity)
                if ws.setup.models.energy { NumberField(label: "energy", value: $ws.setup.residuals.energy) }
                if ws.setup.models.viscous.isTurbulent { NumberField(label: "turbulence", value: $ws.setup.residuals.turbulence) }
                if !ws.setup.models.passiveScalars.isEmpty { NumberField(label: "user scalars", value: $ws.setup.residuals.scalars) }
                Text("Residuals use Fluent's scaling: continuity is normalised by the largest imbalance in the first five iterations; other equations by Σ|aₚφₚ|.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show Residual Plot") { ws.graphicsTab = .residuals }
                Button("Show Report Plots") { ws.graphicsTab = .reports }
            }
        }
        .formStyle(.grouped)
    }
}

struct InitializationPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Initialization Methods") {
                Picker("Method", selection: $ws.setup.initialization.method) {
                    Text("Hybrid Initialization").tag(InitializationMethod.hybrid)
                    Text("Standard Initialization").tag(InitializationMethod.standard)
                }
                .pickerStyle(.radioGroup)
                if ws.setup.initialization.method == .hybrid {
                    Text("Solves Laplace equations for a potential-flow velocity field and pressure; temperature and turbulence take averaged inlet values.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if ws.setup.initialization.method == .standard {
                Section("Initial Values") {
                    if let m = ws.mesh {
                        Picker("Compute from", selection: $ws.setup.initialization.computeFrom) {
                            Text("— (use values below)").tag("")
                            ForEach(m.boundaryZones.filter { $0.kind != .empty }, id: \.name) { Text($0.name).tag($0.name) }
                        }
                    }
                    QuantityField(label: "Gauge pressure", value: $ws.setup.initialization.gaugePressure, unit: "Pa")
                    QuantityVectorField(label: "Velocity", value: $ws.setup.initialization.velocity, unit: "m/s")
                    QuantityField(label: "Temperature", value: $ws.setup.initialization.temperature, unit: "K")
                    if ws.setup.models.viscous.isTurbulent {
                        NumberField(label: "Turbulent kinetic energy", value: $ws.setup.initialization.k, unit: "m²/s²")
                        NumberField(label: "Specific dissipation rate", value: $ws.setup.initialization.omega, unit: "1/s")
                    }
                }
            }
            Section("Patch") {
                ForEach($ws.setup.initialization.patches.indices, id: \.self) { i in
                    PatchRow(patch: $ws.setup.initialization.patches[i], fields: ws.availableFields()) {
                        ws.setup.initialization.patches.remove(at: i)
                    }
                }
                Button("Add Patch Region") {
                    var p = PatchSettings()
                    let b = ws.mesh?.bounds ?? BoundingBox(min: .zero, max: Vec3(1, 1, 1))
                    p.parameters = [b.min.x, b.min.y, b.min.z, b.centre.x, b.centre.y, b.max.z]
                    ws.setup.initialization.patches.append(p)
                }
            }
            Section {
                Button {
                    ws.initialize()
                } label: { Label("Initialize", systemImage: "sparkles") }
                .controlSize(.large)
                .disabled(ws.mesh == nil || ws.isRunning)
                if ws.initialized { Label("Solution initialized", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PatchRow: View {
    @Binding var patch: PatchSettings
    var fields: [String]
    var onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Region", selection: $patch.region) { ForEach(PatchRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            Picker("Variable", selection: $patch.field) {
                ForEach(["pressure", "x-velocity", "y-velocity", "z-velocity", "temperature", "turbulent-kinetic-energy"] + fields.filter { !$0.contains("-") }, id: \.self) { Text($0).tag($0) }
            }
            QuantityField(label: "Value", value: $patch.value)
            TextField(patch.region == .box ? "xmin ymin zmin xmax ymax zmax" : (patch.region == .sphere ? "cx cy cz r" : "x0 y0 z0 x1 y1 z1 r"),
                      text: Binding(get: { patch.parameters.map { Quantity.format($0) }.joined(separator: " ") },
                                    set: { patch.parameters = $0.split(separator: " ").compactMap { Double($0) } }))
                .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
        }
    }
}

struct RunCalculationPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            if ws.setup.general.time == .steady {
                Section("Steady") {
                    IntField(label: "Number of iterations", value: $ws.setup.run.iterations)
                    IntField(label: "Reporting interval", value: $ws.setup.run.reportingInterval)
                }
            } else {
                Section("Transient") {
                    NumberField(label: "Time step size", value: $ws.setup.run.timeStepSize, unit: "s")
                    IntField(label: "Number of time steps", value: $ws.setup.run.numberOfTimeSteps)
                    IntField(label: "Max iterations / time step", value: $ws.setup.run.maxIterationsPerTimeStep)
                    Toggle("Data sampling for time statistics", isOn: $ws.setup.run.dataSampling)
                    LabeledContent("Flow time", value: String(format: "%.6g s", ws.flowTime))
                }
            }
            Section {
                HStack {
                    if ws.isRunning {
                        Button(role: .destructive) { ws.stop() } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.large)
                        ProgressView().controlSize(.small)
                        Text(ws.statusText).foregroundStyle(.secondary)
                    } else {
                        Button { ws.calculate() } label: { Label("Calculate", systemImage: "play.fill") }
                            .controlSize(.large).buttonStyle(.borderedProminent)
                            .disabled(ws.mesh == nil)
                    }
                }
                LabeledContent("Iterations so far", value: "\(ws.currentIteration)")
                if !ws.initialized { Text("The solution will be initialized first.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
