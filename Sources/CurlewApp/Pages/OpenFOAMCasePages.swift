import SwiftUI
import CurlewMesh
import CurlewSolver
import CurlewFoam

/// Run control, safety limits and the extra function objects.
struct FoamRunControlSection: View {
    @Bindable var ws: Workspace
    var o: Binding<FoamSettings> { $ws.setup.openfoam }
    var body: some View {
        Section("Run Control (controlDict)") {
            Picker("Start from", selection: o.startFrom) { Text("Latest time").tag("latestTime"); Text("Start time").tag("startTime") }
            Picker("Stop at", selection: o.stopAt) {
                Text("End time").tag("endTime"); Text("Write now").tag("writeNow"); Text("Now, no write").tag("noWriteNow"); Text("Next write").tag("nextWrite")
            }
            Toggle("Re-read dictionaries while running (runTimeModifiable)", isOn: o.runTimeModifiable)
            Toggle("Compress written fields", isOn: o.writeCompression)
            IntField(label: "Time precision", value: o.timePrecision)
        }
        Section("Safety Limits (fvOptions)") {
            Toggle("Limit velocity magnitude", isOn: Binding(get: { ws.setup.openfoam.limitVelocity != nil },
                                                           set: { ws.setup.openfoam.limitVelocity = $0 ? max(10, 5 * ws.setup.reference.velocity) : nil }))
            if ws.setup.openfoam.limitVelocity != nil {
                NumberField(label: "Maximum |U|", value: Binding(get: { ws.setup.openfoam.limitVelocity ?? 0 }, set: { ws.setup.openfoam.limitVelocity = $0 }), unit: "m/s")
            }
            Text("Heat-transfer cases also get limitTemperature between the Controls page's temperature limits.").font(.caption).foregroundStyle(.secondary)
        }
        Section("More Function Objects") {
            Toggle("Residuals file (solverInfo)", isOn: o.residualsFile)
            Toggle("Courant number", isOn: o.courantNumber)
            Toggle("Mach number (compressible)", isOn: o.machNumber)
            Toggle("Pressure coefficient Cp", isOn: o.pressureCoefficient)
            Toggle("Wall heat flux (heat transfer)", isOn: o.wallHeatFlux)
            Toggle("Turbulence fields (k, ε, ω, νt, R)", isOn: o.turbulenceFields)
            Toggle("λ₂ vortex criterion", isOn: o.lambda2)
            ForEach(Array(ws.setup.openfoam.cuttingPlanes.enumerated()), id: \.offset) { i, _ in
                let pl = Binding<FoamCuttingPlane>.element(o.cuttingPlanes, i, fallback: FoamCuttingPlane(name: "plane", point: [0, 0, 0], normal: [0, 0, 1]))
                VStack(alignment: .leading) {
                    HStack {
                        TextField("name", text: pl.name).textFieldStyle(.roundedBorder)
                        Button(role: .destructive) { ws.setup.openfoam.cuttingPlanes.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    VectorField(label: "Point", value: pl.point, unit: "m")
                    VectorField(label: "Normal", value: pl.normal)
                }
            }
            Button("Add Cutting Plane (VTK surface)") {
                let c = ws.mesh.map { 0.5 * ($0.bounds.min + $0.bounds.max) } ?? Vec3(0, 0, 0)
                ws.setup.openfoam.cuttingPlanes.append(FoamCuttingPlane(name: "plane\(ws.setup.openfoam.cuttingPlanes.count + 1)", point: [c.x, c.y, c.z], normal: [0, 0, 1]))
            }
            Picker("Stop when this report settles", selection: o.runTimeStopReport) {
                Text("Off").tag("")
                ForEach(ws.setup.reports.map(\.name), id: \.self) { Text($0).tag($0) }
            }
            if !ws.setup.openfoam.runTimeStopReport.isEmpty {
                NumberField(label: "Relative change below", value: o.runTimeStopTolerance)
                IntField(label: "over iterations", value: o.runTimeStopWindow)
            }
        }
    }
}

/// Every file of the generated case, with the option to replace any of them.
struct FoamCaseFilesSection: View {
    @Bindable var ws: Workspace
    @State private var files: [String] = []
    @State private var generated: [String: String] = [:]
    @State private var selected = ""
    @State private var status = ""

    var body: some View {
        Section("Case Files (every generated dictionary)") {
            HStack {
                Button("Generate Preview") { preview() }.disabled(ws.mesh == nil)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if !files.isEmpty {
                Picker("File", selection: $selected) {
                    ForEach(files, id: \.self) { f in Text(f + (ws.setup.openfoam.fileOverrides[f] != nil ? "  (replaced)" : "")).tag(f) }
                }
                if let text = ws.setup.openfoam.fileOverrides[selected] {
                    TextEditor(text: Binding(get: { text }, set: { ws.setup.openfoam.fileOverrides[selected] = $0 }))
                        .font(.system(.caption, design: .monospaced)).frame(minHeight: 220).border(.quaternary)
                    Button("Revert to Generated") { ws.setup.openfoam.fileOverrides[selected] = nil }
                } else {
                    ScrollView {
                        Text(generated[selected] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220).border(.quaternary)
                    Button("Replace This File with an Edited Copy") { ws.setup.openfoam.fileOverrides[selected] = generated[selected] ?? "" }
                }
            }
            Text("Shows exactly what Calculate writes. A replaced file is written as you edit it, after everything else, so any OpenFOAM keyword can be set. Prefer the settings above, which stay in step with the setup; replaced files do not follow later changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func preview() {
        guard let mesh = ws.mesh else { return }
        var s = ws.setup
        s.openfoam.fileOverrides = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("curlew-foam-preview-\(UUID().uuidString.prefix(8))")
        status = "Writing…"
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try FoamCaseWriter.write(mesh: mesh, setup: s, to: dir, writeMesh: false, writeFields: true)
                var out: [String: String] = [:]
                let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                while let u = e?.nextObject() as? URL {
                    let rel = String(u.path.dropFirst(dir.path.count + 1))
                    guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !rel.contains("polyMesh/") else { continue }
                    let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                    out[rel] = size > 400_000 ? String(t.prefix(400_000)) + "\n… (truncated in the preview)" : t
                }
                DispatchQueue.main.async {
                    generated = out
                    files = out.keys.sorted { (a, b) in
                        let order = ["system/", "constant/", "0"]
                        let ia = order.firstIndex { a.hasPrefix($0) } ?? 9, ib = order.firstIndex { b.hasPrefix($0) } ?? 9
                        return (ia, a) < (ib, b)
                    }
                    if !files.contains(selected) { selected = files.first { $0 == "system/controlDict" } ?? files.first ?? "" }
                    status = "\(files.count) files"
                }
            } catch {
                DispatchQueue.main.async { status = "\(error)" }
            }
        }
    }
}


/// Fans, porous jumps and thin walls made by OpenFOAM's createBaffles; periodic flow drive.
struct FoamBafflesSection: View {
    @Bindable var ws: Workspace
    var o: Binding<FoamSettings> { $ws.setup.openfoam }
    var body: some View {
        Section("Baffles and Periodic Flow") {
            ForEach(Array(ws.setup.openfoam.baffles.enumerated()), id: \.offset) { i, _ in
                let b = Binding<FoamBaffle>.element(o.baffles, i, fallback: FoamBaffle())
                DisclosureGroup("\(b.wrappedValue.name) — \(b.wrappedValue.kind.displayName)") {
                    TextField("Name", text: b.name).textFieldStyle(.roundedBorder)
                    Picker("Type", selection: b.kind) { ForEach(FoamBaffle.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker("Faces cut by", selection: b.shape) { Text("Disk").tag(FoamBaffle.Shape.disk); Text("Plate").tag(FoamBaffle.Shape.plate); Text("Box surface").tag(FoamBaffle.Shape.box) }
                        .pickerStyle(.segmented)
                    switch b.wrappedValue.shape {
                    case .disk:
                        VectorField(label: "Centre", value: b.origin, unit: "m")
                        VectorField(label: "Normal (flow direction through a fan)", value: b.normal)
                        NumberField(label: "Radius", value: b.radius, unit: "m")
                    case .plate:
                        VectorField(label: "Corner", value: b.origin, unit: "m")
                        VectorField(label: "Span (one component 0)", value: b.span, unit: "m")
                    case .box:
                        VectorField(label: "Minimum corner", value: b.origin, unit: "m")
                        VectorField(label: "Size", value: b.span, unit: "m")
                    }
                    switch b.wrappedValue.kind {
                    case .fan:
                        Text("Fan curve (volume flow → pressure rise)").font(.caption)
                        ForEach(Array(b.wrappedValue.fanCurve.enumerated()), id: \.offset) { j, _ in
                            HStack {
                                NumberField(label: "Q", value: Binding(get: { b.wrappedValue.fanCurve[safe: j]?[safe: 0] ?? 0 }, set: { b.wrappedValue.fanCurve[j][0] = $0 }), unit: "m³/s")
                                NumberField(label: "Δp", value: Binding(get: { b.wrappedValue.fanCurve[safe: j]?[safe: 1] ?? 0 }, set: { b.wrappedValue.fanCurve[j][1] = $0 }), unit: "Pa")
                                Button(role: .destructive) { b.wrappedValue.fanCurve.remove(at: j) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        Button("Add Point") { b.wrappedValue.fanCurve.append([(b.wrappedValue.fanCurve.last?[0] ?? 0) * 1.5 + 0.001, 0]) }
                        Text("The pressure rises across the baffle in the direction of its normal. OpenFOAM's fan condition takes the jump as a function of the face velocity Q / A (A = \(NumberField.format(b.wrappedValue.nominalArea)) m²).")
                            .font(.caption).foregroundStyle(.secondary)
                    case .porousJump:
                        NumberField(label: "Darcy coefficient D", value: b.darcy, unit: "1/m²")
                        NumberField(label: "Inertial coefficient I", value: b.inertial, unit: "1/m")
                        NumberField(label: "Thickness L", value: b.thickness, unit: "m")
                        Text("Δp = (D μ U + ½ I ρ U²) L (OpenFOAM porousBafflePressure).").font(.caption).foregroundStyle(.secondary)
                    case .thinWall:
                        Text("Both sides are no-slip walls with the case's wall treatment.").font(.caption).foregroundStyle(.secondary)
                    }
                    if b.wrappedValue.kind != .thinWall { Toggle("Jump from the mean velocity (uniformJump)", isOn: b.uniformJump) }
                    Button("Remove Baffle", role: .destructive) { ws.setup.openfoam.baffles.remove(at: i) }
                }
            }
            Menu("Add Baffle") {
                ForEach(FoamBaffle.Kind.allCases, id: \.self) { k in
                    Button(k.displayName) {
                        var nb = FoamBaffle(name: "\(k == .fan ? "fan" : (k == .porousJump ? "screen" : "plate"))\(ws.setup.openfoam.baffles.count + 1)", kind: k)
                        if let m = ws.mesh { let c = 0.5 * (m.bounds.min + m.bounds.max); nb.origin = [c.x, c.y, c.z]; nb.radius = 0.25 * max(m.bounds.max.y - m.bounds.min.y, 1e-6) }
                        ws.setup.openfoam.baffles.append(nb)
                    }
                }
            }
            Text("OpenFOAM's createBaffles turns the internal faces cut by the surface into a patch pair (<name>_master on the side the normal leaves, <name>_slave) before the run. Fans and porous jumps couple the pair (cyclic) with a pressure jump.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Drive a periodic flow at a mean velocity (meanVelocityForce)", isOn: Binding(get: { ws.setup.openfoam.meanVelocity != nil },
                                                                                               set: { ws.setup.openfoam.meanVelocity = $0 ? [max(ws.setup.reference.velocity, 1), 0, 0] : nil }))
            if ws.setup.openfoam.meanVelocity != nil {
                VectorField(label: "Mean velocity", value: Binding(get: { ws.setup.openfoam.meanVelocity ?? [1, 0, 0] }, set: { ws.setup.openfoam.meanVelocity = $0 }), unit: "m/s")
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
