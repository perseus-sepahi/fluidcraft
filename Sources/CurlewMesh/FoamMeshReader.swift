import Foundation
import Compression

/// Reader for OpenFOAM `constant/polyMesh` (ASCII or binary, optionally gzipped).
public enum FoamMeshReader {
    /// `url` may point at a case directory, its `constant` directory or `polyMesh` itself.
    /// With `preserveOrder`, cells and faces keep OpenFOAM's numbering, so `internalField`
    /// and patch lists of that case map one-to-one onto the Curlew mesh.
    public static func read(url: URL, preserveOrder: Bool = false) throws -> Mesh {
        var dir = url
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("constant/polyMesh").path) { dir = dir.appendingPathComponent("constant/polyMesh") }
        else if fm.fileExists(atPath: dir.appendingPathComponent("polyMesh").path) { dir = dir.appendingPathComponent("polyMesh") }

        func load(_ name: String) throws -> Data {
            let plain = dir.appendingPathComponent(name)
            if let d = try? Data(contentsOf: plain) { return d }
            let gz = dir.appendingPathComponent(name + ".gz")
            guard let z = try? Data(contentsOf: gz) else { throw MeshError.io("missing polyMesh/\(name)") }
            return try gunzip(z)
        }

        let points = try parseVectors(load("points"))
        let faces = try parseFaces(load("faces"))
        let owner = try parseLabels(load("owner"))
        let neighbour = try parseLabels(load("neighbour"))
        let patches = try parseBoundary(load("boundary"))

        let nCells = (owner.max().map { Int($0) } ?? -1) + 1
        var b = MeshBuilder()
        b.preserveOrder = preserveOrder
        b.points = points
        b.nCells = max(nCells, (neighbour.max().map { Int($0) } ?? -1) + 1)
        for f in 0..<neighbour.count { b.addFace(faces[f], c0: owner[f], c1: neighbour[f]) }
        // Cell zones (blockMesh block names, topoSet/setsToZones, snappyHexMesh zones); cells in
        // no zone stay in the default "fluid" zone.
        if let zd = try? load("cellZones"), let zones = try? parseCellZones(zd), !zones.isEmpty {
            var specs = [MeshBuilder.CellZoneSpec(name: "fluid", kind: .fluid)]
            var of = [Int32](repeating: 0, count: b.nCells)
            for z in zones {
                var idx = specs.firstIndex { $0.name == z.name } ?? -1
                if idx < 0 { specs.append(MeshBuilder.CellZoneSpec(name: z.name, kind: .fluid)); idx = specs.count - 1 }
                for c in z.cells where c >= 0 && Int(c) < b.nCells { of[Int(c)] = Int32(idx) }
            }
            b.cellZones = specs
            b.cellZoneOfCell = of
        }
        for p in patches {
            let kind: ZoneKind
            switch p.type {
            case "wall": kind = .wall
            case "empty": kind = .empty
            case "symmetryPlane", "symmetry", "wedge": kind = .symmetry
            case "cyclic", "cyclicAMI", "processor":
                throw MeshError.unsupported("OpenFOAM \(p.type) patch '\(p.name)'")
            default: kind = ZoneKind.guess(fromName: p.name)
            }
            let z = b.addZone(p.name, kind: kind)
            for f in p.start..<(p.start + p.count) { b.addFace(faces[f], c0: owner[f], c1: -1, zone: z) }
        }
        return try b.build()
    }

    // MARK: Parsing

    struct Header { var binary: Bool; var labelBytes: Int; var scalarBytes: Int; var className: String }

    static func header(_ p: inout ByteParser) throws -> Header {
        guard p.seek("FoamFile") else { throw MeshError.parse("FoamFile header missing") }
        var h = Header(binary: false, labelBytes: 4, scalarBytes: 8, className: "")
        try p.expectChar("{")
        var depth = 1   // v2606 headers carry a nested `meta { names (…); }` block
        while let t = p.token() {
            if t == "}" { depth -= 1; if depth == 0 { break }; continue }
            if t == "{" { depth += 1; continue }
            if depth > 1 { if p.line().contains("}") { depth -= 1 }; continue }
            let rest = p.line().trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
            if rest.hasPrefix("{") { if !rest.hasSuffix("}") { depth += 1 }; continue }   // a sub-dictionary
            switch t {
            case "format": h.binary = rest.hasPrefix("binary")
            case "class": h.className = rest
            case "arch":
                if rest.contains("label=64") { h.labelBytes = 8 }
                if rest.contains("scalar=32") { h.scalarBytes = 4 }
            default: break
            }
            if rest.hasSuffix("}") { depth -= 1; if depth == 0 { break } }
        }
        skipComments(&p)
        return h
    }

    static func skipComments(_ p: inout ByteParser) {
        while true {
            p.skipSpace()
            if p.matches(Array("//".utf8)) { _ = p.line(); continue }
            if p.matches(Array("/*".utf8)) {
                while !p.atEnd && !p.matches(Array("*/".utf8)) { p.skip(bytes: 1) }
                p.skip(bytes: 2); continue
            }
            break
        }
    }

    static func readBinaryLabel(_ p: inout ByteParser, _ size: Int) -> Int {
        var v: UInt64 = 0
        for k in 0..<size { v |= UInt64(p.bytes[p.pos + k]) << (8 * UInt64(k)) }
        p.skip(bytes: size)
        return size == 4 ? Int(Int32(bitPattern: UInt32(truncatingIfNeeded: v))) : Int(Int64(bitPattern: v))
    }
    static func readBinaryScalar(_ p: inout ByteParser, _ size: Int) -> Double {
        if size == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: readBinaryLabel(&p, 4)))) }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(p.bytes[p.pos + k]) << (8 * UInt64(k)) }
        p.skip(bytes: 8)
        return Double(bitPattern: v)
    }

    static func parseVectors(_ data: Data) throws -> [Vec3] {
        var p = ByteParser(data: data)
        let h = try header(&p)
        let n = try p.int()
        try p.expectChar("(")
        var out = [Vec3](repeating: .zero, count: n)
        if h.binary {
            for i in 0..<n {
                out[i] = Vec3(readBinaryScalar(&p, h.scalarBytes), readBinaryScalar(&p, h.scalarBytes), readBinaryScalar(&p, h.scalarBytes))
            }
        } else {
            for i in 0..<n {
                try p.expectChar("(")
                out[i] = Vec3(try p.double(), try p.double(), try p.double())
                try p.expectChar(")")
            }
        }
        return out
    }

    static func parseLabels(_ data: Data) throws -> [Int32] {
        var p = ByteParser(data: data)
        let h = try header(&p)
        let n = try p.int()
        p.skipSpace()
        if p.current == UInt8(ascii: "{") {
            // uniform list: N{value}
            p.skip(bytes: 1)
            let v = try p.int()
            return [Int32](repeating: Int32(v), count: n)
        }
        try p.expectChar("(")
        var out = [Int32](repeating: 0, count: n)
        for i in 0..<n { out[i] = Int32(h.binary ? readBinaryLabel(&p, h.labelBytes) : try p.int()) }
        return out
    }

    static func parseFaces(_ data: Data) throws -> [[Int32]] {
        var p = ByteParser(data: data)
        let h = try header(&p)
        if h.className.contains("faceCompactList") {
            // offsets list then flat label list
            let nOff = try p.int()
            try p.expectChar("(")
            var offsets = [Int](repeating: 0, count: nOff)
            for i in 0..<nOff { offsets[i] = h.binary ? readBinaryLabel(&p, h.labelBytes) : try p.int() }
            try p.expectChar(")")
            let nFlat = try p.int()
            try p.expectChar("(")
            var flat = [Int32](repeating: 0, count: nFlat)
            for i in 0..<nFlat { flat[i] = Int32(h.binary ? readBinaryLabel(&p, h.labelBytes) : try p.int()) }
            var faces: [[Int32]] = []
            faces.reserveCapacity(max(nOff - 1, 0))
            for f in 0..<max(nOff - 1, 0) { faces.append(Array(flat[offsets[f]..<offsets[f + 1]])) }
            return faces
        }
        let n = try p.int()
        try p.expectChar("(")
        var faces: [[Int32]] = []
        faces.reserveCapacity(n)
        for _ in 0..<n {
            let k = try p.int()
            try p.expectChar("(")
            var f = [Int32](repeating: 0, count: k)
            for j in 0..<k { f[j] = Int32(try p.int()) }
            try p.expectChar(")")
            faces.append(f)
        }
        return faces
    }

    struct Patch { var name: String; var type: String; var start: Int; var count: Int }

    static func parseBoundary(_ data: Data) throws -> [Patch] {
        var p = ByteParser(data: data)
        _ = try header(&p)
        let n = try p.int()
        try p.expectChar("(")
        var out: [Patch] = []
        for _ in 0..<n {
            skipComments(&p)
            guard let name = p.token() else { break }
            try p.expectChar("{")
            var patch = Patch(name: name, type: "patch", start: 0, count: 0)
            var depth = 1
            while depth > 0, let t = p.token() {
                if t == "}" { depth -= 1; continue }
                if t.hasSuffix("{") || t == "{" { depth += 1; continue }
                let value = p.line().trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
                if value.hasSuffix("}") { depth -= 1 }
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: " ;}"))
                switch t {
                case "type": patch.type = v
                case "nFaces": patch.count = Int(v) ?? 0
                case "startFace": patch.start = Int(v) ?? 0
                default: break
                }
            }
            out.append(patch)
        }
        return out
    }

    struct CellZoneEntry { var name: String; var cells: [Int32] }

    /// polyMesh/cellZones: `N ( name { type cellZone; cellLabels List<label> n (…); } … )`.
    static func parseCellZones(_ data: Data) throws -> [CellZoneEntry] {
        var p = ByteParser(data: data)
        let h = try header(&p)
        let n = try p.int()
        try p.expectChar("(")
        var out: [CellZoneEntry] = []
        for _ in 0..<n {
            skipComments(&p)
            guard let name = p.token() else { break }
            try p.expectChar("{")
            var cells: [Int32] = []
            while let t = p.token() {
                if t == "}" { break }
                if t == "cellLabels" {
                    skipComments(&p)
                    p.skipSpace()
                    if p.matches(Array("List<label>".utf8)) { p.skip(bytes: 11) }
                    let count = try p.int()
                    p.skipSpace()
                    if p.current == UInt8(ascii: "{") {
                        p.skip(bytes: 1)
                        let v = try p.int()
                        cells = [Int32](repeating: Int32(v), count: count)
                        try p.expectChar("}")
                    } else {
                        try p.expectChar("(")
                        cells = [Int32](repeating: 0, count: count)
                        for i in 0..<count { cells[i] = Int32(h.binary ? readBinaryLabel(&p, h.labelBytes) : try p.int()) }
                        try p.expectChar(")")
                    }
                    try p.expectChar(";")
                    continue
                }
                _ = p.line()   // type cellZone; and other entries
            }
            out.append(CellZoneEntry(name: name, cells: cells))
        }
        return out
    }

    /// Decompress a gzip stream (OpenFOAM `writeCompression on` files).
    public static func gunzipData(_ data: Data) throws -> Data { try gunzip(data) }

    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw MeshError.io("not a gzip stream") }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { let xlen = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 + xlen }
        if flags & 8 != 0 { while b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let isize = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let deflate = Data(b[i..<(b.count - 8)])
        var out = Data(count: max(isize, 1))
        let written = out.withUnsafeMutableBytes { dst in
            deflate.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, isize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == isize else { throw MeshError.io("gzip decompression failed") }
        return out
    }
}
