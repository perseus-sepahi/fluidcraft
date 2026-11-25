import SwiftUI
import AppKit
import CurlewMesh
import CurlewSolver
import CurlewFoam

// OpenFOAM page sections for the settings beyond the core set: model coefficients and
// thermophysical models, per-patch OpenFOAM conditions, fvOptions, time averaging and adaptive
// refinement. Each maps onto OpenFOAM dictionary entries.

/// Rows of numbers edited as text, one row per line ("a b c").
struct RowsEditor: View {
    var label: String
    @Binding var rows: [[Double]]
    var columns: Int
    var height: CGFloat = 80
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout)
            TextEditor(text: Binding(get: { rows.map { $0.map { Quantity.format($0) }.joined(separator: " ") }.joined(separator: "\n") },
                                     set: { rows = $0.split(separator: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).compactMap { Double($0) } }.filter { $0.count == columns } }))
                .font(.system(.caption, design: .monospaced)).frame(height: height).border(.quaternary)
        }
    }
}

/// Coefficients of a polynomial or a NASA set, edited as one line.
struct CoefficientsField: View {
    var label: String
    @Binding var values: [Double]
    var count: Int
    var body: some View {
        LabeledContent(label) {
            TextField("\(count) numbers", text: Binding(get: { values.map { Quantity.format($0) }.joined(separator: " ") },
                                                        set: { let v = $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }; if v.count == count { values = v } }))
                .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced)).frame(minWidth: 260)
        }
    }
}

// MARK: - Model coefficients and thermophysics

struct FoamModelDetailsSection: View {
    @Bindable var ws: Workspace
    @State private var coeffText = ""
    var body: some View {
        let app = FoamCaseWriter.resolvedApplication(ws.setup)
        let turb = FoamCaseWriter.resolvedTurbulence(ws.setup, application: app)
        if turb.family != .laminar {
            Section("Turbulence-Model Coefficients (\(turb.rawValue)Coeffs)") {
                TextEditor(text: Binding(get: { ws.setup.openfoam.turbulenceCoefficients.sorted { $0.key < $1.key }.map { "\($0.key) \(Quantity.format($0.value))" }.joined(separator: "\n") },
                                         set: { text in
                                             var d: [String: Double] = [:]
                                             for line in text.split(separator: "\n") {
                                                 let w = line.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == "\t" })
                                                 if w.count == 2, let v = Double(w[1]) { d[String(w[0])] = v }
                                             }
                                             ws.setup.openfoam.turbulenceCoefficients = d
                                         }))
                    .font(.system(.caption, design: .monospaced)).frame(height: 54).border(.quaternary)
                Text("One \"name value\" per line, e.g. Cmu 0.09, betaStar 0.09, sigmaEps 1.3, Cs 0.17. Blank keeps OpenFOAM's defaults (printed in the solver log by printCoeffs).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if app.isThermal {
            FoamThermoSection(ws: ws)
        }
    }
}

struct FoamThermoSection: View {
    @Bindable var ws: Workspace
    var th: Binding<FoamThermoSettings> { $ws.setup.openfoam.thermo }
    var body: some View {
        Section("Thermophysical Model (thermophysicalProperties)") {
            Picker("Transport (μ, κ)", selection: th.transport) {
                Text("From Materials (constant / Sutherland)").tag(FoamThermoSettings.Transport.automatic)
                Text("const").tag(FoamThermoSettings.Transport.const)
                Text("sutherland").tag(FoamThermoSettings.Transport.sutherland)
                Text("polynomial μ(T), κ(T)").tag(FoamThermoSettings.Transport.polynomial)
            }
            Picker("Thermo (Cp)", selection: th.thermo) {
                Text("hConst (constant Cp)").tag(FoamThermoSettings.Thermo.hConst)
                Text("janaf (NASA polynomials)").tag(FoamThermoSettings.Thermo.janaf)
                Text("hPolynomial Cp(T)").tag(FoamThermoSettings.Thermo.hPolynomial)
            }
            Picker("Equation of state", selection: th.equationOfState) {
                Text("From Materials (density method)").tag(FoamThermoSettings.EquationOfState.automatic)
                ForEach(FoamThermoSettings.EquationOfState.allCases.filter { $0 != .automatic }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            let t = ws.setup.openfoam.thermo
            if t.thermo == .janaf {
                NumberField(label: "Tlow", value: th.janafTlow, unit: "K")
                NumberField(label: "Tcommon", value: th.janafTcommon, unit: "K")
                NumberField(label: "Thigh", value: th.janafThigh, unit: "K")
                CoefficientsField(label: "highCpCoeffs", values: th.highCpCoeffs, count: 7)
                CoefficientsField(label: "lowCpCoeffs", values: th.lowCpCoeffs, count: 7)
                Button("Air (NASA, from OpenFOAM's tutorials)") {
                    ws.setup.openfoam.thermo.highCpCoeffs = FoamThermoSettings.airJanafHigh
                    ws.setup.openfoam.thermo.lowCpCoeffs = FoamThermoSettings.airJanafLow
                    ws.setup.openfoam.thermo.janafTlow = 200; ws.setup.openfoam.thermo.janafTcommon = 1000; ws.setup.openfoam.thermo.janafThigh = 3500
                }
            }
            if t.thermo == .hPolynomial {
                CoefficientsField(label: "Cp(T) = Σ aᵢTⁱ [J/(kg K)]", values: th.cpCoeffs, count: 8)
                NumberField(label: "Hf (formation enthalpy)", value: th.formationEnthalpy, unit: "J/kg")
                NumberField(label: "Sf (formation entropy)", value: th.formationEntropy, unit: "J/(kg K)")
            }
            if t.transport == .polynomial {
                CoefficientsField(label: "μ(T) [Pa s]", values: th.muCoeffs, count: 8)
                CoefficientsField(label: "κ(T) [W/(m K)]", values: th.kappaCoeffs, count: 8)
            }
            switch t.equationOfState {
            case .PengRobinsonGas:
                NumberField(label: "Critical temperature Tc", value: th.criticalTemperature, unit: "K")
                NumberField(label: "Critical pressure Pc", value: th.criticalPressure, unit: "Pa")
                NumberField(label: "Critical molar volume Vc", value: th.criticalVolume, unit: "m³/kmol")
                NumberField(label: "Acentric factor ω", value: th.acentricFactor)
            case .icoPolynomial:
                CoefficientsField(label: "ρ(T) [kg/m³]", values: th.rhoCoeffs, count: 8)
            case .perfectFluid:
                NumberField(label: "R", value: th.perfectFluidR, unit: "J/(kg K)")
                NumberField(label: "ρ₀", value: th.perfectFluidRho0, unit: "kg/m³")
            default: EmptyView()
            }
            Text("OpenFOAM is compiled for some combinations only; a case that asks for another is refused with the combinations it does have. The energy form (enthalpy or internal energy) follows what OpenFOAM offers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Per-patch OpenFOAM conditions

struct FoamPatchConditionsSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Boundary Conditions (OpenFOAM types per patch)") {
            let zones = (ws.mesh?.boundaryZones ?? []).filter { $0.kind != .empty }
            if zones.isEmpty { Text("Load or generate a mesh to set OpenFOAM conditions per patch.").foregroundStyle(.secondary) }
            ForEach(zones, id: \.name) { z in
                let kind = ws.setup.boundaries[z.name]?.type ?? z.kind
                let choices = FoamPatchCondition.allCases.filter { $0.applies(to: kind) }
                if choices.count > 1 {
                    let po = Binding<FoamPatchOptions>(get: { ws.setup.openfoam.options(forPatch: z.name) },
                                                       set: { ws.setup.openfoam.patchOptions[z.name] = $0.condition == .automatic && $0 == FoamPatchOptions() ? nil : $0 })
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("\(z.name) (\(kind.rawValue))", selection: po.condition) {
                            ForEach(choices, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        PatchConditionEditor(options: po)
                    }
                }
            }
            Text("Conditions not listed here can be typed on OpenFOAM › Expert › Raw Boundary Conditions.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PatchConditionEditor: View {
    @Binding var options: FoamPatchOptions
    var body: some View {
        switch options.condition {
        case .volumetricFlowRate:
            NumberField(label: "Volume flow (into the domain)", value: $options.volumetricFlowRate, unit: "m³/s")
        case .syntheticTurbulence:
            NumberField(label: "Turbulence intensity", value: $options.turbulenceIntensity)
            NumberField(label: "Integral length scale L", value: $options.lengthScale, unit: "m")
            NumberField(label: "Inflow height δ (boundary layer / half channel)", value: $options.delta, unit: "m")
            Text("Divergence-free synthetic eddies (DFSEM) for LES/DES; R = ⅔k I from the intensity and the patch-mean velocity.").font(.caption).foregroundStyle(.secondary)
        case .profileFromFile:
            HStack {
                TextField("CSV file: x, y, z, Ux, Uy, Uz", text: $options.profileFile).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]; p.message = "CSV with columns x, y, z, Ux, Uy, Uz"
                    if p.runModal() == .OK, let u = p.url { options.profileFile = u.path }
                }
            }
            Text("Interpolated onto the patch faces (planar interpolation): the points must spread over the patch, e.g. an LES or measured inflow profile.").font(.caption).foregroundStyle(.secondary)
        case .fanCurve:
            RowsEditor(label: "Fan curve: volume flow [m³/s]  pressure rise [Pa]", rows: $options.fanCurve, columns: 2)
        case .nonReflecting:
            NumberField(label: "Distance to the far field lInf (0 = advective only)", value: $options.farFieldDistance, unit: "m")
            Text("Waves leave the domain instead of reflecting (transient runs; waveTransmissive for compressible solvers).").font(.caption).foregroundStyle(.secondary)
        case .roughWall:
            NumberField(label: "Sand-grain roughness Ks", value: $options.roughnessHeight, unit: "m")
            NumberField(label: "Roughness constant Cs", value: $options.roughnessConstant)
        case .automatic:
            EmptyView()
        }
    }
}

// MARK: - fvOptions

struct FoamFvOptionsSection: View {
    @Bindable var ws: Workspace
    var body: some View {
        Section("Sources and Constraints (fvOptions)") {
            ForEach(Array(ws.setup.openfoam.fvOptions.enumerated()), id: \.offset) { i, _ in
                let f = Binding<FoamFvOption>.element($ws.setup.openfoam.fvOptions, i, fallback: FoamFvOption())
                DisclosureGroup("\(f.wrappedValue.name) — \(f.wrappedValue.kind.displayName)") {
                    TextField("Name", text: f.name).textFieldStyle(.roundedBorder)
                    Picker("Cell zone", selection: f.zone) {
                        Text("Whole domain").tag("")
                        ForEach(ws.mesh?.cellZones.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    switch f.wrappedValue.kind {
                    case .fixedTemperature:
                        NumberField(label: "Temperature", value: f.temperature, unit: "K")
                    case .velocityDamping:
                        NumberField(label: "Damp above |U|", value: f.maximumVelocity, unit: "m/s")
                    case .rotorDisk:
                        RotorDiskEditor(rotor: f.rotor)
                    }
                    Button("Remove", role: .destructive) { ws.setup.openfoam.fvOptions.remove(at: i) }
                }
            }
            Menu("Add") {
                ForEach(FoamFvOption.Kind.allCases, id: \.self) { k in
                    Button(k.displayName) {
                        var opt = FoamFvOption(name: "\(k.rawValue)\(ws.setup.openfoam.fvOptions.count + 1)", kind: k)
                        if k == .rotorDisk, let z = ws.mesh?.cellZones.first(where: { $0.name != "fluid" }) { opt.zone = z.name }
                        ws.setup.openfoam.fvOptions.append(opt)
                    }
                }
            }
            .fixedSize()
            Text("Porous zones, MRF, momentum and energy sources and actuator disks stay on the Cell Zone pages.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RotorDiskEditor: View {
    @Binding var rotor: FoamRotorDisk
    var body: some View {
        IntField(label: "Blades", value: $rotor.blades)
        NumberField(label: "Speed", value: $rotor.rpm, unit: "rpm")
        VectorField(label: "Hub centre", value: $rotor.origin, unit: "m")
        VectorField(label: "Axis (right-hand rotation)", value: $rotor.axis)
        VectorField(label: "Blade-angle reference (⊥ axis)", value: $rotor.referenceDirection)
        NumberField(label: "Collective pitch θ₀", value: $rotor.collectivePitch, unit: "°")
        NumberField(label: "Tip effect (lift-free beyond r/R)", value: $rotor.tipEffect)
        RowsEditor(label: "Blade sections: radius [m]  twist [°]  chord [m]", rows: $rotor.sections, columns: 3)
        RowsEditor(label: "Airfoil table: angle of attack [°]  Cd  Cl", rows: $rotor.profile, columns: 3, height: 110)
    }
}

// MARK: - Averaging and adaptive refinement

struct FoamAveragingRefinementSection: View {
    @Bindable var ws: Workspace
    var fa: Binding<FoamFieldAverage> { $ws.setup.openfoam.fieldAverage }
    var ar: Binding<FoamAdaptiveRefinement> { $ws.setup.openfoam.adaptiveRefinement }
    var body: some View {
        let transient = FoamCaseWriter.resolvedApplication(ws.setup).isTransient
        Section("Time Averaging (fieldAverage, transient)") {
            Picker("Averaging", selection: Binding(get: { ws.setup.openfoam.fieldAverage.enabled.map { $0 ? 1 : 0 } ?? -1 },
                                                   set: { ws.setup.openfoam.fieldAverage.enabled = $0 < 0 ? nil : $0 == 1 })) {
                Text("With Run Calculation's data sampling").tag(-1); Text("On").tag(1); Text("Off").tag(0)
            }
            TextField("Fields (e.g. U p T k)", text: fa.fields).textFieldStyle(.roundedBorder)
            Toggle("Variance ⟨φ′φ′⟩ (prime2Mean; Reynolds stresses for U)", isOn: fa.prime2Mean)
            NumberField(label: "Start averaging at", value: fa.startTime, unit: "s")
            NumberField(label: "Window (0 = whole run)", value: fa.window, unit: "s")
            if !transient { Text("Steady applications do not average.").font(.caption).foregroundStyle(.orange) }
        }
        Section("Adaptive Mesh Refinement (dynamicRefineFvMesh)") {
            Toggle("Refine and unrefine during the run", isOn: ar.enabled)
            if ws.setup.openfoam.adaptiveRefinement.enabled {
                TextField("Field or expression (p, T, k, mag(U), mag(fvc::grad(T))…)", text: ar.field).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                NumberField(label: "Refine where value ≥", value: ar.lowerLevel)
                NumberField(label: "and ≤", value: ar.upperLevel)
                NumberField(label: "Unrefine where value <", value: ar.unrefineLevel)
                IntField(label: "Every N time steps", value: ar.refineInterval)
                IntField(label: "Maximum refinement levels", value: ar.maxRefinement)
                IntField(label: "Maximum cells", value: ar.maxCells)
                IntField(label: "Buffer layers", value: ar.bufferLayers)
                if !transient { Text("Needs a transient application (pimpleFoam and the other PIMPLE solvers).").font(.caption).foregroundStyle(.orange) }
                if let m = ws.mesh, m.cellShapeHistogram().contains(where: { $0.key != "hexahedra" && $0.value > 0 }) {
                    Text("OpenFOAM refines hexahedra only (hexRef8); this mesh has other cells too.").font(.caption).foregroundStyle(.orange)
                }
                Text("Splits each marked cell into 8 (3D meshes). The refined solution opens in ParaView and in Python scripts (Post-Processing), which read the mesh of each time; Curlew's Results pages keep the original mesh, so it is not loaded into them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
