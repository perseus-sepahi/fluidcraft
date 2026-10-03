import Foundation

/// Fast whitespace-delimited token reader over a NUL-terminated byte buffer.
struct ByteParser {
    private(set) var bytes: [UInt8]
    var pos = 0

    init(data: Data) {
        var b = [UInt8](data)
        b.append(0)
        bytes = b
    }

    var atEnd: Bool { pos >= bytes.count - 1 }

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    mutating func skipSpace() {
        while pos < bytes.count - 1 && ByteParser.isSpace(bytes[pos]) { pos += 1 }
    }
    mutating func token() -> String? {
        skipSpace()
        guard !atEnd else { return nil }
        let s = pos
        while pos < bytes.count - 1 && !ByteParser.isSpace(bytes[pos]) { pos += 1 }
        return String(decoding: bytes[s..<pos], as: UTF8.self)
    }
    /// Rest of the current line (excluding the newline), trimmed.
    mutating func line() -> String {
        let s = pos
        while pos < bytes.count - 1 && bytes[pos] != 10 { pos += 1 }
        let str = String(decoding: bytes[s..<pos], as: UTF8.self)
        if pos < bytes.count - 1 { pos += 1 }
        return str.trimmingCharacters(in: .whitespaces)
    }
    mutating func int() throws -> Int {
        skipSpace()
        var neg = false
        if bytes[pos] == 45 { neg = true; pos += 1 } else if bytes[pos] == 43 { pos += 1 }
        var v = 0, any = false
        while bytes[pos] >= 48 && bytes[pos] <= 57 { v = v * 10 + Int(bytes[pos] - 48); pos += 1; any = true }
        guard any else { throw MeshError.parse("expected integer at byte \(pos)") }
        return neg ? -v : v
    }
    mutating func double() throws -> Double {
        skipSpace()
        let start = pos
        let v: Double = bytes.withUnsafeBufferPointer { buf -> Double in
            let base = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self)
            var end: UnsafeMutablePointer<CChar>? = nil
            let r = strtod(base + start, &end)
            if let end { pos = base.distance(to: UnsafePointer(end)) }
            return r
        }
        guard pos > start else { throw MeshError.parse("expected number at byte \(start)") }
        return v
    }
    /// Advance to the line starting with `marker` (e.g. "$Nodes"); returns false if absent.
    mutating func seek(_ marker: String) -> Bool {
        let m = Array(marker.utf8)
        while !atEnd {
            skipSpace()
            if matches(m) {
                pos += m.count
                return true
            }
            while pos < bytes.count - 1 && bytes[pos] != 10 { pos += 1 }
        }
        return false
    }
    func matches(_ m: [UInt8]) -> Bool {
        guard pos + m.count <= bytes.count - 1 else { return false }
        for k in 0..<m.count where bytes[pos + k] != m[k] { return false }
        return true
    }
    mutating func skip(bytes n: Int) { pos += n }
    mutating func expectChar(_ c: Character) throws {
        skipSpace()
        guard bytes[pos] == c.asciiValue else { throw MeshError.parse("expected '\(c)' at byte \(pos)") }
        pos += 1
    }
    var current: UInt8 { bytes[pos] }
}
