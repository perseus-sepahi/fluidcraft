import Foundation
import FluidCraftMesh

/// Values of one field entry: a uniform value or a list, `components` numbers per element.
public enum FoamFieldData: Sendable, Equatable {
    case uniform([Double])
    case list([Double], components: Int)

    public var components: Int {
        switch self { case .uniform(let v): return v.count; case .list(_, let c): return c }
    }

    /// Element count (nil for uniform).
    public var count: Int? {
        if case .list(let v, let c) = self { return v.count / max(c, 1) }
        return nil
    }

    public func scalars(count n: Int) -> [Double]? {
        switch self {
        case .uniform(let v): return v.count == 1 ? [Double](repeating: v[0], count: n) : nil
        case .list(let v, let c): return c == 1 && v.count == n ? v : nil
        }
    }

    public func vectors(count n: Int) -> [Vec3]? {
        switch self {
        case .uniform(let v): return v.count == 3 ? [Vec3](repeating: Vec3(v[0], v[1], v[2]), count: n) : nil
        case .list(let v, let c):
            guard c == 3, v.count == 3 * n else { return nil }
            return (0..<n).map { Vec3(v[3 * $0], v[3 * $0 + 1], v[3 * $0 + 2]) }
        }
    }
}

/// A field file (`volScalarField`, `volVectorField`, `surfaceScalarField`, …): the internal
/// field and each patch's `value` entry where one was written.
public struct FoamFieldFile: Sendable {
    public var className = ""
    public var internalField: FoamFieldData?
    public var patchValues: [String: FoamFieldData] = [:]
    public var patchTypes: [String: String] = [:]
}

/// Reader for OpenFOAM field files in ASCII or binary format, gzipped or not.
public enum FoamFieldReader {
    public static func read(url: URL) throws -> FoamFieldFile {
        if let d = try? Data(contentsOf: url) { return try parse(d) }
        let gz = url.appendingPathExtension("gz")
        guard let z = try? Data(contentsOf: gz) else { throw MeshError.io("missing field file \(url.lastPathComponent)") }
        return try parse(FoamMeshReader.gunzipData(z))
    }

    public static func parse(_ data: Data) throws -> FoamFieldFile {
        var p = Scanner(bytes: [UInt8](data))
        var out = FoamFieldFile()
        // header
        guard p.seekWord("FoamFile") else { throw MeshError.parse("FoamFile header missing") }
        try p.expect("{")
        while true {
            p.skipSpace()
            if p.peek == UInt8(ascii: "}") { p.pos += 1; break }
            guard let k = p.word() else { throw MeshError.parse("unterminated FoamFile header") }
            let v = p.rawUntilSemicolon()
            switch k {
            case "format": p.binary = v.contains("binary")
            case "class": out.className = v.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "arch":
                if v.contains("scalar=32") { p.scalarSize = 4 }
                if v.contains("label=64") { p.labelSize = 8 }
            default: break
            }
        }
        while true {
            p.skipSpace()
            if p.atEnd { break }
            guard let key = p.word() else { break }
            switch key {
            case "internalField":
                out.internalField = try p.value()
                p.skipTo(";")
            case "boundaryField":
                try p.expect("{")
                while true {
                    p.skipSpace()
                    if p.peek == UInt8(ascii: "}") { p.pos += 1; break }
                    guard let patch = p.word() else { throw MeshError.parse("unterminated boundaryField") }
                    try p.expect("{")
                    while true {
                        p.skipSpace()
                        if p.peek == UInt8(ascii: "}") { p.pos += 1; break }
                        guard let k = p.word() else { throw MeshError.parse("unterminated patch \(patch)") }
                        if k == "value" {
                            out.patchValues[patch] = try p.value()
                            p.skipTo(";")
                        } else if k == "type" {
                            out.patchTypes[patch] = p.rawUntilSemicolon().trimmingCharacters(in: .whitespaces)
                        } else {
                            try p.skipEntry()
                        }
                    }
                }
            default:
                try p.skipEntry()
            }
        }
        return out
    }

    struct Scanner {
        var b: [UInt8]
        var pos = 0
        var binary = false
        var scalarSize = 8
        var labelSize = 4

        init(bytes: [UInt8]) { b = bytes; b.append(0) }

        var atEnd: Bool { pos >= b.count - 1 }
        var peek: UInt8 { b[pos] }

        static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        static func isPunct(_ c: UInt8) -> Bool { c == 59 || c == 123 || c == 125 || c == 40 || c == 41 }

        mutating func skipSpace() {
            while !atEnd {
                if Scanner.isSpace(b[pos]) { pos += 1; continue }
                if b[pos] == 47 && b[pos + 1] == 47 { while !atEnd && b[pos] != 10 { pos += 1 }; continue }
                if b[pos] == 47 && b[pos + 1] == 42 {
                    pos += 2
                    while !atEnd && !(b[pos] == 42 && b[pos + 1] == 47) { pos += 1 }
                    pos += 2; continue
                }
                break
            }
        }

        mutating func word() -> String? {
            skipSpace()
            guard !atEnd else { return nil }
            if b[pos] == 34 {   // quoted
                let s = pos + 1
                pos += 1
                while !atEnd && b[pos] != 34 { pos += 1 }
                let w = String(decoding: b[s..<pos], as: UTF8.self)
                pos += 1
                return w
            }
            let s = pos
            while !atEnd && !Scanner.isSpace(b[pos]) && !Scanner.isPunct(b[pos]) { pos += 1 }
            if pos == s { pos += 1; return String(UnicodeScalar(b[s])) }
            return String(decoding: b[s..<pos], as: UTF8.self)
        }

        mutating func seekWord(_ w: String) -> Bool {
            while let t = word() { if t == w { return true } }
            return false
        }

        mutating func expect(_ c: Character) throws {
            skipSpace()
            guard b[pos] == c.asciiValue else { throw MeshError.parse("expected '\(c)' at byte \(pos)") }
            pos += 1
        }

        mutating func rawUntilSemicolon() -> String {
            let s = pos
            while !atEnd && b[pos] != 59 { pos += 1 }
            let v = String(decoding: b[s..<pos], as: UTF8.self)
            if !atEnd { pos += 1 }
            return v
        }

        mutating func skipTo(_ c: Character) {
            skipSpace()
            if !atEnd && b[pos] == c.asciiValue { pos += 1 }
        }

        mutating func number() throws -> Double {
            skipSpace()
            let start = pos
            let v: Double = b.withUnsafeBufferPointer { buf in
                let base = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self)
                var end: UnsafeMutablePointer<CChar>? = nil
                let r = strtod(base + start, &end)
                if let end { pos = base.distance(to: UnsafePointer(end)) }
                return r
            }
            guard pos > start else { throw MeshError.parse("expected a number at byte \(start)") }
            return v
        }

        mutating func element(_ comps: Int, into out: inout [Double]) throws {
            if comps == 1 { out.append(try number()); return }
            try expect("(")
            for _ in 0..<comps { out.append(try number()) }
            try expect(")")
        }

        /// `uniform X`, `uniform (x y z)`, `nonuniform List<T> N(...)` (ASCII or binary) or
        /// `nonuniform List<T> N{X}`.
        mutating func value() throws -> FoamFieldData {
            guard let kind = word() else { throw MeshError.parse("missing field value") }
            if kind == "uniform" {
                skipSpace()
                var v: [Double] = []
                if peek == UInt8(ascii: "(") {
                    pos += 1
                    while true { skipSpace(); if peek == UInt8(ascii: ")") { pos += 1; break }; v.append(try number()) }
                } else { v.append(try number()) }
                return .uniform(v)
            }
            guard kind == "nonuniform" else { throw MeshError.parse("unsupported field value '\(kind)'") }
            guard let type = word() else { throw MeshError.parse("missing list type") }
            let comps: Int
            switch type {
            case "List<scalar>": comps = 1
            case "List<vector>": comps = 3
            case "List<symmTensor>": comps = 6
            case "List<tensor>": comps = 9
            case "List<sphericalTensor>": comps = 1
            default: throw MeshError.parse("unsupported list type \(type)")
            }
            skipSpace()
            let n = Int(try number())
            skipSpace()
            if peek == UInt8(ascii: "{") {
                pos += 1
                var one: [Double] = []
                try element(comps, into: &one)
                try expect("}")
                var v: [Double] = []
                v.reserveCapacity(n * comps)
                for _ in 0..<n { v += one }
                return .list(v, components: comps)
            }
            try expect("(")
            var v: [Double] = []
            v.reserveCapacity(n * comps)
            if binary && n > 0 {
                let count = n * comps
                guard pos + count * scalarSize <= b.count - 1 else { throw MeshError.parse("truncated binary list") }
                b.withUnsafeBytes { raw in
                    for i in 0..<count {
                        if scalarSize == 8 { v.append(raw.loadUnaligned(fromByteOffset: pos + 8 * i, as: Double.self)) }
                        else { v.append(Double(raw.loadUnaligned(fromByteOffset: pos + 4 * i, as: Float.self))) }
                    }
                }
                pos += count * scalarSize
            } else {
                for _ in 0..<n { try element(comps, into: &v) }
            }
            try expect(")")
            return .list(v, components: comps)
        }

        /// Skip one dictionary entry (value up to `;`, or a `{ … }` sub-dictionary), stepping
        /// over binary lists by their declared size.
        mutating func skipEntry() throws {
            skipSpace()
            if peek == UInt8(ascii: "{") {
                pos += 1
                while true {
                    skipSpace()
                    if atEnd { return }
                    if peek == UInt8(ascii: "}") { pos += 1; return }
                    _ = word()
                    try skipEntry()
                }
            }
            var depth = 0
            while !atEnd {
                skipSpace()
                // verbatim string #{ … #}
                if peek == 35 && b[pos + 1] == 123 {
                    pos += 2
                    while !atEnd && !(b[pos] == 35 && b[pos + 1] == 125) { pos += 1 }
                    pos += 2
                    continue
                }
                let c = peek
                if c == 59 && depth == 0 { pos += 1; return }
                if c == 40 { depth += 1; pos += 1; continue }
                if c == 41 { depth -= 1; pos += 1; continue }
                if c == 123 { try skipEntry(); continue }
                let save = pos
                if let w = word(), w == "nonuniform" { pos = save; _ = try value(); continue }
            }
        }
    }
}

// MARK: - Time directories

public enum FoamTimes {
    /// Numeric time directory names in a case, ascending, with their values.
    public static func list(_ dir: URL) -> [(name: String, value: Double)] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.compactMap { n in Double(n).map { (n, $0) } }.sorted { $0.value < $1.value }
    }

    public static func latest(_ dir: URL) -> (name: String, value: Double)? { list(dir).last }
}
