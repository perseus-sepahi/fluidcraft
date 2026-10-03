import SwiftUI
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver

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

    var body: some View {
        Form {
            Section("Start from a Tutorial") {
                ForEach(TutorialCatalog.all) { t in
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
            Section("Generate a Mesh") {
                Picker("Method", selection: $method) {
                    Text("Block (structured, Cartesian)").tag(0)
                    Text("Cylinder O-grid (2D)").tag(1)
                    Text("Gmsh templates").tag(2)
                    Text("CAD geometry (Gmsh)").tag(3)
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
                Text("Fluent .msh/.cas (ASCII or binary), Gmsh .msh (v2.2/v4.1), OpenFOAM polyMesh directory.").font(.caption).foregroundStyle(.secondary)
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
                if gmTemplate != 2 {
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
            Section("CAD Geometry (STEP / IGES / BREP)") {
                HStack {
                    Text(cadPath.isEmpty ? "No file" : (cadPath as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = ["step", "stp", "iges", "igs", "brep"].compactMap { UTType(filenameExtension: $0) }
                        if p.runModal() == .OK, let u = p.url { cadPath = u.path }
                    }
                }
                Picker("Flow type", selection: $cadExternal) {
                    Text("External flow around the body (box enclosure)").tag(true)
                    Text("Internal flow (body is the fluid volume)").tag(false)
                }
                Picker("Flow direction", selection: $cadAxis) { Text("+x").tag(0); Text("+y").tag(1); Text("+z").tag(2) }.pickerStyle(.segmented)
                Text("Named selections are created automatically: inlet/outlet on the extreme faces along the flow direction, \(cadExternal ? "farfield on the other box faces and body on the geometry" : "wall on all other faces").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sizing") { sizingFields }
            Section {
                Button(ws.isMeshing ? "Meshing…" : "Mesh Geometry") {
                    var s = gm
                    s.template = .cad(path: cadPath, external: cadExternal, flowAxis: cadAxis, padding: [3, 8, 3, 3, 3, 3])
                    ws.generateMesh(s)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cadPath.isEmpty || ws.isMeshing || !GmshDriver.isAvailable)
            }
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
        let new = name.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != z.name, !m.boundaryZones.contains(where: { $0.name == new }) else { name = z.name; return }
        let settings = ws.setup.boundaries.removeValue(forKey: z.name)
        m.updateBoundaryZone(index, name: new)
        ws.setup.boundaries[new] = settings ?? BoundarySettings(type: z.kind)
        ws.solver = nil; ws.post = nil; ws.initialized = false
        ws.log("Renamed zone \(z.name) → \(new)")
    }
}
