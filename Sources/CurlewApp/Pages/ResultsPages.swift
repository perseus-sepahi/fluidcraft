import SwiftUI
import UniformTypeIdentifiers
import CurlewMesh
import CurlewSolver
import CurlewPost

struct SurfacesPage: View {
    @Bindable var ws: Workspace
    @State private var kind = 0
    @State private var axis = 0
    @State private var coordinate = 0.0
    @State private var point = [0.0, 0.0, 0.0]
    @State private var normal = [0.0, 0.0, 1.0]
    @State private var isoField = "velocity-magnitude"
    @State private var isoValue = 1.0
    @State private var name = ""
    var body: some View {
        Form {
            Section("Surfaces") {
                if ws.namedSurfaces.isEmpty { Text("Boundary zones are always available. Create planes or iso-surfaces below.").font(.caption).foregroundStyle(.secondary) }
                ForEach(ws.namedSurfaces) { s in
                    HStack {
                        VStack(alignment: .leading) { Text(s.name); Text(s.definition.label).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) { ws.namedSurfaces.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Create") {
                Picker("Type", selection: $kind) { Text("Plane (axis-aligned)").tag(0); Text("Plane (point & normal)").tag(1); Text("Iso-Surface").tag(2) }
                switch kind {
                case 0:
                    Picker("Axis", selection: $axis) { Text("x =").tag(0); Text("y =").tag(1); Text("z =").tag(2) }.pickerStyle(.segmented)
                    NumberField(label: "Coordinate", value: $coordinate, unit: "m")
                    if let b = ws.mesh?.bounds { Text(String(format: "Range %.4g … %.4g", b.min[axis], b.max[axis])).font(.caption).foregroundStyle(.secondary) }
                case 1:
                    VectorField(label: "Point", value: $point, unit: "m")
                    VectorField(label: "Normal", value: $normal)
                default:
                    Picker("Field", selection: $isoField) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                    NumberField(label: "Iso-value", value: $isoValue)
                }
                TextField("Name (optional)", text: $name)
                Button("Create") { create() }.disabled(ws.mesh == nil)
            }
        }
        .formStyle(.grouped)
    }
    func create() {
        let def: SurfaceDefinition
        var label = name
        switch kind {
        case 0:
            var p = [0.0, 0.0, 0.0]; p[axis] = coordinate
            var n = [0.0, 0.0, 0.0]; n[axis] = 1
            def = .plane(point: p, normal: n)
            if label.isEmpty { label = "\(["x", "y", "z"][axis])=\(Quantity.format(coordinate))" }
        case 1:
            def = .plane(point: point, normal: normal)
            if label.isEmpty { label = "plane-\(ws.namedSurfaces.count + 1)" }
        default:
            def = .isoSurface(field: isoField, value: isoValue)
            if label.isEmpty { label = "iso-\(isoField)-\(Quantity.format(isoValue))" }
        }
        ws.namedSurfaces.append(NamedSurface(name: label, definition: def))
        ws.log("Created surface \(label)")
        name = ""
    }
}

struct MeshDisplayPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            if let m = ws.mesh {
                Section("Surfaces") {
                    MultiSelectList(items: m.boundaryZones.filter { $0.kind != .empty }.map(\.name), selection: $ws.display.surfaces, emptyMeaning: m.isTwoDimensional ? "2D domain" : "all boundaries")
                }
                Section {
                    Button("Display") { ws.display.mode = .mesh; ws.graphicsTab = .viewport; ws.refreshDisplay() }.buttonStyle(.borderedProminent)
                }
            } else { NoMeshNotice() }
        }
        .formStyle(.grouped)
    }
}

struct GraphicsCommon: View {
    @Bindable var ws: Workspace
    var showRange = true
    var body: some View {
        Section("Colouring") {
            Picker("Colormap", selection: $ws.display.colormap) { ForEach(Colormap.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Levels", selection: $ws.display.bands) {
                Text("Smooth").tag(0); Text("10 bands").tag(10); Text("20 bands").tag(20); Text("40 bands").tag(40)
            }
            if showRange {
                Toggle("Auto range", isOn: $ws.display.autoRange)
                if !ws.display.autoRange {
                    NumberField(label: "Min", value: $ws.display.minValue)
                    NumberField(label: "Max", value: $ws.display.maxValue)
                }
            }
        }
    }
}

struct ContoursPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            if ws.mesh == nil { NoMeshNotice() } else {
                Section("Contours of") {
                    Picker("Field", selection: $ws.display.field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                    Toggle("Draw mesh edges", isOn: $ws.display.showEdges)
                    Toggle("Show outline (walls)", isOn: $ws.display.showOutline)
                }
                Section("Surfaces") {
                    MultiSelectList(items: ws.surfaceNames(), selection: $ws.display.surfaces, emptyMeaning: ws.mesh?.isTwoDimensional == true ? "2D domain" : "all walls")
                }
                GraphicsCommon(ws: ws)
                Section {
                    Button("Display") { show() }.buttonStyle(.borderedProminent).disabled(!ws.initialized)
                    if !ws.initialized { Text("Initialize or run the solution first.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }
    func show() { ws.display.mode = .contours; ws.graphicsTab = .viewport; ws.refreshDisplay() }
}

struct VectorsPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            if ws.mesh == nil { NoMeshNotice() } else {
                Section("Vectors of velocity") {
                    Picker("Colour by", selection: $ws.display.field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                    NumberField(label: "Scale", value: $ws.display.vectorScale)
                    Stepper("Skip: \(ws.display.vectorSkip)", value: $ws.display.vectorSkip, in: 0...50)
                }
                Section("Surfaces") {
                    MultiSelectList(items: ws.surfaceNames(), selection: $ws.display.surfaces, emptyMeaning: ws.mesh?.isTwoDimensional == true ? "2D domain" : "all walls")
                }
                GraphicsCommon(ws: ws)
                Section { Button("Display") { ws.display.mode = .vectors; ws.graphicsTab = .viewport; ws.refreshDisplay() }.buttonStyle(.borderedProminent).disabled(!ws.initialized) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PathlinesPage: View {
    @Bindable var ws: Workspace
    var body: some View {
        Form {
            if let m = ws.mesh {
                Section("Pathlines") {
                    Picker("Colour by", selection: $ws.display.field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                    Picker("Release from", selection: $ws.display.pathlineSeeds) {
                        Text("first inlet").tag("")
                        ForEach(m.boundaryZones.filter { $0.kind != .empty }, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    IntField(label: "Number of particles", value: $ws.display.pathlineCount)
                    IntField(label: "Max steps", value: $ws.display.pathlineSteps)
                }
                GraphicsCommon(ws: ws)
                Section { Button("Display") { ws.display.mode = .pathlines; ws.graphicsTab = .viewport; ws.refreshDisplay() }.buttonStyle(.borderedProminent).disabled(!ws.initialized) }
            } else { NoMeshNotice() }
        }
        .formStyle(.grouped)
    }
}

struct XYPlotPage: View {
    @Bindable var ws: Workspace
    @State private var mode = 0
    @State private var field = "x-velocity"
    @State private var a = [0.0, 0.0, 0.0]
    @State private var b = [1.0, 0.0, 0.0]
    @State private var zone = ""
    @State private var axis = 0
    var body: some View {
        Form {
            if let m = ws.mesh {
                Section("Y Axis Function") {
                    Picker("Field", selection: $field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } }
                }
                Section("X Axis") {
                    Picker("Plot", selection: $mode) { Text("Along a line").tag(0); Text("On a boundary vs coordinate").tag(1) }.pickerStyle(.segmented)
                    if mode == 0 {
                        VectorField(label: "Start point", value: $a, unit: "m")
                        VectorField(label: "End point", value: $b, unit: "m")
                    } else {
                        Picker("Zone", selection: $zone) { ForEach(m.boundaryZones.filter { $0.kind != .empty }, id: \.name) { Text($0.name).tag($0.name) } }
                        Picker("Position on", selection: $axis) { Text("x").tag(0); Text("y").tag(1); Text("z").tag(2) }.pickerStyle(.segmented)
                    }
                }
                Section {
                    Button("Plot") { plot() }.buttonStyle(.borderedProminent).disabled(!ws.initialized || ws.isRunning)
                    if ws.xyPlot != nil { Button("Export CSV…") { exportCSV() } }
                }
            } else { NoMeshNotice() }
        }
        .formStyle(.grouped)
        .onAppear {
            if let m = ws.mesh {
                let bb = m.bounds
                if a == [0, 0, 0] && b == [1, 0, 0] {
                    a = [bb.min.x, bb.centre.y, bb.centre.z]; b = [bb.max.x, bb.centre.y, bb.centre.z]
                }
                if zone.isEmpty { zone = m.boundaryZones.first { $0.kind == .wall }?.name ?? "" }
            }
        }
    }
    func plot() {
        guard let post = ws.post else { return }
        let pts: [(Double, Double)]
        let xl: String
        if mode == 0 {
            pts = post.lineSample(field, from: Vec3(a[0], a[1], a[2]), to: Vec3(b[0], b[1], b[2]), points: 300)
            xl = "Distance along line (m)"
        } else {
            pts = post.zoneSample(field, zone: zone, axis: axis)
            xl = "Position \(["x", "y", "z"][axis]) (m)"
        }
        ws.xyPlot = XYPlotData(title: "\(field)", xLabel: xl, yLabel: field,
                               series: [.init(name: field, points: pts.enumerated().map { XYPoint(id: $0.offset, x: $0.element.0, y: $0.element.1) })])
        ws.graphicsTab = .xy
    }
    func exportCSV() {
        guard let d = ws.xyPlot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(d.title).csv"
        if panel.runModal() == .OK, let url = panel.url {
            var t = "\(d.xLabel),\(d.yLabel)\n"
            for p in d.series.first?.points ?? [] { t += "\(p.x),\(p.y)\n" }
            try? t.write(to: url, atomically: true, encoding: .utf8)
            ws.log("Wrote \(url.path)")
        }
    }
}

struct ReportsPage: View {
    @Bindable var ws: Workspace
    @State private var kind = 0
    @State private var zones: [String] = []
    @State private var field = "pressure"
    @State private var direction = [1.0, 0.0, 0.0]
    @State private var surfaceKind: ReportKind = .areaWeightedAverage
    var body: some View {
        Form {
            if let m = ws.mesh {
                Section("Report") {
                    Picker("Type", selection: $kind) {
                        Text("Fluxes (mass flow)").tag(0); Text("Forces").tag(1); Text("Surface Integrals").tag(2); Text("Volume Integrals").tag(3); Text("Heat Transfer").tag(4)
                    }
                    if kind == 2 {
                        Picker("Report type", selection: $surfaceKind) {
                            Text("Area-Weighted Average").tag(ReportKind.areaWeightedAverage)
                            Text("Mass-Weighted Average").tag(ReportKind.massWeightedAverage)
                            Text("Integral").tag(ReportKind.integral)
                        }
                    }
                    if kind == 2 || kind == 3 { Picker("Field", selection: $field) { ForEach(ws.availableFields(), id: \.self) { Text($0).tag($0) } } }
                    if kind == 1 { VectorField(label: "Direction", value: $direction) }
                }
                if kind != 3 {
                    Section("Zones") {
                        MultiSelectList(items: m.boundaryZones.filter { $0.kind != .empty }.map(\.name), selection: $zones,
                                        emptyMeaning: kind == 1 ? "all walls" : "all zones")
                    }
                }
                Section {
                    Button("Compute") { compute() }.buttonStyle(.borderedProminent).disabled(!ws.initialized || ws.isRunning)
                    if !ws.lastReportText.isEmpty {
                        Text(ws.lastReportText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } else { NoMeshNotice() }
        }
        .formStyle(.grouped)
    }

    func compute() {
        guard let s = ws.solver, let m = ws.mesh else { return }
        var t = ""
        switch kind {
        case 0:
            t = "Mass Flow Rate                    [kg/s]\n-------------------------------- --------------------\n"
            var net = 0.0
            let list = zones.isEmpty ? m.boundaryZones.filter { ![.empty, .wall, .symmetry].contains($0.kind) }.map(\.name) : zones
            for z in list {
                var r = ReportDefinition(name: z, kind: .massFlowRate); r.zones = [z]
                let v = Reports.evaluate(r, solver: s); net += v
                t += z.padding(toLength: 32, withPad: " ", startingAt: 0) + " " + String(format: "%20.10g", v) + "\n"
            }
            t += "-------------------------------- --------------------\n" + "Net".padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g", net)
        case 1:
            let list = zones.isEmpty ? m.boundaryZones.filter { $0.kind == .wall }.map(\.name) : zones
            let dir = normalized(Vec3(direction[0], direction[1], direction[2]))
            let ref = ws.setup.reference
            let q = 0.5 * ref.density * ref.velocity * ref.velocity * ref.area
            t = String(format: "Forces - Direction Vector (%.3g %.3g %.3g)\n", dir.x, dir.y, dir.z)
            t += "Zone                     Pressure        Viscous         Total           Coefficient\n"
            var tp = 0.0, tv = 0.0
            for z in list {
                let (F, _) = Reports.forces([z], s)
                let p = dot(F.pressure, dir), v = dot(F.viscous, dir)
                tp += p; tv += v
                t += z.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: " %-15.6g %-15.6g %-15.6g %-.6g\n", p, v, p + v, (p + v) / max(q, 1e-300))
            }
            t += "Net".padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: " %-15.6g %-15.6g %-15.6g %-.6g", tp, tv, tp + tv, (tp + tv) / max(q, 1e-300))
        case 2:
            var r = ReportDefinition(name: "s", kind: surfaceKind); r.field = field
            t = "\(surfaceKind.displayName) of \(field)\n"
            let list = zones.isEmpty ? m.boundaryZones.filter { $0.kind != .empty }.map(\.name) : zones
            for z in list {
                r.zones = [z]
                t += z.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g\n", Reports.evaluate(r, solver: s))
            }
            // named planes
            if let post = ws.post {
                for ns in ws.namedSurfaces where surfaceKind == .areaWeightedAverage {
                    let sm = post.surface(ns.definition, field: field)
                    let (avg, _) = sm.areaAverage()
                    t += ns.name.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g\n", avg)
                }
            }
        case 3:
            t = "Volume integrals of \(field)\n"
            for k in [ReportKind.volumeAverage, .volumeMaximum, .volumeMinimum] {
                var r = ReportDefinition(name: "v", kind: k); r.field = field
                t += k.displayName.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g\n", Reports.evaluate(r, solver: s))
            }
            t += "Total volume".padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g m3", m.totalVolume)
        default:
            t = "Total Heat Transfer Rate          [W]\n"
            var net = 0.0
            let list = zones.isEmpty ? m.boundaryZones.filter { $0.kind != .empty }.map(\.name) : zones
            for z in list {
                var r = ReportDefinition(name: z, kind: .heatTransferRate); r.zones = [z]
                let v = Reports.evaluate(r, solver: s); net += v
                t += z.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g\n", v)
            }
            t += "Net".padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %20.10g", net)
        }
        ws.lastReportText = t
        ws.log(t)
    }
}
