import SwiftUI
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftFoam

struct GeneralPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Solver") {
                LabeledContent("OpenFOAM application", value: FoamCaseWriter.resolvedApplication(ws.setup).rawValue)
                Button("OpenFOAM settings…") { ws.selection = .openfoam }.buttonStyle(.link)
                Picker("Type", selection: $ws.setup.general.solver) {
                    Text("Pressure-Based").tag(SolverType.pressureBased)
                    Text("Density-Based").tag(SolverType.densityBased)
                }
                .pickerStyle(.radioGroup)
                if ws.setup.general.solver == .densityBased {
                    Text("Compressible ideal-gas flow with rhoCentralFoam (central-upwind fluxes). Use an ideal-gas material; viscous model Inviscid or Laminar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Flux scheme", selection: $ws.setup.methods.flux) {
                        Text("Kurganov").tag(FluxScheme.roe); Text("Tadmor").tag(FluxScheme.ausm)
                    }
                    NumberField(label: "Courant number", value: $ws.setup.methods.courantNumber)
                }
                Picker("Time", selection: $ws.setup.general.time) {
                    Text("Steady").tag(TimeMode.steady)
                    Text("Transient").tag(TimeMode.transient)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Velocity Formulation", value: "Absolute")
            }
            Section("Gravity") {
                Toggle("Gravity", isOn: $ws.setup.general.gravityEnabled)
                if ws.setup.general.gravityEnabled {
                    VectorField(label: "Gravitational acceleration", value: $ws.setup.general.gravity, unit: "m/s²")
                }
            }
            Section("Operating Conditions") {
                NumberField(label: "Operating pressure", value: $ws.setup.general.operatingPressure, unit: "Pa")
                NumberField(label: "Operating temperature", value: $ws.setup.general.operatingTemperature, unit: "K")
                Toggle("Specified operating density", isOn: Binding(
                    get: { ws.setup.general.operatingDensity != nil },
                    set: { ws.setup.general.operatingDensity = $0 ? (ws.setup.general.operatingDensity ?? 1.225) : nil }))
                if ws.setup.general.operatingDensity != nil {
                    NumberField(label: "Operating density", value: Binding(get: { ws.setup.general.operatingDensity ?? 1.225 }, set: { ws.setup.general.operatingDensity = $0 }), unit: "kg/m³")
                }
                VectorField(label: "Reference pressure location", value: $ws.setup.general.referencePressureLocation, unit: "m")
            }
            if let m = ws.mesh {
                Section("Mesh") {
                    LabeledContent("Cells", value: "\(m.nCells)")
                    LabeledContent("Dimension", value: m.isTwoDimensional ? "2D (one-cell slab)" : "3D")
                    Button("Check Mesh") { ws.selection = .meshInfo }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            Section("Viscous Model") {
                Picker("Model", selection: $ws.setup.models.viscous) {
                    ForEach(ViscousModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if ws.setup.models.viscous.usesEpsilon {
                    Picker("Near-wall treatment", selection: $ws.setup.models.wallTreatment) {
                        Text("Scalable / Automatic (Reichardt blend)").tag(WallTreatment.automatic)
                        Text("Standard Wall Functions").tag(WallTreatment.standardWallFunctions)
                    }
                }
                if ws.setup.models.viscous == .kOmegaSST {
                    Text("Menter 2003 SST with production limiter and y⁺-insensitive (blended) wall treatment.").font(.caption).foregroundStyle(.secondary)
                }
                if ws.setup.models.viscous.isTurbulent {
                    NumberField(label: "Turbulent Prandtl number", value: $ws.setup.models.turbulentPrandtl)
                }
            }
            Section("Energy") {
                Toggle("Energy equation", isOn: $ws.setup.models.energy)
            }
            Section("User-Defined Scalars (passive)") {
                // Rows are keyed by index and read values (never live bindings) when deleting:
                // removing an element while a binding into the same array is being read aborts.
                ForEach(Array(ws.setup.models.passiveScalars.enumerated()), id: \.offset) { i, sc in
                    let name = sc.name
                    HStack {
                        RenameField(label: "Name", name: name) { ws.renameScalar(name, to: $0) }
                        NumberField(label: "D", value: .element($ws.setup.models.passiveScalars, i, fallback: sc).diffusivity, unit: "m²/s")
                        Button(role: .destructive) { ws.removeScalar(named: name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(name)")
                    }
                }
                Button("Add Scalar") { ws.addScalar() }
                if !ws.setup.models.passiveScalars.isEmpty {
                    Text("Set inlet values under Boundary Conditions › UDS. Press Return to apply a new name.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("More models") {
                Text("Radiation (P-1, discrete ordinates), LES and DES, transition (k-ω SST LM) and Reynolds-stress models are set on the OpenFOAM page; periodic boundaries on Boundary Conditions. Not set up yet: multiphase, species transport and combustion, discrete phase, surface-to-surface and solar radiation, moving and overset meshes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MaterialsPage: View {
    @Bindable var ws: Workspace
    @State private var selected: String? = "air"
    @State private var addName = "water-liquid"

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Fluid") {
                    ForEach(ws.setup.materials.filter { $0.kind == .fluid }) { m in Label(m.name, systemImage: "drop").tag(m.name) }
                }
                Section("Solid") {
                    ForEach(ws.setup.materials.filter { $0.kind == .solid }) { m in Label(m.name, systemImage: "cube.fill").tag(m.name) }
                }
            }
            .frame(minHeight: 150, maxHeight: 220)
            HStack {
                Picker("", selection: $addName) {
                    ForEach(MaterialLibrary.all.filter { m in !ws.setup.materials.contains { $0.name == m.name } }) { m in
                        Text("\(m.name) (\(m.kind.rawValue))").tag(m.name)
                    }
                }
                .labelsHidden()
                Button("Copy from Library") {
                    if let m = MaterialLibrary.lookup(addName), !ws.setup.materials.contains(where: { $0.name == m.name }) {
                        ws.setup.materials.append(m); selected = m.name
                    }
                }
                Button("New") {
                    var m = FluidCraftSolver.Material(name: Workspace.uniqueName("material", existing: ws.setup.materials.map(\.name)))
                    m.kind = .fluid
                    ws.setup.materials.append(m); selected = m.name
                }
                Button("Delete") {
                    if let n = selected, ws.removeMaterial(named: n) { selected = ws.setup.materials.first?.name }
                }
                .disabled(selected == nil)
            }
            .padding(8)
            Divider()
            if let i = ws.setup.materials.firstIndex(where: { $0.name == selected }) {
                let current = ws.setup.materials[i]
                MaterialEditor(material: .element($ws.setup.materials, i, fallback: current)) { new in
                    guard ws.renameMaterial(current.name, to: new) else { return false }
                    selected = new
                    return true
                }
                .id(current.name)
            } else {
                Spacer()
            }
        }
    }
}

struct MaterialEditor: View {
    @Binding var material: FluidCraftSolver.Material
    var onRename: (String) -> Bool
    var body: some View {
        Form {
            Section("Material") {
                LabeledContent("Name") { RenameField(label: "", name: material.name, onCommit: onRename).frame(maxWidth: 200) }
                Picker("Type", selection: $material.kind) {
                    Text("Fluid").tag(CellZoneKind.fluid); Text("Solid").tag(CellZoneKind.solid)
                }
            }
            Section("Properties") {
                if material.kind == .fluid {
                    Picker("Density", selection: $material.densityMethod) {
                        Text("constant").tag(DensityMethod.constant)
                        Text("boussinesq").tag(DensityMethod.boussinesq)
                        Text("incompressible-ideal-gas").tag(DensityMethod.incompressibleIdealGas)
                        Text("ideal-gas (density-based solver)").tag(DensityMethod.idealGas)
                    }
                }
                if (material.densityMethod != .incompressibleIdealGas && material.densityMethod != .idealGas) || material.kind == .solid {
                    NumberField(label: "Density", value: $material.density, unit: "kg/m³")
                }
                if material.kind == .fluid {
                    Picker("Viscosity", selection: $material.viscosityMethod) {
                        ForEach(ViscosityMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    switch material.viscosityMethod {
                    case .constant: NumberField(label: "Viscosity", value: $material.viscosity, unit: "kg/m·s")
                    case .sutherland:
                        NumberField(label: "Reference viscosity", value: $material.viscosity, unit: "kg/m·s")
                        NumberField(label: "Reference temperature", value: $material.sutherlandT0, unit: "K")
                        NumberField(label: "Effective temperature S", value: $material.sutherlandS, unit: "K")
                    case .powerLaw:
                        NumberField(label: "Consistency index k", value: $material.powerLawK, unit: "kg·sⁿ⁻²/m")
                        NumberField(label: "Power-law index n", value: $material.powerLawN)
                        NumberField(label: "Minimum viscosity", value: $material.powerLawMin, unit: "kg/m·s")
                        NumberField(label: "Maximum viscosity", value: $material.powerLawMax, unit: "kg/m·s")
                    }
                }
                NumberField(label: "Cp (specific heat)", value: $material.specificHeat, unit: "J/kg·K")
                NumberField(label: "Thermal conductivity", value: $material.thermalConductivity, unit: "W/m·K")
                if material.kind == .solid {
                    Toggle("Orthotropic conductivity (kx, ky, kz)", isOn: Binding(
                        get: { material.anisotropicConductivity != nil },
                        set: { material.anisotropicConductivity = $0 ? Array(repeating: material.thermalConductivity, count: 3) : nil }))
                    if material.anisotropicConductivity != nil {
                        VectorField(label: "Conductivity along x, y, z", value: Binding(
                            get: { material.anisotropicConductivity ?? [] }, set: { material.anisotropicConductivity = $0 }), unit: "W/m·K")
                        Text("For laminates such as FR-4 circuit boards (high in-plane, low through the thickness). OpenFOAM: heSolidThermo constAnIso.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if material.kind == .fluid {
                    NumberField(label: "Thermal expansion coefficient", value: $material.thermalExpansion, unit: "1/K")
                    NumberField(label: "Molecular weight", value: $material.molecularWeight, unit: "kg/kmol")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CellZonesPage: View {
    @Bindable var ws: Workspace
    @State private var selected: String?
    var body: some View {
        if let mesh = ws.mesh {
            VStack(spacing: 0) {
                List(mesh.cellZones, id: \.name, selection: $selected) { z in
                    HStack {
                        Label(z.name, systemImage: ws.setup.cellZones[z.name]?.kind == .solid ? "cube.fill" : "drop")
                        Spacer()
                        Text("\(z.cellCount) cells").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .frame(minHeight: 90, maxHeight: 160)
                Divider()
                if let name = selected ?? mesh.cellZones.first?.name, ws.setup.cellZones[name] != nil {
                    CellZoneEditor(ws: ws, name: name)
                }
            }
            .onAppear { if selected == nil { selected = mesh.cellZones.first?.name } }
        } else { NoMeshNotice() }
    }
}

struct CellZoneEditor: View {
    @Bindable var ws: Workspace
    var name: String
    var binding: Binding<CellZoneSettings> {
        Binding(get: { ws.setup.cellZones[name] ?? CellZoneSettings() }, set: { ws.setup.cellZones[name] = $0 })
    }
    var body: some View {
        let z = binding
        Form {
            Section(name) {
                Picker("Type", selection: z.kind) { Text("Fluid").tag(CellZoneKind.fluid); Text("Solid").tag(CellZoneKind.solid) }
                Picker("Material", selection: z.material) {
                    ForEach(ws.setup.materials.filter { $0.kind == z.wrappedValue.kind }) { Text($0.name).tag($0.name) }
                }
            }
            if z.wrappedValue.kind == .fluid {
                Section("Porous Zone") {
                    Toggle("Porous zone", isOn: Binding(get: { z.wrappedValue.porous != nil }, set: { z.wrappedValue.porous = $0 ? PorousSettings() : nil }))
                    if z.wrappedValue.porous != nil {
                        VectorField(label: "Viscous resistance (1/α)", value: Binding(get: { z.wrappedValue.porous!.viscousResistance }, set: { z.wrappedValue.porous!.viscousResistance = $0 }), unit: "1/m²")
                        VectorField(label: "Inertial resistance (C₂)", value: Binding(get: { z.wrappedValue.porous!.inertialResistance }, set: { z.wrappedValue.porous!.inertialResistance = $0 }), unit: "1/m")
                    }
                }
                Section("Frame Motion (MRF)") {
                    Toggle("Moving reference frame", isOn: z.frameMotion)
                    if z.wrappedValue.frameMotion {
                        NumberField(label: "Rotational velocity", value: z.rotationSpeed, unit: "rad/s")
                        VectorField(label: "Rotation axis origin", value: z.rotationAxisOrigin, unit: "m")
                        VectorField(label: "Rotation axis direction", value: z.rotationAxisDirection)
                    }
                }
                Section("Actuator Disk (wind turbine)") {
                    Toggle("Actuator disk", isOn: Binding(get: { z.wrappedValue.actuatorDisk != nil }, set: { z.wrappedValue.actuatorDisk = $0 ? ActuatorDisk() : nil }))
                    if z.wrappedValue.actuatorDisk != nil {
                        let d = Binding(get: { z.wrappedValue.actuatorDisk ?? ActuatorDisk() }, set: { z.wrappedValue.actuatorDisk = $0 })
                        VectorField(label: "Thrust direction (downstream)", value: d.direction)
                        NumberField(label: "Thrust coefficient Ct", value: d.thrustCoefficient)
                        NumberField(label: "Power coefficient Cp", value: d.powerCoefficient)
                        NumberField(label: "Rotor area", value: d.diskArea, unit: "m²")
                        NumberField(label: "Reference wind speed", value: d.referenceVelocity, unit: "m/s")
                        VectorField(label: "Upstream monitor point", value: d.upstreamPoint, unit: "m")
                        Text("Thrust T = ½ρA·Ct·U² spread over the zone's cells. FluidCraft uses the reference speed; OpenFOAM (actuationDiskSource, Froude) samples the wind at the monitor point.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Source Terms") {
                    QuantityVectorField(label: "Momentum source", value: z.momentumSource, unit: "N/m³")
                }
            }
            Section("Energy") {
                QuantityField(label: "Energy source", value: z.energySource, unit: "W/m³")
            }
        }
        .formStyle(.grouped)
    }
}

struct BoundariesPage: View {
    @Bindable var ws: Workspace
    @State private var selected: String?
    var body: some View {
        if let mesh = ws.mesh {
            VStack(spacing: 0) {
                List(mesh.boundaryZones.filter { $0.kind != .empty }, id: \.name, selection: $selected) { z in
                    HStack {
                        Text(z.name).lineLimit(1)
                        Spacer()
                        Text(ws.setup.boundaries[z.name]?.type.displayName ?? z.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
                Divider()
                if let name = selected, ws.setup.boundaries[name] != nil {
                    BoundaryEditor(ws: ws, name: name)
                } else {
                    ContentUnavailableView("Select a Zone", systemImage: "square.dashed", description: Text("Choose a boundary zone to edit its condition."))
                }
            }
            .onAppear { if selected == nil { selected = mesh.boundaryZones.first { $0.kind != .empty }?.name } }
        } else { NoMeshNotice() }
    }
}

struct BoundaryEditor: View {
    @Bindable var ws: Workspace
    var name: String
    @State private var tab = 0
    var b: Binding<BoundarySettings> {
        Binding(get: { ws.setup.boundaries[name] ?? BoundarySettings(type: .wall) }, set: { ws.setup.boundaries[name] = $0 })
    }
    var body: some View {
        let bc = b
        let t = bc.wrappedValue.type
        let turbulent = ws.setup.models.viscous.isTurbulent
        Form {
            Section(name) {
                Picker("Type", selection: bc.type) {
                    ForEach(ZoneKind.userSelectable, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("", selection: $tab) {
                    Text("Momentum").tag(0)
                    Text("Thermal").tag(1)
                    if turbulent && t != .wall && t != .symmetry { Text("Turbulence").tag(2) }
                    if !ws.setup.models.passiveScalars.isEmpty { Text("UDS").tag(3) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if tab == 0 {
                PeriodicSection(ws: ws, name: name, bc: bc)
                Section("Momentum") {
                    switch t {
                    case .velocityInlet:
                        Picker("Velocity specification", selection: bc.velocitySpecification) {
                            Text("Magnitude, normal to boundary").tag(VelocitySpecification.magnitudeNormal)
                            Text("Components").tag(VelocitySpecification.components)
                        }
                        Toggle("Atmospheric boundary layer (log-law wind profile)", isOn: Binding(
                            get: { bc.wrappedValue.atmosphericBoundaryLayer != nil },
                            set: { bc.wrappedValue.atmosphericBoundaryLayer = $0 ? ABLProfile() : nil }))
                        if bc.wrappedValue.atmosphericBoundaryLayer != nil {
                            let abl = Binding(get: { bc.wrappedValue.atmosphericBoundaryLayer ?? ABLProfile() }, set: { bc.wrappedValue.atmosphericBoundaryLayer = $0 })
                            NumberField(label: "Reference wind speed", value: abl.referenceVelocity, unit: "m/s")
                            NumberField(label: "Reference height", value: abl.referenceHeight, unit: "m")
                            NumberField(label: "Roughness length z₀", value: abl.roughnessLength, unit: "m")
                            NumberField(label: "Ground level (displacement)", value: abl.displacement, unit: "m")
                            VectorField(label: "Wind direction", value: abl.flowDirection)
                            VectorField(label: "Up direction", value: abl.verticalDirection)
                            Text("Richards–Hoxey neutral profile: U = u*/κ ln((z+z₀)/z₀), with matching k and ε (or ω). OpenFOAM: atmBoundaryLayerInlet* conditions.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if bc.wrappedValue.velocitySpecification == .magnitudeNormal {
                            QuantityField(label: "Velocity magnitude", value: bc.velocityMagnitude, unit: "m/s")
                        } else {
                            QuantityVectorField(label: "Velocity", value: bc.velocity, unit: "m/s")
                        }
                    case .massFlowInlet:
                        QuantityField(label: "Mass flow rate", value: bc.massFlowRate, unit: "kg/s")
                    case .pressureInlet:
                        QuantityField(label: "Gauge total pressure", value: bc.gaugePressure, unit: "Pa")
                        if ws.setup.general.solver == .densityBased {
                            NumberField(label: "Inlet Mach number (> 1: supersonic)", value: bc.machNumber)
                        }
                    case .pressureOutlet:
                        QuantityField(label: "Gauge pressure", value: bc.gaugePressure, unit: "Pa")
                        Text("Backflow enters normal to the boundary.").font(.caption).foregroundStyle(.secondary)
                    case .wall:
                        Picker("Wall motion", selection: bc.wallMotion) {
                            Text("Stationary").tag(WallMotion.stationary); Text("Moving (translational)").tag(WallMotion.moving); Text("Rotating").tag(WallMotion.rotating)
                        }
                        if bc.wrappedValue.wallMotion == .moving { QuantityVectorField(label: "Wall velocity", value: bc.wallVelocity, unit: "m/s") }
                        if bc.wrappedValue.wallMotion == .rotating {
                            NumberField(label: "Speed", value: bc.rotationSpeed, unit: "rad/s")
                            VectorField(label: "Axis origin", value: bc.rotationAxisOrigin, unit: "m")
                            VectorField(label: "Axis direction", value: bc.rotationAxisDirection)
                        }
                        Picker("Shear condition", selection: bc.shearCondition) {
                            Text("No Slip").tag(ShearCondition.noSlip); Text("Specified Shear (zero)").tag(ShearCondition.specifiedShear)
                        }
                        NumberField(label: "Aerodynamic roughness z₀ (0 = smooth)", value: bc.roughnessLength, unit: "m")
                        if bc.wrappedValue.roughnessLength > 0 {
                            Text("Rough terrain, used by OpenFOAM's atmNutkWallFunction (k-ε / k-ω cases).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .pressureFarField:
                        QuantityField(label: "Gauge pressure", value: bc.gaugePressure, unit: "Pa")
                        if ws.setup.general.solver == .densityBased {
                            NumberField(label: "Mach number", value: bc.machNumber)
                        } else {
                            QuantityField(label: "Free-stream speed", value: bc.velocityMagnitude, unit: "m/s")
                        }
                        VectorField(label: "Flow direction", value: bc.flowDirection)
                    case .outflow:
                        Text("Zero normal diffusive flux; mass flow balanced to the inflow.").font(.caption).foregroundStyle(.secondary)
                    case .symmetry:
                        Text("Zero normal velocity and zero normal gradients.").font(.caption).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                }
            } else if tab == 1 {
                Section("Thermal") {
                    if !ws.setup.models.energy {
                        Text("Enable the energy equation under Models to use thermal conditions.").font(.caption).foregroundStyle(.secondary)
                    }
                    if t == .wall {
                        Picker("Thermal condition", selection: bc.thermalCondition) {
                            Text("Adiabatic").tag(ThermalCondition.adiabatic)
                            Text("Heat Flux").tag(ThermalCondition.heatFlux)
                            Text("Temperature").tag(ThermalCondition.temperature)
                            Text("Convection").tag(ThermalCondition.convection)
                        }
                        switch bc.wrappedValue.thermalCondition {
                        case .temperature: QuantityField(label: "Temperature", value: bc.temperature, unit: "K")
                        case .heatFlux: QuantityField(label: "Heat flux", value: bc.heatFlux, unit: "W/m²")
                        case .convection:
                            QuantityField(label: "Heat transfer coefficient", value: bc.heatTransferCoefficient, unit: "W/m²·K")
                            QuantityField(label: "Free-stream temperature", value: bc.freeStreamTemperature, unit: "K")
                        case .adiabatic: EmptyView()
                        }
                    } else if t == .symmetry {
                        Text("Zero heat flux.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        QuantityField(label: t == .pressureOutlet || t == .outflow ? "Backflow temperature" : "Temperature", value: bc.temperature, unit: "K")
                    }
                }
            } else if tab == 2 {
                Section("Turbulence") {
                    Picker("Specification", selection: bc.turbulenceSpecification) {
                        Text("Intensity and Viscosity Ratio").tag(TurbulenceSpecification.intensityAndViscosityRatio)
                        Text("Intensity and Length Scale").tag(TurbulenceSpecification.intensityAndLengthScale)
                        Text("Intensity and Hydraulic Diameter").tag(TurbulenceSpecification.intensityAndHydraulicDiameter)
                        Text(ws.setup.models.viscous == .spalartAllmaras ? "Modified Turbulent Viscosity" : (ws.setup.models.viscous.usesOmega ? "K and Omega" : "K and Epsilon")).tag(TurbulenceSpecification.direct)
                    }
                    switch bc.wrappedValue.turbulenceSpecification {
                    case .intensityAndViscosityRatio:
                        NumberField(label: "Turbulent intensity", value: Binding(get: { bc.wrappedValue.turbulentIntensity * 100 }, set: { bc.wrappedValue.turbulentIntensity = $0 / 100 }), unit: "%")
                        NumberField(label: "Turbulent viscosity ratio", value: bc.turbulentViscosityRatio)
                    case .intensityAndLengthScale:
                        NumberField(label: "Turbulent intensity", value: Binding(get: { bc.wrappedValue.turbulentIntensity * 100 }, set: { bc.wrappedValue.turbulentIntensity = $0 / 100 }), unit: "%")
                        NumberField(label: "Turbulent length scale", value: bc.turbulentLengthScale, unit: "m")
                    case .intensityAndHydraulicDiameter:
                        NumberField(label: "Turbulent intensity", value: Binding(get: { bc.wrappedValue.turbulentIntensity * 100 }, set: { bc.wrappedValue.turbulentIntensity = $0 / 100 }), unit: "%")
                        NumberField(label: "Hydraulic diameter", value: bc.hydraulicDiameter, unit: "m")
                    case .direct:
                        if ws.setup.models.viscous == .spalartAllmaras {
                            NumberField(label: "Modified turbulent viscosity", value: bc.modifiedTurbulentViscosity, unit: "m²/s")
                        } else {
                            NumberField(label: "Turbulent kinetic energy", value: bc.k, unit: "m²/s²")
                            if ws.setup.models.viscous.usesOmega { NumberField(label: "Specific dissipation rate", value: bc.omega, unit: "1/s") }
                            else { NumberField(label: "Turbulent dissipation rate", value: bc.epsilon, unit: "m²/s³") }
                        }
                    }
                }
            } else {
                Section("User-Defined Scalars") {
                    ForEach(ws.setup.models.passiveScalars) { sc in
                        NumberField(label: sc.name, value: Binding(get: { bc.wrappedValue.scalars[sc.name] ?? 0 }, set: { bc.wrappedValue.scalars[sc.name] = $0 }))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ExpressionsPage: View {
    @Bindable var ws: Workspace
    @State private var testResult = ""
    var body: some View {
        Form {
            Section {
                ForEach(Array(ws.setup.expressions.enumerated()), id: \.offset) { i, e in
                    let name = e.name
                    HStack {
                        RenameField(label: "Name", name: name) { ws.renameExpression(name, to: $0) }.frame(width: 110)
                        TextField("Definition", text: Binding<NamedExpression>.element($ws.setup.expressions, i, fallback: e).definition)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Button(role: .destructive) { ws.setup.expressions.removeAll { $0.name == name } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("New Expression") {
                    let n = Workspace.uniqueName("expr", existing: ws.setup.expressions.map(\.name)).replacingOccurrences(of: "-", with: "")
                    ws.setup.expressions.append(NamedExpression(name: n, definition: "1 [m/s]"))
                }
            } header: {
                Text("Named Expressions")
            } footer: {
                Text("Use x, y, z, t, other names, + − × ÷ ^, sin cos exp log sqrt abs min max if(c,a,b). Units in [brackets] are documentation only (SI). Use names in any boundary or source field.")
            }
            Section("Check") {
                Button("Validate All") {
                    do {
                        let d = try Expr.compileNamed(ws.setup.expressions.map { ($0.name, $0.definition) })
                        testResult = d.keys.sorted().map { "\($0) = \(Quantity.format(d[$0]!.value()))  (at x=y=z=t=0)" }.joined(separator: "\n")
                        if testResult.isEmpty { testResult = "No expressions." }
                    } catch { testResult = "\(error)" }
                }
                if !testResult.isEmpty { Text(testResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ReferenceValuesPage: View {
    @Bindable var ws: Workspace
    @State private var fromZone = ""
    var body: some View {
        Form {
            Section("Reference Values (coefficients)") {
                NumberField(label: "Area", value: $ws.setup.reference.area, unit: "m²")
                NumberField(label: "Length", value: $ws.setup.reference.length, unit: "m")
                NumberField(label: "Velocity", value: $ws.setup.reference.velocity, unit: "m/s")
                NumberField(label: "Density", value: $ws.setup.reference.density, unit: "kg/m³")
                NumberField(label: "Pressure", value: $ws.setup.reference.pressure, unit: "Pa")
                NumberField(label: "Temperature", value: $ws.setup.reference.temperature, unit: "K")
                NumberField(label: "Viscosity", value: $ws.setup.reference.viscosity, unit: "kg/m·s")
            }
            if let m = ws.mesh {
                Section("Compute From") {
                    Picker("Zone", selection: $fromZone) {
                        Text("—").tag("")
                        ForEach(m.boundaryZones.filter { [.velocityInlet, .massFlowInlet, .pressureFarField].contains($0.kind) }, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Button("Compute") { computeFrom() }.disabled(fromZone.isEmpty)
                }
                if m.isTwoDimensional, let ax = m.twoDimensionalAxis {
                    Text("2D: forces are per slab depth of \(Quantity.format(m.bounds.size[ax])) m — set the reference area to chord × depth.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
    func computeFrom() {
        guard let b = ws.setup.boundaries[fromZone] else { return }
        if let v = b.velocityMagnitude.constantValue { ws.setup.reference.velocity = v }
        if b.velocitySpecification == .components {
            let comps = b.velocity.compactMap(\.constantValue)
            if comps.count == 3 { ws.setup.reference.velocity = sqrt(comps.map { $0 * $0 }.reduce(0, +)) }
        }
        if let zn = ws.mesh?.cellZones.first?.name, let mat = ws.setup.material(named: ws.setup.cellZones[zn]?.material ?? "") {
            ws.setup.reference.density = mat.density
            ws.setup.reference.viscosity = mat.viscosity
        }
        if let t = b.temperature.constantValue { ws.setup.reference.temperature = t }
    }
}


/// Periodic pairing of a patch (OpenFOAM cyclicAMI).
struct PeriodicSection: View {
    @Bindable var ws: Workspace
    let name: String
    let bc: Binding<BoundarySettings>
    var partnerOfOther: String? {
        ws.setup.boundaries.first { $0.value.periodic?.partner == name }?.key
    }
    var body: some View {
        Section("Periodic (OpenFOAM cyclicAMI)") {
            if let other = partnerOfOther {
                Text("Periodic partner of \(other); its settings define the pair.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Periodic with", selection: Binding(
                    get: { bc.wrappedValue.periodic?.partner ?? "" },
                    set: { p in bc.wrappedValue.periodic = p.isEmpty ? nil : (bc.wrappedValue.periodic.map { var l = $0; l.partner = p; return l } ?? PeriodicLink(partner: p)) })) {
                    Text("Not periodic").tag("")
                    ForEach((ws.mesh?.boundaryZones ?? []).filter { $0.name != name && $0.kind != .empty }.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                if bc.wrappedValue.periodic != nil {
                    let l = Binding(get: { bc.wrappedValue.periodic ?? PeriodicLink() }, set: { bc.wrappedValue.periodic = $0 })
                    Picker("Transform", selection: l.rotational) { Text("Translation").tag(false); Text("Rotation").tag(true) }.pickerStyle(.segmented)
                    if l.wrappedValue.rotational {
                        VectorField(label: "Rotation axis", value: l.axis)
                        VectorField(label: "Rotation centre", value: l.centre, unit: "m")
                        NumberField(label: "Angle onto the partner", value: l.angle, unit: "°")
                    } else {
                        Toggle("Translation from the patch centroids", isOn: Binding(get: { l.wrappedValue.separation == nil },
                                                                                   set: { l.wrappedValue.separation = $0 ? nil : [0, 0, 0] }))
                        if l.wrappedValue.separation != nil {
                            VectorField(label: "Translation onto the partner", value: Binding(get: { l.wrappedValue.separation ?? [0, 0, 0] }, set: { l.wrappedValue.separation = $0 }), unit: "m")
                        }
                    }
                    Text("Both patches become a cyclicAMI pair (matching or non-matching faces). A closed periodic flow needs a driving force: OpenFOAM page › Baffles and Periodic Flow › Mean velocity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
