import SwiftUI
import UniformTypeIdentifiers
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftFoam

/// Everything OpenFOAM: installation, application and models, time and
/// output, schemes, linear solvers, pressure–velocity coupling, parallel decomposition,
/// function objects and the raw-dictionary escape hatches.
struct OpenFOAMPage: View {
    @Bindable var ws: Workspace

    var o: Binding<FoamSettings> { $ws.setup.openfoam }

    var body: some View {
        Form {
            FoamBackendSection(ws: ws)
            do {
                FoamPhysicsSection(ws: ws)
                FoamModelDetailsSection(ws: ws)
                FoamPatchConditionsSection(ws: ws)
                FoamFvOptionsSection(ws: ws)
                FoamTimeSection(ws: ws)
                FoamSchemesSection(ws: ws)
                FoamSolversSection(ws: ws)
                FoamCouplingSection(ws: ws)
                FoamParallelMonitorSection(ws: ws)
                FoamRunControlSection(ws: ws)
                FoamAveragingRefinementSection(ws: ws)
                FoamBafflesSection(ws: ws)
                FoamExpertSection(ws: ws)
                FoamCaseFilesSection(ws: ws)
            }
        }
        .formStyle(.grouped)
        .onAppear { if ws.foamInstallations.isEmpty { ws.refreshFoamInstallations() } }
    }
}

// MARK: - Backend, installation, case

struct FoamBackendSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Solver") {
            Text("OpenFOAM solves every case. Calculate writes this setup as an OpenFOAM case, runs it in the installation below and loads the latest time back, so every Results page works on the OpenFOAM solution.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Installation") {
            Picker("OpenFOAM", selection: $ws.setup.openfoam.installation) {
                Text(ws.foamInstallations.first.map { "Automatic (\($0.name))" } ?? "Automatic (none found)").tag("")
                ForEach(ws.foamInstallations) { inst in
                    Text("\(inst.name) — \(inst.version ?? "?")").tag(inst.location.path)
                }
                if !ws.setup.openfoam.installation.isEmpty && !ws.foamInstallations.contains(where: { $0.location.path == ws.setup.openfoam.installation }) {
                    Text(ws.setup.openfoam.installation).tag(ws.setup.openfoam.installation)
                }
            }
            HStack {
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.message = "Choose an OpenFOAM .app, an installation directory containing etc/bashrc, or the bashrc itself"
                    if p.runModal() == .OK, let u = p.url { ws.setup.openfoam.installation = u.path }
                }
                Button("Rescan") { ws.refreshFoamInstallations() }
                Button("Test") { ws.probeFoam() }
                Spacer()
                Text(ws.foamProbe).font(.caption).foregroundStyle(ws.foamProbe.hasPrefix("✗") ? .red : .secondary).lineLimit(2)
            }
        }
        Section("Case Directory") {
            HStack {
                TextField("Case directory", text: $ws.setup.openfoam.caseDirectory, prompt: Text("~/FluidCraft/<title> (default)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { ws.setup.openfoam.caseDirectory = u.path }
                }
            }
            let dir = ws.foamCaseDirectory
            Text(dir.path).font(.system(.caption, design: .monospaced)).foregroundStyle(dir.path.contains(" ") ? .red : .secondary)
            if dir.path.contains(" ") { Text("OpenFOAM cannot run in a path with spaces.").font(.caption).foregroundStyle(.red) }
            HStack {
                if ws.isRunning && ws.foamJob != nil {
                    Button(role: .destructive) { ws.stop() } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.large)
                    ProgressView().controlSize(.small)
                    Text(ws.statusText).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { ws.calculateWithOpenFOAM() } label: { Label("Run OpenFOAM", systemImage: "play.fill") }
                        .controlSize(.large).buttonStyle(.borderedProminent).disabled(ws.mesh == nil || ws.isRunning)
                }
                Spacer()
            }
            HStack {
                Button("Write Case") { ws.writeFoamCase() }.disabled(ws.mesh == nil || ws.isRunning)
                Button("Load Results") { ws.loadFoamResults() }.disabled(ws.mesh == nil || ws.isRunning)
                Menu("More") {
                    Button("Reveal in Finder") { ws.revealFoamCase() }
                    Button("Open in ParaView") { ws.openFoamInParaView() }
                    Divider()
                    Button("Clean Results and Logs") { ws.cleanFoamCase() }.disabled(ws.isRunning)
                }
                .fixedSize()
            }
            if !ws.foamStatus.isEmpty { Text(ws.foamStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Physics

struct FoamPhysicsSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        let app = FoamCaseWriter.resolvedApplication(ws.setup)
        let turb = FoamCaseWriter.resolvedTurbulence(ws.setup, application: app)
        Section("Application and Models") {
            Picker("Application", selection: $ws.setup.openfoam.application) {
                ForEach(FoamApplication.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if ws.setup.openfoam.application == .automatic {
                LabeledContent("Selected", value: app.rawValue)
            }
            Picker("Turbulence", selection: $ws.setup.openfoam.turbulence) {
                ForEach(FoamTurbulenceModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if ws.setup.openfoam.turbulence == .fromFluidCraft {
                LabeledContent("Selected", value: turb.family == .laminar ? "laminar" : "\(turb.family.rawValue) \(turb.rawValue)")
            }
            if turb.family != .laminar {
                Picker("Wall treatment", selection: $ws.setup.openfoam.wallTreatment) {
                    ForEach(FoamWallTreatment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            if turb.family == .LES {
                Picker("LES filter width (delta)", selection: $ws.setup.openfoam.lesDelta) {
                    ForEach(["cubeRootVol", "vanDriest", "smooth", "maxDeltaxyz"], id: \.self) { Text($0).tag($0) }
                }
                if !app.isTransient { Text("LES and DES need a transient application; Automatic picks one.").font(.caption).foregroundStyle(.orange) }
            }
            if app.isMultiRegion {
                Text("Conjugate heat transfer: the fluid zones form one region and each solid zone its own region, coupled through mappedWall interfaces (turbulentTemperatureRadCoupledMixed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Materials, boundary conditions, cell zones (solid, porous, MRF, sources, expressions), gravity, reports and initialization come from the Setup and Solution pages.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Radiation (thermophysical solvers)") {
            Picker("Model", selection: $ws.setup.openfoam.radiation.model) {
                Text("None").tag(FoamRadiation.Model.none)
                Text("Discrete ordinates (fvDOM)").tag(FoamRadiation.Model.fvDOM)
                Text("P1").tag(FoamRadiation.Model.P1)
            }
            if ws.setup.openfoam.radiation.model != .none {
                NumberField(label: "Absorption coefficient", value: $ws.setup.openfoam.radiation.absorption, unit: "1/m")
                NumberField(label: "Wall emissivity", value: $ws.setup.openfoam.radiation.emissivity)
                IntField(label: "Solve every n iterations", value: $ws.setup.openfoam.radiation.solverFrequency)
                if ws.setup.openfoam.radiation.model == .fvDOM {
                    IntField(label: "Azimuthal divisions (nPhi)", value: $ws.setup.openfoam.radiation.nPhi)
                    IntField(label: "Polar divisions (nTheta)", value: $ws.setup.openfoam.radiation.nTheta)
                }
                if ws.setup.openfoam.radiation.model == .P1 && ws.setup.openfoam.radiation.absorption <= 0 {
                    Text("P1 needs a participating gas (absorption > 0); use fvDOM for transparent air.").font(.caption).foregroundStyle(.orange)
                }
                Text("Needs the energy equation; the case runs with buoyantSimpleFoam / buoyantPimpleFoam (or the conjugate solver, where solid walls exchange radiation through qr).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Initial Fields") {
            Picker("0/ fields from", selection: $ws.setup.openfoam.initialFields) {
                ForEach(FoamInitialFields.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Continue from the latest time in the case", isOn: $ws.setup.openfoam.continueFromLatestTime)
            Toggle("Load results into FluidCraft when the run ends", isOn: $ws.setup.openfoam.loadResults)
        }
    }
}

// MARK: - Time and output

struct FoamTimeSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        let app = FoamCaseWriter.resolvedApplication(ws.setup)
        Section("Time and Output (controlDict)") {
            OptionalNumberField(label: app.isTransient ? "End time (override)" : "Iterations (override)",
                                value: $ws.setup.openfoam.endTime,
                                placeholder: app.isTransient ? Double(ws.setup.run.numberOfTimeSteps) * ws.setup.run.timeStepSize : Double(ws.setup.run.iterations),
                                unit: app.isTransient ? "s" : "")
            if app.isTransient {
                OptionalNumberField(label: "deltaT (override)", value: $ws.setup.openfoam.deltaT, placeholder: ws.setup.run.timeStepSize, unit: "s")
                Toggle("Adjustable time step (adjustTimeStep)", isOn: $ws.setup.openfoam.adjustTimeStep)
                if ws.setup.openfoam.adjustTimeStep {
                    NumberField(label: "maxCo", value: $ws.setup.openfoam.maxCo)
                    NumberField(label: "maxDeltaT", value: $ws.setup.openfoam.maxDeltaT, unit: "s")
                }
            }
            Picker("writeControl", selection: $ws.setup.openfoam.writeControl) {
                ForEach(FoamWriteControl.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if [.runTime, .adjustableRunTime, .clockTime, .cpuTime].contains(ws.setup.openfoam.writeControl) {
                NumberField(label: "Write interval", value: $ws.setup.openfoam.writeEvery, unit: "s")
            } else {
                IntField(label: "Write every N steps (0 = at the end)", value: $ws.setup.openfoam.writeInterval)
            }
            Picker("writeFormat", selection: $ws.setup.openfoam.writeFormat) { Text("binary").tag("binary"); Text("ascii").tag("ascii") }
                .pickerStyle(.segmented)
            IntField(label: "writePrecision", value: $ws.setup.openfoam.writePrecision)
            IntField(label: "purgeWrite (0 = keep all)", value: $ws.setup.openfoam.purgeWrite)
        }
    }
}

/// A number that is either derived (nil, showing the derived value as placeholder) or set.
struct OptionalNumberField: View {
    var label: String
    @Binding var value: Double?
    var placeholder: Double
    var unit = ""
    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? placeholder) : nil })) { Text(label) }
                .toggleStyle(.checkbox)
            Spacer()
            if value != nil {
                NumberField(label: "", value: Binding(get: { value ?? placeholder }, set: { value = $0 }), unit: unit)
            } else {
                Text(NumberField.format(placeholder) + (unit.isEmpty ? "" : " \(unit)")).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Schemes

struct FoamSchemesSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Discretisation Schemes (fvSchemes)") {
            Text("Empty fields follow the Methods page. Anything typed is written verbatim, e.g. `bounded Gauss linearUpwind limited`, `cellLimited leastSquares 1`, `Gauss linear limited corrected 0.5`.")
                .font(.caption).foregroundStyle(.secondary)
            SchemeField(label: "ddtSchemes default", text: $ws.setup.openfoam.schemes.ddt, hint: "steadyState / Euler / backward / CrankNicolson 0.9")
            SchemeField(label: "gradSchemes default", text: $ws.setup.openfoam.schemes.grad, hint: "leastSquares / Gauss linear")
            SchemeField(label: "grad(U)", text: $ws.setup.openfoam.schemes.gradU, hint: "cellLimited Gauss linear 1")
            SchemeField(label: "div(phi,U)", text: $ws.setup.openfoam.schemes.divU, hint: "bounded Gauss linearUpwind grad(U)")
            SchemeField(label: "div(phi, turbulence)", text: $ws.setup.openfoam.schemes.divTurbulence, hint: "bounded Gauss upwind")
            SchemeField(label: "div(phi, energy)", text: $ws.setup.openfoam.schemes.divEnergy, hint: "bounded Gauss upwind")
            SchemeField(label: "div(phi, scalars)", text: $ws.setup.openfoam.schemes.divScalars, hint: "bounded Gauss limitedLinear 1")
            SchemeField(label: "laplacianSchemes default", text: $ws.setup.openfoam.schemes.laplacian, hint: "Gauss linear corrected")
            SchemeField(label: "snGradSchemes default", text: $ws.setup.openfoam.schemes.snGrad, hint: "corrected")
            SchemeField(label: "interpolationSchemes default", text: $ws.setup.openfoam.schemes.interpolation, hint: "linear")
            Picker("wallDist method", selection: $ws.setup.openfoam.schemes.wallDistance) {
                ForEach(["meshWave", "meshWaveFrozen", "Poisson", "advectionDiffusion", "exactDistance"], id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

struct SchemeField: View {
    var label: String
    @Binding var text: String
    var hint: String
    var body: some View {
        LabeledContent(label) {
            TextField(hint, text: $text).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(minWidth: 220)
        }
    }
}

// MARK: - Linear solvers

struct FoamSolversSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Linear Solvers (fvSolution › solvers)") {
            LinearSolverEditor(title: "Pressure (p / p_rgh)", value: $ws.setup.openfoam.pressureSolver)
            LinearSolverEditor(title: "Velocity (U)", value: $ws.setup.openfoam.velocitySolver)
            LinearSolverEditor(title: "Turbulence (k, ω, ε, ν̃)", value: $ws.setup.openfoam.turbulenceSolver)
            LinearSolverEditor(title: "Energy and scalars (T, h, e)", value: $ws.setup.openfoam.energySolver)
        }
    }
}

struct LinearSolverEditor: View {
    var title: String
    @Binding var value: FoamLinearSolver
    var body: some View {
        DisclosureGroup(title + " — \(value.solver)") {
            Picker("solver", selection: $value.solver) { ForEach(FoamLinearSolver.solverChoices, id: \.self) { Text($0).tag($0) } }
            if value.solver == "GAMG" || value.solver == "smoothSolver" {
                Picker("smoother", selection: $value.smoother) { ForEach(FoamLinearSolver.smootherChoices, id: \.self) { Text($0).tag($0) } }
            } else {
                Picker("preconditioner", selection: $value.preconditioner) { ForEach(FoamLinearSolver.preconditionerChoices, id: \.self) { Text($0).tag($0) } }
            }
            NumberField(label: "tolerance", value: $value.tolerance)
            NumberField(label: "relTol", value: $value.relTol)
            IntField(label: "maxIter", value: $value.maxIter)
            IntField(label: "minIter", value: $value.minIter)
            if value.solver == "GAMG" {
                IntField(label: "nCellsInCoarsestLevel", value: $value.nCellsInCoarsestLevel)
                IntField(label: "nPreSweeps", value: $value.nPreSweeps)
                IntField(label: "nPostSweeps", value: $value.nPostSweeps)
                IntField(label: "mergeLevels", value: $value.mergeLevels)
                Toggle("cacheAgglomeration", isOn: $value.cacheAgglomeration)
            }
            if value.solver == "smoothSolver" { IntField(label: "nSweeps", value: $value.nSweeps) }
        }
    }
}

// MARK: - Coupling and relaxation

struct FoamCouplingSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        let app = FoamCaseWriter.resolvedApplication(ws.setup)
        Section(app.isTransient ? "PIMPLE / PISO Controls" : "SIMPLE Controls") {
            Picker("consistent (SIMPLEC)", selection: Binding(
                get: { ws.setup.openfoam.consistent.map { $0 ? 1 : 0 } ?? -1 },
                set: { ws.setup.openfoam.consistent = $0 < 0 ? nil : $0 == 1 })) {
                Text("From Methods (\(ws.setup.methods.coupling.rawValue))").tag(-1)
                Text("yes").tag(1)
                Text("no").tag(0)
            }
            if app.isTransient {
                IntField(label: "nOuterCorrectors", value: $ws.setup.openfoam.nOuterCorrectors)
                IntField(label: "nCorrectors", value: $ws.setup.openfoam.nCorrectors)
                Toggle("momentumPredictor", isOn: $ws.setup.openfoam.momentumPredictor)
                Toggle("turbOnFinalIterOnly", isOn: $ws.setup.openfoam.turbOnFinalIterOnly)
                NumberField(label: "Outer-loop residual control (0 = off)", value: $ws.setup.openfoam.outerResidual)
            }
            OptionalIntField(label: "nNonOrthogonalCorrectors", value: $ws.setup.openfoam.nNonOrthogonalCorrectors, placeholder: ws.setup.methods.nonOrthogonalCorrectors)
            Toggle("Pressure reference at a point (pRefPoint)", isOn: Binding(get: { ws.setup.openfoam.pressureReferencePoint != nil },
                                                                           set: { on in ws.setup.openfoam.pressureReferencePoint = on ? (ws.mesh.map { let c = 0.5 * ($0.bounds.min + $0.bounds.max); return [c.x, c.y, c.z] } ?? [0, 0, 0]) : nil }))
            if ws.setup.openfoam.pressureReferencePoint != nil {
                VectorField(label: "pRefPoint", value: Binding(get: { ws.setup.openfoam.pressureReferencePoint ?? [0, 0, 0] }, set: { ws.setup.openfoam.pressureReferencePoint = $0 }), unit: "m")
            }
            NumberField(label: "pRefValue (gauge)", value: $ws.setup.openfoam.pressureReferenceValue, unit: "Pa")
            Text("The reference is used only when no boundary fixes the pressure (closed or periodic domains).").font(.caption).foregroundStyle(.secondary)
        }
        if !app.isTransient {
            Section("Convergence (residualControl, initial residuals; 0 = off)") {
                NumberField(label: "Pressure", value: $ws.setup.openfoam.residualP)
                NumberField(label: "Velocity", value: $ws.setup.openfoam.residualU)
                NumberField(label: "Turbulence", value: $ws.setup.openfoam.residualTurbulence)
                NumberField(label: "Energy", value: $ws.setup.openfoam.residualEnergy)
            }
        }
        Section("Relaxation Factors (unchecked = Controls page)") {
            OptionalNumberField(label: "Pressure (field)", value: $ws.setup.openfoam.relaxationP, placeholder: ws.setup.controls.urf.pressure)
            OptionalNumberField(label: "U (equation)", value: $ws.setup.openfoam.relaxationU, placeholder: ws.setup.controls.urf.momentum)
            OptionalNumberField(label: "Turbulence (equations)", value: $ws.setup.openfoam.relaxationTurbulence, placeholder: ws.setup.controls.urf.turbulentKineticEnergy)
            OptionalNumberField(label: "Energy (equation)", value: $ws.setup.openfoam.relaxationEnergy, placeholder: ws.setup.controls.urf.energy)
        }
    }
}

struct OptionalIntField: View {
    var label: String
    @Binding var value: Int?
    var placeholder: Int
    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? placeholder) : nil })) { Text(label) }.toggleStyle(.checkbox)
            Spacer()
            if value != nil { IntField(label: "", value: Binding(get: { value ?? placeholder }, set: { value = $0 })) }
            else { Text("\(placeholder)").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Parallel and monitors

struct FoamParallelMonitorSection: View {
    @Bindable var ws: Workspace
    @State private var probeText = ""
    var body: some View {
        Section("Parallel (decomposeParDict)") {
            Stepper("Cores: \(ws.setup.openfoam.cores)", value: $ws.setup.openfoam.cores, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
            Picker("Decomposition method", selection: $ws.setup.openfoam.decomposition) {
                ForEach(["scotch", "hierarchical", "simple", "kahip"], id: \.self) { Text($0).tag($0) }
            }
            .disabled(ws.setup.openfoam.cores < 2)
            if ["hierarchical", "simple"].contains(ws.setup.openfoam.decomposition) && ws.setup.openfoam.cores > 1 {
                Toggle("Set the split (n)", isOn: Binding(get: { ws.setup.openfoam.decompositionSplit != nil },
                                                        set: { ws.setup.openfoam.decompositionSplit = $0 ? [ws.setup.openfoam.cores, 1, 1] : nil }))
                if let d = ws.setup.openfoam.decompositionSplit, d.count == 3 {
                    HStack {
                        ForEach(0..<3, id: \.self) { i in
                            IntField(label: ["x", "y", "z"][i], value: Binding(get: { ws.setup.openfoam.decompositionSplit?[i] ?? 1 },
                                                                               set: { ws.setup.openfoam.decompositionSplit?[i] = max(1, $0) }))
                        }
                    }
                    if d[0] * d[1] * d[2] != ws.setup.openfoam.cores { Text("x × y × z must equal the core count.").font(.caption).foregroundStyle(.orange) }
                }
                Picker("order", selection: $ws.setup.openfoam.decompositionOrder) {
                    ForEach(["xyz", "xzy", "yxz", "yzx", "zxy", "zyx"], id: \.self) { Text($0).tag($0) }
                }
            }
            Text("More than one core runs decomposePar, mpirun -np N <solver> -parallel and reconstructPar.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Function Objects") {
            Toggle("checkMesh before solving", isOn: $ws.setup.openfoam.checkMesh)
            Toggle("yPlus on walls", isOn: $ws.setup.openfoam.yPlus)
            Toggle("wallShearStress", isOn: $ws.setup.openfoam.wallShearStress)
            Toggle("fieldMinMax (U, p, T)", isOn: $ws.setup.openfoam.fieldMinMax)
            Toggle("vorticity", isOn: $ws.setup.openfoam.vorticity)
            Toggle("Q criterion", isOn: $ws.setup.openfoam.qCriterion)
            VStack(alignment: .leading) {
                Text("Probe locations (one \"x y z\" per line)")
                TextEditor(text: Binding(get: { ws.setup.openfoam.probes.map { $0.map { Quantity.format($0) }.joined(separator: " ") }.joined(separator: "\n") },
                                         set: { ws.setup.openfoam.probes = $0.split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }.filter { $0.count == 3 } }))
                    .font(.system(.caption, design: .monospaced)).frame(height: 54).border(.quaternary)
            }
            Text("Report definitions become forceCoeffs, forces, surfaceFieldValue and volFieldValue objects and are plotted live in Report Plots.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Expert

struct FoamExpertSection: View {
    @Bindable var ws: Workspace
    @State private var appendFile = "system/fvSolution"
    @State private var newFilePath = "system/topoSetDict"
    var body: some View {
        Section("Raw Boundary Conditions (any OpenFOAM type)") {
            ForEach(Array(ws.setup.openfoam.patchOverrides.enumerated()), id: \.offset) { i, _ in
                let ov: Binding<FoamPatchOverride> = Binding<FoamPatchOverride>.element($ws.setup.openfoam.patchOverrides, i, fallback: FoamPatchOverride(patch: "", field: "U", text: ""))
                VStack(alignment: .leading) {
                    HStack {
                        Picker("Patch", selection: ov.patch) {
                            ForEach(ws.mesh?.boundaryZones.map(\.name) ?? [ov.wrappedValue.patch], id: \.self) { Text($0).tag($0) }
                        }
                        TextField("field", text: ov.field).textFieldStyle(.roundedBorder).frame(width: 80)
                        Button(role: .destructive) { ws.setup.openfoam.patchOverrides.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    TextEditor(text: ov.text).font(.system(.caption, design: .monospaced)).frame(height: 60).border(.quaternary)
                }
            }
            Button("Add Raw Condition") {
                let patch = ws.mesh?.boundaryZones.first?.name ?? "inlet"
                ws.setup.openfoam.patchOverrides.append(FoamPatchOverride(patch: patch, field: "U", text: "type            fixedValue;\nvalue           uniform (1 0 0);"))
            }
            Text("The text replaces everything inside the patch's braces in 0/<field>.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Append to Generated Dictionaries") {
            Picker("File", selection: $appendFile) {
                ForEach(["system/controlDict", "system/fvSchemes", "system/fvSolution", "system/decomposeParDict", "constant/turbulenceProperties",
                         "constant/transportProperties", "constant/thermophysicalProperties", "constant/fvOptions", "constant/MRFProperties"], id: \.self) { Text($0).tag($0) }
            }
            TextEditor(text: Binding(get: { ws.setup.openfoam.dictionaryAppends[appendFile] ?? "" },
                                     set: { ws.setup.openfoam.dictionaryAppends[appendFile] = $0.isEmpty ? nil : $0 }))
                .font(.system(.caption, design: .monospaced)).frame(height: 70).border(.quaternary)
            Text("Later entries override earlier ones, e.g. `SIMPLE { nNonOrthogonalCorrectors 2; }` merges into the generated SIMPLE dictionary.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Custom function objects (inside controlDict › functions)")
                TextEditor(text: $ws.setup.openfoam.customFunctions).font(.system(.caption, design: .monospaced)).frame(height: 70).border(.quaternary)
            }
        }
        Section("Extra Files and Stages") {
            ForEach(ws.setup.openfoam.extraFiles.keys.sorted(), id: \.self) { path in
                DisclosureGroup(path) {
                    TextEditor(text: Binding(get: { ws.setup.openfoam.extraFiles[path] ?? "" }, set: { ws.setup.openfoam.extraFiles[path] = $0 }))
                        .font(.system(.caption, design: .monospaced)).frame(height: 80).border(.quaternary)
                    Button("Remove", role: .destructive) { ws.setup.openfoam.extraFiles[path] = nil }
                }
            }
            HStack {
                TextField("case-relative path", text: $newFilePath).textFieldStyle(.roundedBorder)
                Button("Add File") {
                    let p = newFilePath.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty && ws.setup.openfoam.extraFiles[p] == nil {
                        ws.setup.openfoam.extraFiles[p] = "FoamFile { version 2.0; format ascii; class dictionary; object \((p as NSString).lastPathComponent); }\n\n"
                    }
                }
            }
            ForEach(Array(ws.setup.openfoam.customStages.enumerated()), id: \.offset) { i, _ in
                let st: Binding<FoamCustomStage> = Binding<FoamCustomStage>.element($ws.setup.openfoam.customStages, i, fallback: FoamCustomStage(phase: .afterSolve, command: ""))
                HStack {
                    Picker("", selection: st.phase) { Text("before solve").tag(FoamCustomStage.Phase.beforeSolve); Text("after solve").tag(FoamCustomStage.Phase.afterSolve) }
                        .labelsHidden().frame(width: 120)
                    TextField("command", text: st.command).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    Toggle("parallel", isOn: st.parallel).toggleStyle(.checkbox)
                    Button(role: .destructive) { ws.setup.openfoam.customStages.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            Button("Add Stage") { ws.setup.openfoam.customStages.append(FoamCustomStage(phase: .afterSolve, command: "postProcess -func vorticity -latestTime")) }
            Text("Stages run in the case directory with the OpenFOAM environment, e.g. topoSet, setFields, postProcess.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
