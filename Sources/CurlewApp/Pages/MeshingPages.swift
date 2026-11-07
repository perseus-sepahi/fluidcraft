import SwiftUI
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver
import CurlewFoam

struct MeshGenerationPage: View {
    @Bindable var ws: Workspace
    @State private var method = 0
    // block
    @State private var bx = [0.0, 1.0]
    @State private var by = [0.0, 1.0]
    @State private var bz = [0.0, 1.0]
    @State private var nx = 40
    @State private var ny = 40
    @State private var nz = 20
    @State private var gx = 1.0
    @State private var gy = 1.0
    @State private var gz = 1.0
    @State private var threeD = false
    @State private var depth = 0.1
    @State private var sideKinds: [String: ZoneKind] = ["x-min": .velocityInlet, "x-max": .pressureOutlet, "y-min": .wall, "y-max": .wall, "z-min": .wall, "z-max": .wall]
    @State private var obstacle = false
    @State private var obs = [0.4, 0.4, 0.0, 0.6, 0.6, 1.0]
    // O-grid
    @State private var ogR = 0.5
    @State private var ogRo = 20.0
    @State private var ogNr = 80
    @State private var ogNt = 128
    @State private var ogG = 60.0
    // gmsh
    @State private var gm = MeshingSettings(template: .channelCylinder(length: 2.2, height: 0.41, cx: 0.2, cy: 0.2, radius: 0.05))
    @State private var gmTemplate = 0
    @State private var nacaCode = "0012"
    @State private var ffR = 30.0
    @State private var pipeL = 0.5
    @State private var pipeD = 0.05
    @State private var cadPath = ""
    @State private var cadExternal = true
    @State private var cadAxis = 0
    @State private var ch = [2.2, 0.41, 0.2, 0.2, 0.05]
    @State private var cadMesher = 0          // 0 Gmsh, 1 snappyHexMesh
    @State private var snappy = SnappySettings()

    var body: some View {
        Form {
            Section("Generate a Mesh") {
                Picker("Method", selection: $method) {
                    Text("Block (structured, Cartesian)").tag(0)
                    Text("Cylinder O-grid (2D)").tag(1)
                    Text("Gmsh templates").tag(2)
                    Text("CAD geometry, mesh only (STEP, IGES, STL, OBJ, …)").tag(3)
                }
            }
            switch method {
            case 0: blockSection
            case 1: ogridSection
            case 2: gmshSection
            default: cadSection
            }
            Section("Import") {
                Button("Import Mesh File…") { importMesh() }
                Text("Fluent .msh/.cas (ASCII or binary), Gmsh .msh (v2.2/v4.1), OpenFOAM polyMesh directory. CAD files: choose CAD geometry above.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var blockSection: some View {
        Group {
            Section("Domain") {
                Toggle("3D", isOn: $threeD)
                axisRow("x", $bx, $nx, $gx)
                axisRow("y", $by, $ny, $gy)
                if threeD { axisRow("z", $bz, $nz, $gz) } else { NumberField(label: "Slab depth", value: $depth, unit: "m") }
            }
            Section("Boundary types") {
                ForEach(threeD ? ["x-min", "x-max", "y-min", "y-max", "z-min", "z-max"] : ["x-min", "x-max", "y-min", "y-max"], id: \.self) { side in
                    Picker(side, selection: Binding(get: { sideKinds[side] ?? .wall }, set: { sideKinds[side] = $0 })) {
                        ForEach(ZoneKind.userSelectable, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            Section("Obstacle") {
                Toggle("Rectangular obstacle (wall)", isOn: $obstacle)
                if obstacle {
                    TextField("xmin ymin zmin xmax ymax zmax", text: Binding(get: { obs.map { Quantity.format($0) }.joined(separator: " ") },
                                                                              set: { obs = $0.split(separator: " ").compactMap { Double($0) } }))
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
            }
            Section {
                Button("Generate Block Mesh") {
                    var spec = BlockMeshSpec(x: BlockAxis(from: bx[0], to: bx[1], cells: nx, grading: gx),
                                             y: BlockAxis(from: by[0], to: by[1], cells: ny, grading: gy),
                                             z: threeD ? BlockAxis(from: bz[0], to: bz[1], cells: nz, grading: gz) : nil,
                                             depth: depth, sideKinds: sideKinds)
                    if obstacle && obs.count == 6 { spec.obstacles = [obs] }
                    ws.buildBlockMesh(spec)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    func axisRow(_ n: String, _ r: Binding<[Double]>, _ c: Binding<Int>, _ g: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                NumberField(label: "\(n) from", value: Binding(get: { r.wrappedValue[0] }, set: { r.wrappedValue[0] = $0 }))
                NumberField(label: "to", value: Binding(get: { r.wrappedValue[1] }, set: { r.wrappedValue[1] = $0 }))
            }
            HStack {
                IntField(label: "cells", value: c)
                NumberField(label: "grading", value: g)
            }
        }
    }

    var ogridSection: some View {
        Section("O-grid around a cylinder") {
            NumberField(label: "Cylinder radius", value: $ogR, unit: "m")
            NumberField(label: "Outer radius", value: $ogRo, unit: "m")
            IntField(label: "Radial cells", value: $ogNr)
            IntField(label: "Circumferential cells", value: $ogNt)
            NumberField(label: "Radial grading", value: $ogG)
            Button("Generate O-grid") {
                do { ws.setMesh(try CylinderOGridSpec(radius: ogR, outerRadius: ogRo, radialCells: ogNr, circumferentialCells: ogNt, radialGrading: ogG).build(), source: "O-grid") }
                catch { ws.log("\(error)", .error) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var sizingFields: some View {
        Group {
            NumberField(label: "Maximum size", value: $gm.maxSize, unit: "m")
            NumberField(label: "Wall size", value: $gm.wallSize, unit: "m")
            NumberField(label: "Growth distance", value: $gm.growthDistance, unit: "m")
        }
    }

    var gmshSection: some View {
        Group {
            Section("Gmsh Template") {
                if !GmshDriver.isAvailable { Label("Gmsh.app not found in /Applications", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Picker("Geometry", selection: $gmTemplate) {
                    Text("2D channel with cylinder").tag(0)
                    Text("2D NACA 4-digit airfoil").tag(1)
                    Text("3D pipe").tag(2)
                }
                switch gmTemplate {
                case 0:
                    NumberField(label: "Channel length", value: $ch[0], unit: "m")
                    NumberField(label: "Channel height", value: $ch[1], unit: "m")
                    NumberField(label: "Cylinder centre x", value: $ch[2], unit: "m")
                    NumberField(label: "Cylinder centre y", value: $ch[3], unit: "m")
                    NumberField(label: "Cylinder radius", value: $ch[4], unit: "m")
                case 1:
                    TextField("NACA code", text: $nacaCode).textFieldStyle(.roundedBorder)
                    NumberField(label: "Far-field radius (chords)", value: $ffR)
                default:
                    NumberField(label: "Length", value: $pipeL, unit: "m")
                    NumberField(label: "Diameter", value: $pipeD, unit: "m")
                }
            }
            Section("Sizing") {
                sizingFields
                if gmTemplate == 2 {
                    InflationFields(ws: ws, gm: $gm, referenceLength: pipeD)
                } else {
                    Toggle("Quad-dominant", isOn: $gm.quads)
                    NumberField(label: "Boundary layer first height (0 = off)", value: $gm.blFirstHeight, unit: "m")
                    NumberField(label: "Boundary layer growth", value: $gm.blGrowth)
                    NumberField(label: "Boundary layer thickness", value: $gm.blThickness, unit: "m")
                }
            }
            Section {
                Button(ws.isMeshing ? "Meshing…" : "Generate with Gmsh") {
                    var s = gm
                    switch gmTemplate {
                    case 0: s.template = .channelCylinder(length: ch[0], height: ch[1], cx: ch[2], cy: ch[3], radius: ch[4])
                    case 1: s.template = .naca4(code: nacaCode, farfieldRadius: ffR)
                    default: s.template = .pipe(length: pipeL, diameter: pipeD)
                    }
                    ws.generateMesh(s)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ws.isMeshing || !GmshDriver.isAvailable)
                Button("Show Gmsh Script") {
                    var s = gm
                    switch gmTemplate {
                    case 0: s.template = .channelCylinder(length: ch[0], height: ch[1], cx: ch[2], cy: ch[3], radius: ch[4])
                    case 1: s.template = .naca4(code: nacaCode, farfieldRadius: ffR)
                    default: s.template = .pipe(length: pipeL, diameter: pipeD)
                    }
                    if let g = try? GmshDriver.script(s) { ws.log(g.geo) }
                }
            }
        }
    }

    var cadSection: some View {
        Group {
            Section("CAD Geometry") {
                HStack {
                    Text(cadPath.isEmpty ? "No file" : (cadPath as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = CADFormat.extensions.compactMap { UTType(filenameExtension: $0) }
                        p.message = "STEP, IGES, BREP, FreeCAD (exact CAD); STL, OBJ, PLY, OFF, 3MF, glTF, AMF, VTK (triangulated); native SolidWorks/CATIA/Parasolid/… with a converter (Settings)"
                        if p.runModal() == .OK, let u = p.url { cadPath = u.path; guessUnit() }
                    }
                }
                if let f = CADFormat.detect(URL(fileURLWithPath: cadPath)) {
                    LabeledContent("Format", value: f.displayName + (f.isBRep ? " — exact geometry (OpenCASCADE)" : " — triangulated surface"))
                }
                Picker("File units", selection: $gm.cadUnit) {
                    ForEach(CADUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(CADFormat.detect(URL(fileURLWithPath: cadPath)) == .threeMF)
                Picker("Flow type", selection: $cadExternal) {
                    Text("External flow around the body (box enclosure)").tag(true)
                    Text("Internal flow (body is the fluid volume)").tag(false)
                }
                Picker("Flow direction", selection: $cadAxis) { Text("+x").tag(0); Text("+y").tag(1); Text("+z").tag(2) }.pickerStyle(.segmented)
                Picker("Mesher", selection: $cadMesher) {
                    Text("Gmsh — tetrahedra + prism layers").tag(0)
                    Text("snappyHexMesh — hex-dominant (OpenFOAM)").tag(1)
                }
                Text(cadExternal
                     ? "Named selections are created automatically: inlet/outlet on the box faces along the flow direction, farfield on the other box faces, and the body's own regions (STL solids, OBJ groups, 3MF/glTF objects) as walls."
                     : "Openings are found automatically: every flat cap at the ends of the flow direction is an inlet or outlet, and smaller caps on the other sides (an elbow's exit, a tee's branch) are extra outlets (outlet_ymax, …) you can retype under Boundary Conditions. Surfaces already named inlet/outlet in the file are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if cadMesher == 0 {
                Section("Sizing (Gmsh)") {
                    sizingFields
                    if let f = CADFormat.detect(URL(fileURLWithPath: cadPath)), !f.isBRep {
                        NumberField(label: "Feature angle (patch split)", value: $gm.featureAngle, unit: "°")
                    }
                    InflationFields(ws: ws, gm: $gm, referenceLength: 1)
                }
                Section {
                    Button(ws.isMeshing ? "Meshing…" : "Mesh Geometry with Gmsh") {
                        var s = gm
                        s.template = .cad(path: cadPath, external: cadExternal, flowAxis: cadAxis, padding: [3, 8, 3, 3, 3, 3])
                        ws.generateMesh(s)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cadPath.isEmpty || ws.isMeshing || !GmshDriver.isAvailable)
                }
            } else {
                SnappySettingsSection(snappy: $snappy, external: cadExternal)
                Section {
                    if ws.foamInstallations.isEmpty { Label("No OpenFOAM installation found (OpenFOAM page › Installation).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Button(ws.isMeshing ? "Meshing…" : "Mesh Geometry with snappyHexMesh") {
                        var s = snappy
                        s.path = cadPath; s.unit = gm.cadUnit; s.external = cadExternal; s.flowAxis = cadAxis
                        ws.meshWithSnappy(s)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cadPath.isEmpty || ws.isMeshing || ws.isRunning)
                    Text("Runs surfaceFeatureExtract, blockMesh, snappyHexMesh (castellate, snap, layers) and checkMesh in \(ws.foamCaseDirectory.deletingLastPathComponent().path), then imports the polyMesh. STEP/IGES/BREP are tessellated with Gmsh first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Large numbers in a CAD file usually mean millimetres.
    func guessUnit() {
        guard let f = CADFormat.detect(URL(fileURLWithPath: cadPath)), !f.isBRep, f != .threeMF,
              let surf = try? SurfaceReader.read(url: URL(fileURLWithPath: cadPath)) else { return }
        let (lo, hi) = surf.bounds
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        if size > 50 { gm.cadUnit = .millimetre; ws.log("\((cadPath as NSString).lastPathComponent): \(surf.triangleCount) triangles, size \(NumberField.format(size)) — assuming millimetres (change File units if not).") }
        else { ws.log("\((cadPath as NSString).lastPathComponent): \(surf.triangleCount) triangles in \(surf.regionNames.count) region(s): \(surf.regionNames.joined(separator: ", ")); size \(NumberField.format(size)).") }
        let open = surf.openOrNonManifoldEdges
        if open > 0 { ws.log("  \(open) open or non-manifold edges — the surface is not watertight.", .warning) }
        if !cadExternal {
            let ops = surf.detectOpenings(flowAxis: cadAxis)
            ws.log("  openings for internal flow: " + (ops.isEmpty ? "none found (flat caps on the bounding box)" : ops.map { String(format: "%@ (%.3g m²)", $0.name as NSString, $0.area) }.joined(separator: ", ")))
        }
    }

    func importMesh() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowedContentTypes = ["msh", "cas", "crlmesh"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        p.message = "Choose a Fluent/Gmsh .msh file or an OpenFOAM case directory"
        if p.runModal() == .OK, let u = p.url { ws.importMesh(url: u) }
    }
}

struct MeshInfoPage: View {
    @Bindable var ws: Workspace
    @State private var scale = 1.0
    var body: some View {
        Form {
            if let m = ws.mesh, let q = ws.meshQuality {
                Section("Mesh") {
                    LabeledContent("Source", value: ws.meshSource)
                    LabeledContent("Cells", value: "\(m.nCells)")
                    LabeledContent("Faces", value: "\(m.nFaces)")
                    LabeledContent("Nodes", value: "\(m.nPoints)")
                    LabeledContent("Dimension", value: m.isTwoDimensional ? "2D slab" : "3D")
                    ForEach(m.cellShapeHistogram().sorted { $0.key < $1.key }, id: \.key) { k, v in LabeledContent(k, value: "\(v)") }
                }
                Section("Quality") {
                    LabeledContent("Minimum orthogonal quality") { Text(String(format: "%.4f", q.minOrthogonalQuality)).foregroundStyle(q.minOrthogonalQuality < 0.1 ? .red : .primary) }
                    LabeledContent("Mean orthogonal quality", value: String(format: "%.4f", q.meanOrthogonalQuality))
                    LabeledContent("Maximum aspect ratio", value: String(format: "%.4g", q.maxAspectRatio))
                    LabeledContent("Max non-orthogonality", value: String(format: "%.2f°", q.maxNonOrthogonality))
                    LabeledContent("Minimum volume", value: String(format: "%.4e m³", q.minVolume))
                    LabeledContent("Total volume", value: String(format: "%.6g m³", q.totalVolume))
                    if q.negativeVolumes > 0 { Label("\(q.negativeVolumes) negative volumes", systemImage: "xmark.octagon").foregroundStyle(.red) }
                    Button("Report Quality to Console") { ws.log(q.text) }
                }
                Section("Boundary Zones") {
                    ForEach(Array(m.boundaryZones.enumerated()), id: \.element.id) { i, z in
                        if z.kind != .empty {
                            ZoneRow(ws: ws, index: i)
                        }
                    }
                }
                Section("Domain extents") {
                    Text(String(format: "x [%.5g, %.5g]\ny [%.5g, %.5g]\nz [%.5g, %.5g]", q.bounds.min.x, q.bounds.max.x, q.bounds.min.y, q.bounds.max.y, q.bounds.min.z, q.bounds.max.z))
                        .font(.system(.caption, design: .monospaced))
                }
            } else { NoMeshNotice() }
        }
        .formStyle(.grouped)
    }
}

struct ZoneRow: View {
    @Bindable var ws: Workspace
    var index: Int
    @State private var name = ""
    var body: some View {
        if let m = ws.mesh {
            let z = m.boundaryZones[index]
            HStack {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                    .onSubmit { rename(m, z) }
                Picker("", selection: Binding(get: { ws.setup.boundaries[z.name]?.type ?? z.kind }, set: { k in
                    if ws.meshEditingBlocked { return }
                    var b = ws.setup.boundaries[z.name] ?? BoundarySettings(type: k)
                    b.type = k
                    ws.setup.boundaries[z.name] = b
                    m.updateBoundaryZone(index, kind: k)
                })) {
                    ForEach(ZoneKind.userSelectable, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                Text("\(z.count)").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            }
            .onAppear { name = z.name }
        }
    }
    func rename(_ m: Mesh, _ z: BoundaryZone) {
        if ws.meshEditingBlocked { name = z.name; return }
        let new = name.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != z.name, !m.boundaryZones.contains(where: { $0.name == new }) else { name = z.name; return }
        let settings = ws.setup.boundaries.removeValue(forKey: z.name)
        m.updateBoundaryZone(index, name: new)
        ws.setup.boundaries[new] = settings ?? BoundarySettings(type: z.kind)
        ws.solver = nil; ws.post = nil; ws.initialized = false
        ws.log("Renamed zone \(z.name) → \(new)")
    }
}


/// 3D prism-layer (inflation) controls with a first-cell-height calculator.
struct InflationFields: View {
    var ws: Workspace
    @Binding var gm: MeshingSettings
    var referenceLength: Double
    @State private var showCalculator = false
    @State private var yPlus = 1.0
    @State private var velocity = 1.0
    @State private var length = 0.0

    var enabled: Binding<Bool> {
        Binding(get: { gm.blFirstHeight > 0 }, set: { on in
            if on {
                gm.blFirstHeight = gm.wallSize / 50
                if gm.blLayers == 0 { gm.blLayers = 10 }
            } else { gm.blFirstHeight = 0 }
        })
    }

    var body: some View {
        Toggle("Prism layers on walls (inflation)", isOn: enabled)
        if gm.blFirstHeight > 0 {
            NumberField(label: "First layer height", value: $gm.blFirstHeight, unit: "m")
            NumberField(label: "Growth rate", value: $gm.blGrowth)
            IntField(label: "Number of layers", value: $gm.blLayers)
            if let inf = gm.inflation3D {
                let last = inf.firstHeight * pow(inf.growth, Double(inf.layers - 1))
                Text(String(format: "Total thickness %.4g m, last layer %.3g m. Prisms join the tetrahedra best when the wall size is about 1.5–3 × the last layer (now %.1f ×).",
                            inf.targetThickness, last, gm.wallSize / last))
                    .font(.caption).foregroundStyle(gm.wallSize / last > 4 || gm.wallSize / last < 1 ? .orange : .secondary)
            }
            DisclosureGroup("First height from y+", isExpanded: $showCalculator) {
                NumberField(label: "Target y+", value: $yPlus)
                NumberField(label: "Velocity", value: $velocity, unit: "m/s")
                NumberField(label: "Reference length", value: $length, unit: "m")
                let mat = ws.setup.materials.first
                let rho = mat?.density ?? 1.225, mu = mat?.viscosity ?? 1.7894e-5
                let e = WallSpacing.estimate(yPlus: yPlus, velocity: velocity, length: length > 0 ? length : referenceLength, density: rho, viscosity: mu)
                Text(String(format: "Re = %.3g with %@ (ρ %.4g, μ %.4g). First height %.3g m; boundary layer ≈ %.3g m.",
                            e.reynolds, (mat?.name ?? "air") as NSString, rho, mu, e.firstHeight, e.boundaryLayerThickness))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use This Height") {
                    gm.blFirstHeight = e.firstHeight
                    // enough layers for the last one to reach about half the wall size
                    gm.blLayers = max(3, Int((log(max(0.5 * gm.wallSize / e.firstHeight, 1.01)) / log(max(gm.blGrowth, 1.01))).rounded(.up)) + 1)
                }
            }
            Text("All walls are inflated; inlets, outlets and symmetry planes are followed by the layers. Low-Re models (SST, Spalart–Allmaras) want y+ ≈ 1.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


/// snappyHexMesh controls for CAD meshing.
struct SnappySettingsSection: View {
    @Binding var snappy: SnappySettings
    var external: Bool
    var body: some View {
        Section("snappyHexMesh") {
            NumberField(label: "Background cell size (0 = automatic)", value: $snappy.baseCellSize, unit: "m")
            Stepper("Surface refinement: level \(snappy.surfaceLevelMin) – \(snappy.surfaceLevelMax)", onIncrement: { snappy.surfaceLevelMax += 1; snappy.surfaceLevelMin += 1 },
                    onDecrement: { snappy.surfaceLevelMin = max(0, snappy.surfaceLevelMin - 1); snappy.surfaceLevelMax = max(snappy.surfaceLevelMin, snappy.surfaceLevelMax - 1) })
            Stepper("Maximum surface level: \(snappy.surfaceLevelMax)", value: $snappy.surfaceLevelMax, in: snappy.surfaceLevelMin...10)
            Stepper("Feature edge level: \(snappy.featureLevel)", value: $snappy.featureLevel, in: 0...10)
            NumberField(label: "Feature included angle", value: $snappy.includedAngle, unit: "°")
            Stepper("Cells between levels: \(snappy.nCellsBetweenLevels)", value: $snappy.nCellsBetweenLevels, in: 1...8)
            if external {
                Toggle("Refinement box around body and wake", isOn: $snappy.refinementBox)
                if snappy.refinementBox {
                    Stepper("Box level: \(snappy.refinementBoxLevel)", value: $snappy.refinementBoxLevel, in: 0...8)
                    NumberField(label: "Box padding (body lengths)", value: $snappy.refinementBoxPadding)
                    NumberField(label: "Wake length (body lengths)", value: $snappy.wakeLength)
                }
                TextField("Domain padding −x +x −y +y −z +z (body lengths)", text: Binding(
                    get: { snappy.padding.map { NumberField.format($0) }.joined(separator: " ") },
                    set: { let v = $0.split(separator: " ").compactMap { Double($0) }; if v.count == 6 { snappy.padding = v } }))
                    .textFieldStyle(.roundedBorder)
            }
        }
        Section("snappyHexMesh Layers and Quality") {
            Stepper("Prism layers: \(snappy.layers)", value: $snappy.layers, in: 0...30)
            if snappy.layers > 0 {
                NumberField(label: "Expansion ratio", value: $snappy.expansionRatio)
                NumberField(label: "First layer thickness (0 = relative sizes)", value: $snappy.firstLayerThickness, unit: "m")
                if snappy.firstLayerThickness == 0 {
                    NumberField(label: "Final layer thickness (relative)", value: $snappy.finalLayerThickness)
                    NumberField(label: "Minimum thickness (relative)", value: $snappy.minThickness)
                }
            }
            NumberField(label: "maxNonOrtho", value: $snappy.maxNonOrtho, unit: "°")
            NumberField(label: "maxInternalSkewness", value: $snappy.maxInternalSkewness)
            NumberField(label: "maxBoundarySkewness", value: $snappy.maxBoundarySkewness)
            Stepper("Cores: \(snappy.cores)", value: $snappy.cores, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
            TextField("locationInMesh x y z (empty = automatic)", text: Binding(
                get: { snappy.locationInMesh.map { NumberField.format($0) }.joined(separator: " ") },
                set: { let v = $0.split(separator: " ").compactMap { Double($0) }; snappy.locationInMesh = v.count == 3 ? v : [] }))
                .textFieldStyle(.roundedBorder)
        }
    }
}
