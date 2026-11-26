import Foundation

/// Reader for the Fluent mesh/case file format (`.msh`, mesh part of `.cas`).
///
/// Supports ASCII and binary (20xx single / 30xx double) node, cell and face
/// sections, mixed and polygonal faces, 2D (edge-based) and 3D meshes, and zone
/// names from sections 39/45. Hanging-node face/cell trees are rejected.
public enum FluentMeshReader {
    public static func read(url: URL, depth2D: Double = 1) throws -> Mesh {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw MeshError.io("cannot read \(url.path): \(error.localizedDescription)") }
        return try read(data: data, depth2D: depth2D)
    }

    struct FaceSection { var zone: Int; var first: Int; var last: Int; var bc: Int; var faces: [[Int32]]; var c0: [Int32]; var c1: [Int32] }
    struct CellSection { var zone: Int; var first: Int; var last: Int; var type: Int }

    public static func read(data: Data, depth2D: Double = 1) throws -> Mesh {
        let bytes = [UInt8](data)
        var s = Scanner(bytes: bytes)
        var dim = 3
        var nodes: [Vec3] = []
        var faceSections: [FaceSection] = []
        var cellSections: [CellSection] = []
        var zoneInfo: [Int: (type: String, name: String)] = [:]
        var maxCell = 0

        while s.skipToOpenParen() {
            guard let index = s.readDecimal() else { try s.skipBalanced(); continue }
            switch index {
            case 0, 1:
                try s.skipBalanced(fromInside: true)
            case 2:
                s.skipSpace()
                if let d = s.readDecimal() { dim = d }
                try s.skipBalanced(fromInside: true)
            case 10, 2010, 3010:
                let h = try s.readHeaderHex()
                guard h.count >= 4 else { throw MeshError.parse("bad node header") }
                let zone = h[0], first = h[1], last = h[2]
                let nd = h.count >= 5 ? h[4] : dim
                if zone == 0 || !s.peekOpenParen() { try s.skipBalanced(fromInside: true); continue }
                let n = last - first + 1
                if nodes.count < last { nodes.append(contentsOf: repeatElement(.zero, count: last - nodes.count)) }
                try s.expectOpen()
                for i in 0..<n {
                    var p = Vec3.zero
                    for a in 0..<nd {
                        let v: Double
                        if index == 10 { v = try s.readFloat() }
                        else if index == 2010 { v = Double(try s.readBinaryFloat32()) }
                        else { v = try s.readBinaryFloat64() }
                        if a < 3 { p[a] = v }
                    }
                    nodes[first - 1 + i] = p
                }
                try s.finishSection(binary: index != 10, index: index)
            case 12, 2012, 3012:
                let h = try s.readHeaderHex()
                guard h.count >= 4 else { throw MeshError.parse("bad cell header") }
                if h[0] == 0 { maxCell = max(maxCell, h[2]); try s.skipBalanced(fromInside: true); continue }
                cellSections.append(CellSection(zone: h[0], first: h[1], last: h[2], type: h[3]))
                maxCell = max(maxCell, h[2])
                if s.peekOpenParen() {
                    // Mixed element-type list: types are irrelevant for a face-based mesh.
                    if index == 12 { try s.skipBalanced() } else {
                        try s.expectOpen()
                        for _ in 0..<(h[2] - h[1] + 1) { _ = try s.readBinaryInt32() }
                        try s.finishSection(binary: true, index: index)
                        continue
                    }
                }
                try s.skipBalanced(fromInside: true)
            case 13, 2013, 3013:
                let h = try s.readHeaderHex()
                // declaration "(13 (0 first last 0))" carries only four values
                if h.first == 0 || !s.peekOpenParen() { try s.skipBalanced(fromInside: true); continue }
                guard h.count >= 5 else { throw MeshError.parse("bad face header") }
                let first = h[1], last = h[2], bc = h[3], ftype = h[4]
                let n = last - first + 1
                var sec = FaceSection(zone: h[0], first: first, last: last, bc: bc, faces: [], c0: [], c1: [])
                sec.faces.reserveCapacity(n); sec.c0.reserveCapacity(n); sec.c1.reserveCapacity(n)
                let binary = index != 13
                try s.expectOpen()
                for _ in 0..<n {
                    let nn: Int
                    if ftype == 0 || ftype == 5 { nn = binary ? Int(try s.readBinaryInt32()) : try s.readHex() }
                    else { nn = ftype }
                    var f = [Int32](repeating: 0, count: nn)
                    for k in 0..<nn { f[k] = Int32(binary ? Int(try s.readBinaryInt32()) : try s.readHex()) - 1 }
                    let a = binary ? Int(try s.readBinaryInt32()) : try s.readHex()
                    let b = binary ? Int(try s.readBinaryInt32()) : try s.readHex()
                    sec.faces.append(f); sec.c0.append(Int32(a)); sec.c1.append(Int32(b))
                }
                try s.finishSection(binary: binary, index: index)
                faceSections.append(sec)
            case 39, 45:
                // (45 (id type name [domain])(...))
                try s.expectOpen()
                let tokens = s.readUntilClose()
                let parts = tokens.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
                if parts.count >= 3, let id = Int(parts[0]) ?? Int(parts[0], radix: 16) {
                    zoneInfo[id] = (parts[1], parts[2])
                }
                try s.skipBalanced(fromInside: true)
            case 58, 59, 2058, 2059, 3058, 3059:
                throw MeshError.unsupported("hanging-node (adapted) meshes with face/cell trees; export a conformal mesh")
            default:
                if index >= 2000 { try s.skipBinarySection(index: index) } else { try s.skipBalanced(fromInside: true) }
            }
        }

        guard !nodes.isEmpty else { throw MeshError.parse("no nodes found") }
        guard maxCell > 0 else { throw MeshError.parse("no cells found") }
        return try assemble(dim: dim, nodes: nodes, faces: faceSections, cells: cellSections,
                            zoneInfo: zoneInfo, nCells: maxCell, depth: depth2D)
    }

    public static func zoneKind(bc: Int, typeName: String?) -> ZoneKind {
        if let t = typeName?.lowercased() {
            switch t {
            case "wall": return .wall
            case "velocity-inlet": return .velocityInlet
            case "mass-flow-inlet": return .massFlowInlet
            case "pressure-inlet", "inlet-vent", "intake-fan": return .pressureInlet
            case "pressure-outlet", "exhaust-fan", "outlet-vent": return .pressureOutlet
            case "outflow": return .outflow
            case "symmetry", "axis": return .symmetry
            case "pressure-far-field": return .pressureFarField
            case "interior": return .interior
            default: break
            }
        }
        switch bc {
        case 3: return .wall
        case 4: return .pressureInlet
        case 5: return .pressureOutlet
        case 7, 37: return .symmetry
        case 9: return .pressureFarField
        case 10: return .velocityInlet
        case 20: return .massFlowInlet
        case 36: return .outflow
        case 2: return .interior
        default: return .wall
        }
    }

    static func assemble(dim: Int, nodes: [Vec3], faces: [FaceSection], cells: [CellSection],
                         zoneInfo: [Int: (type: String, name: String)], nCells: Int, depth: Double) throws -> Mesh {
        var b = MeshBuilder()
        b.nCells = nCells
        // Cell zones
        b.cellZones = []
        var cz = [Int32](repeating: 0, count: nCells)
        // several sections may belong to the same zone id (non-contiguous cell ranges)
        var specOfZone: [Int: Int32] = [:]
        for sec in cells.sorted(by: { $0.zone < $1.zone }) {
            if specOfZone[sec.zone] == nil {
                let info = zoneInfo[sec.zone]
                let kind: CellZoneKind = (info?.type.lowercased() == "solid") ? .solid : .fluid
                b.cellZones.append(MeshBuilder.CellZoneSpec(name: info?.name ?? "zone-\(sec.zone)", kind: kind))
                specOfZone[sec.zone] = Int32(b.cellZones.count - 1)
            }
            let zi = specOfZone[sec.zone]!
            for c in (sec.first - 1)..<min(sec.last, nCells) { cz[c] = zi }
        }
        if b.cellZones.isEmpty { b.cellZones = [MeshBuilder.CellZoneSpec(name: "fluid", kind: .fluid)] }
        b.cellZoneOfCell = cz

        if dim == 3 {
            b.points = nodes
            for sec in faces {
                let info = zoneInfo[sec.zone]
                let kind = zoneKind(bc: sec.bc, typeName: info?.type)
                let name = info?.name ?? "zone-\(sec.zone)"
                for i in 0..<sec.faces.count {
                    var c0 = sec.c0[i], c1 = sec.c1[i]
                    if c0 == 0 { swap(&c0, &c1) }
                    guard c0 > 0 else { throw MeshError.topology("face with no adjacent cell") }
                    if c1 > 0 {
                        b.addFace(sec.faces[i], c0: c0 - 1, c1: c1 - 1)
                    } else {
                        let z = b.addZone(name, kind: kind == .interior ? .wall : kind)
                        b.addFace(sec.faces[i], c0: c0 - 1, c1: -1, zone: z)
                    }
                }
            }
            return try b.build()
        }

        // 2D: extrude edges into a one-cell slab.
        let nN = nodes.count
        b.points = nodes.map { Vec3($0.x, $0.y, 0) } + nodes.map { Vec3($0.x, $0.y, depth) }
        var cellEdges = [[(Int32, Int32)]](repeating: [], count: nCells)
        for sec in faces {
            let info = zoneInfo[sec.zone]
            let kind = zoneKind(bc: sec.bc, typeName: info?.type)
            let name = info?.name ?? "zone-\(sec.zone)"
            for i in 0..<sec.faces.count {
                let e = sec.faces[i]
                guard e.count == 2 else { throw MeshError.topology("2D face with \(e.count) nodes") }
                var c0 = sec.c0[i], c1 = sec.c1[i]
                if c0 == 0 { swap(&c0, &c1) }
                guard c0 > 0 else { throw MeshError.topology("edge with no adjacent cell") }
                let quad: [Int32] = [e[0], e[1], e[1] + Int32(nN), e[0] + Int32(nN)]
                cellEdges[Int(c0 - 1)].append((e[0], e[1]))
                if c1 > 0 {
                    cellEdges[Int(c1 - 1)].append((e[0], e[1]))
                    b.addFace(quad, c0: c0 - 1, c1: c1 - 1)
                } else {
                    let z = b.addZone(name, kind: kind == .interior ? .wall : kind)
                    b.addFace(quad, c0: c0 - 1, c1: -1, zone: z)
                }
            }
        }
        let fb = b.addZone("frontAndBack", kind: .empty)
        for c in 0..<nCells {
            guard let loop = chainLoop(cellEdges[c]) else {
                throw MeshError.topology("2D cell \(c + 1) edges do not form a closed loop")
            }
            b.addFace(loop, c0: Int32(c), c1: -1, zone: fb)
            b.addFace(loop.reversed().map { $0 + Int32(nN) }, c0: Int32(c), c1: -1, zone: fb)
        }
        return try b.build()
    }

    /// Order a cell's edges into a closed polygon loop.
    static func chainLoop(_ edges: [(Int32, Int32)]) -> [Int32]? {
        guard edges.count >= 3 else { return nil }
        var adj: [Int32: [Int32]] = [:]
        for (a, b) in edges { adj[a, default: []].append(b); adj[b, default: []].append(a) }
        for (_, v) in adj where v.count != 2 { return nil }
        let start = edges[0].0
        var loop = [start]
        var prev = start
        var cur = edges[0].1
        while cur != start {
            loop.append(cur)
            guard let nb = adj[cur] else { return nil }
            let next = nb[0] == prev ? nb[1] : nb[0]
            prev = cur; cur = next
            if loop.count > edges.count { return nil }
        }
        return loop.count == edges.count ? loop : nil
    }
}

/// Byte scanner for Lisp-like Fluent sections.
struct Scanner {
    let bytes: [UInt8]
    var pos = 0
    init(bytes: [UInt8]) { self.bytes = bytes }

    @inline(__always) var atEnd: Bool { pos >= bytes.count }
    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    mutating func skipSpace() { while pos < bytes.count && Scanner.isSpace(bytes[pos]) { pos += 1 } }

    /// Advance past the next '(' at top level. Returns false at end of input.
    mutating func skipToOpenParen() -> Bool {
        while pos < bytes.count && bytes[pos] != 40 { pos += 1 }
        if pos >= bytes.count { return false }
        pos += 1
        return true
    }
    mutating func peekOpenParen() -> Bool {
        skipSpace()
        return pos < bytes.count && bytes[pos] == 40
    }
    mutating func expectOpen() throws {
        skipSpace()
        guard pos < bytes.count && bytes[pos] == 40 else { throw MeshError.parse("expected '(' at byte \(pos)") }
        pos += 1
    }
    mutating func readDecimal() -> Int? {
        skipSpace()
        var v = 0, any = false
        while pos < bytes.count, bytes[pos] >= 48 && bytes[pos] <= 57 { v = v * 10 + Int(bytes[pos] - 48); pos += 1; any = true }
        return any ? v : nil
    }
    mutating func readHex() throws -> Int {
        skipSpace()
        var v = 0, any = false
        while pos < bytes.count {
            let c = bytes[pos]
            let d: Int
            if c >= 48 && c <= 57 { d = Int(c - 48) }
            else if c >= 97 && c <= 102 { d = Int(c - 87) }
            else if c >= 65 && c <= 70 { d = Int(c - 55) }
            else { break }
            v = v * 16 + d; pos += 1; any = true
        }
        guard any else { throw MeshError.parse("expected hex number at byte \(pos)") }
        return v
    }
    mutating func readFloat() throws -> Double {
        skipSpace()
        let start = pos
        while pos < bytes.count {
            let c = bytes[pos]
            if (c >= 48 && c <= 57) || c == 43 || c == 45 || c == 46 || c == 101 || c == 69 || c == 100 || c == 68 { pos += 1 } else { break }
        }
        guard pos > start else { throw MeshError.parse("expected number at byte \(start)") }
        var str = String(decoding: bytes[start..<pos], as: UTF8.self)
        if str.contains("d") || str.contains("D") { str = str.replacingOccurrences(of: "d", with: "e").replacingOccurrences(of: "D", with: "e") }
        guard let v = Double(str) else { throw MeshError.parse("bad number '\(str)'") }
        return v
    }
    /// Reads "(a b c ...)" header of hex numbers.
    mutating func readHeaderHex() throws -> [Int] {
        try expectOpen()
        var out: [Int] = []
        while true {
            skipSpace()
            guard pos < bytes.count else { throw MeshError.parse("unterminated header") }
            if bytes[pos] == 41 { pos += 1; break }
            out.append(try readHex())
        }
        return out
    }
    mutating func readUntilClose() -> String {
        let start = pos
        var depth = 0
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 40 { depth += 1 }
            if c == 41 { if depth == 0 { break }; depth -= 1 }
            pos += 1
        }
        let s = String(decoding: bytes[start..<min(pos, bytes.count)], as: UTF8.self)
        if pos < bytes.count { pos += 1 }
        return s
    }
    /// Skip a balanced expression. If `fromInside`, we are already inside one open paren.
    mutating func skipBalanced(fromInside: Bool = false) throws {
        var depth = fromInside ? 1 : 0
        if !fromInside {
            skipSpace()
            guard pos < bytes.count, bytes[pos] == 40 else { return }
        }
        var inString = false
        while pos < bytes.count {
            let c = bytes[pos]; pos += 1
            if inString { if c == 34 { inString = false }; continue }
            if c == 34 { inString = true; continue }
            if c == 40 { depth += 1 }
            else if c == 41 { depth -= 1; if depth == 0 { return } }
        }
    }
    mutating func finishSection(binary: Bool, index: Int) throws {
        if binary {
            // ")End of Binary Section   3010)"
            let marker = Array("End of Binary Section".utf8)
            guard let r = find(marker, from: pos) else { throw MeshError.parse("missing end of binary section \(index)") }
            pos = r + marker.count
            while pos < bytes.count && bytes[pos] != 41 { pos += 1 }
            pos += 1
        } else {
            // close body ')' and section ')'
            try skipBalanced(fromInside: true)
            try skipBalanced(fromInside: true)
        }
    }
    mutating func skipBinarySection(index: Int) throws {
        let marker = Array("End of Binary Section".utf8)
        guard let r = find(marker, from: pos) else { throw MeshError.parse("missing end of binary section \(index)") }
        pos = r + marker.count
        while pos < bytes.count && bytes[pos] != 41 { pos += 1 }
        pos += 1
    }
    func find(_ needle: [UInt8], from: Int) -> Int? {
        guard needle.count > 0, bytes.count >= needle.count else { return nil }
        var i = from
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }
    mutating func readBinaryInt32() throws -> Int32 {
        guard pos + 4 <= bytes.count else { throw MeshError.parse("truncated binary data") }
        let v = UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
        pos += 4
        return Int32(bitPattern: v)
    }
    mutating func readBinaryFloat32() throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try readBinaryInt32()))
    }
    mutating func readBinaryFloat64() throws -> Double {
        guard pos + 8 <= bytes.count else { throw MeshError.parse("truncated binary data") }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(bytes[pos + k]) << (8 * UInt64(k)) }
        pos += 8
        return Double(bitPattern: v)
    }
}
