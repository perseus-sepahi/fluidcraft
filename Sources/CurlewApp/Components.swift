import SwiftUI
import CurlewMesh
import CurlewSolver

/// Numeric text field that commits on Return or focus loss.
struct NumberField: View {
    var label: String
    @Binding var value: Double
    var unit: String = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70, maxWidth: 140)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).font(.caption).frame(minWidth: 34, alignment: .leading) }
            }
        } label: { Text(label) }
        .onAppear { text = NumberField.format(value) }
        .onChange(of: value) { _, v in if !focused { text = NumberField.format(v) } }
    }

    func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) { value = v }
        text = NumberField.format(value)
    }

    static func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if abs(v) >= 1e-3 && abs(v) < 1e6 {
            var s = String(format: "%.8g", v)
            if s.contains("e") { s = String(format: "%g", v) }
            return s
        }
        return String(format: "%.6g", v)
    }
}

struct IntField: View {
    var label: String
    @Binding var value: Int
    var body: some View {
        LabeledContent(label) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 70, maxWidth: 140)
        }
    }
}

/// Constant or expression input (e.g. `4*Umax*y*(H-y)/H^2`).
struct QuantityField: View {
    var label: String
    @Binding var value: Quantity
    var unit: String = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                if case .expression = value { Image(systemName: "function").foregroundStyle(.tint).help("Expression") }
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70, maxWidth: 180)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).font(.caption).frame(minWidth: 34, alignment: .leading) }
            }
        } label: { Text(label) }
        .onAppear { text = value.description }
        .onChange(of: value) { _, v in if !focused { text = v.description } }
    }

    func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { text = value.description; return }
        value = Quantity.parse(t)
    }
}

struct VectorField: View {
    var label: String
    @Binding var value: [Double]
    var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack {
                ForEach(0..<3, id: \.self) { i in
                    NumberField(label: ["X", "Y", "Z"][i], value: Binding(
                        get: { value.count > i ? value[i] : 0 },
                        set: { v in var a = value; while a.count < 3 { a.append(0) }; a[i] = v; value = a }))
                }
            }
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct QuantityVectorField: View {
    var label: String
    @Binding var value: [Quantity]
    var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            ForEach(0..<3, id: \.self) { i in
                QuantityField(label: ["X", "Y", "Z"][i] + " component", value: Binding(
                    get: { value.count > i ? value[i] : 0 },
                    set: { v in var a = value; while a.count < 3 { a.append(0) }; a[i] = v; value = a }), unit: unit)
            }
        }
    }
}

/// Multi-select list of names.
struct MultiSelectList: View {
    var items: [String]
    @Binding var selection: [String]
    var emptyMeaning: String = "default"
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.self) { item in
                Toggle(isOn: Binding(
                    get: { selection.contains(item) },
                    set: { on in if on { if !selection.contains(item) { selection.append(item) } } else { selection.removeAll { $0 == item } } })) {
                    Text(item).lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
            if selection.isEmpty { Text("None selected — \(emptyMeaning)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String = ""
    var symbol: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }
}

struct NoMeshNotice: View {
    var body: some View {
        ContentUnavailableView("No Mesh", systemImage: "square.grid.3x3.square",
                               description: Text("Generate a mesh or use File › Import Mesh."))
    }
}

extension ZoneKind {
    static var userSelectable: [ZoneKind] { [.wall, .velocityInlet, .massFlowInlet, .pressureInlet, .pressureOutlet, .outflow, .symmetry, .pressureFarField] }
}
