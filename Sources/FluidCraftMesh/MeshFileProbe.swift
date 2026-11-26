import Foundation

/// What a mesh file's header says, read without converting it. FluidCraft uses this to pick
/// the converter: OpenFOAM's (`fluentMeshToFoam`, `gmshToFoam`) where they read the file,
/// FluidCraft's own reader only where they cannot (binary files, 2D Gmsh meshes).
public enum MeshFileProbe {
    /// A Fluent mesh/case file: dimension, binary sections, and zone types from sections
    /// 39/45 (OpenFOAM's converters turn `velocity-inlet` etc. into plain patches).
    public struct Fluent: Sendable {
        public var dimension = 3
        /// Has binary (20xx/30xx) sections, which OpenFOAM's Fluent converters cannot read.
        public var binary = false
        /// Fluent zone name → Fluent zone type (`wall`, `velocity-inlet`, `solid`, …).
        public var zoneTypes: [String: String] = [:]
        /// An HDF5 (`.cas.h5`/`.msh.h5`) file.
        public var hdf5 = false
    }

    /// A Gmsh `.msh` file: version, binary flag and the number of volume entities (v4).
    public struct Gmsh: Sendable {
        public var version = 2.2
        public var binary = false
        /// Number of volume entities (v4 `$Entities`); nil when the file does not say (v2).
        public var volumes: Int?
        /// A physical tag names groups of two dimensions (say surface 1 "wall" and volume 1
        /// "fluid"); gmshToFoam looks names up by tag alone and would mix them up.
        public var sharedPhysicalTags = false
    }

    public static func fluent(_ url: URL) throws -> Fluent {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw MeshError.io("cannot read \(url.path): \(error.localizedDescription)") }
        return fluent(data: data)
    }

    /// Top-level sections are found by tracking parenthesis depth (quoted text skipped).
    /// Scanning stops at the first binary section: its payload is not text.
    public static func fluent(data: Data) -> Fluent {
        var info = Fluent()
        if data.starts(with: [0x89, 0x48, 0x44, 0x46]) { info.hdf5 = true; return info }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0, depth = 0
            func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
            func decimal(_ j: inout Int) -> Int? {
                var v = 0, any = false
                while j < n, b[j] >= 48, b[j] <= 57 { v = v * 10 + Int(b[j] - 48); j += 1; any = true }
                return any ? v : nil
            }
            func token(_ j: inout Int) -> String {
                while j < n, isSpace(b[j]) { j += 1 }
                let s = j
                while j < n, !isSpace(b[j]), b[j] != 40, b[j] != 41 { j += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: b[s..<j]), as: UTF8.self)
            }
            while i < n {
                let c = b[i]
                if c == 34 {   // quoted text
                    i += 1
                    while i < n, b[i] != 34 { i += 1 }
                    i += 1; continue
                }
                if c == 41 { depth = max(0, depth - 1); i += 1; continue }
                guard c == 40 else { i += 1; continue }
                depth += 1
                if depth != 1 { i += 1; continue }
                var j = i + 1
                guard let index = decimal(&j) else { i += 1; continue }
                if index >= 2000 { info.binary = true; return }
                switch index {
                case 2:
                    while j < n, isSpace(b[j]) { j += 1 }
                    if let d = decimal(&j) { info.dimension = d }
                case 39, 45:
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == 40 {
                        j += 1
                        _ = token(&j)                       // zone id
                        let type = token(&j), name = token(&j)
                        if !name.isEmpty { info.zoneTypes[name] = type.lowercased() }
                    }
                default: break
                }
                i += 1
            }
        }
        return info
    }

    public static func gmsh(_ url: URL) throws -> Gmsh {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw MeshError.io("cannot read \(url.path)") }
        defer { try? h.close() }
        // the header and $Entities come first; 4 MB is plenty even with many physical names
        let d = (try? h.read(upToCount: 4 << 20)) ?? Data()
        return gmsh(header: d)
    }

    public static func gmsh(header d: Data) -> Gmsh {
        var info = Gmsh()
        let text = String(decoding: d, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        while let l = lines.next() {
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "$MeshFormat", let f = lines.next() {
                let p = f.split(separator: " ")
                if p.count >= 2 { info.version = Double(p[0]) ?? 2.2; info.binary = p[1] == "1" }
            } else if t == "$PhysicalNames", let c = lines.next(), let n = Int(c.trimmingCharacters(in: .whitespacesAndNewlines)) {
                var dimOfTag: [Int: Int] = [:]
                for _ in 0..<n {
                    guard let e = lines.next() else { break }
                    let p = e.split(separator: " ")
                    guard p.count >= 2, let d = Int(p[0]), let tag = Int(p[1]) else { continue }
                    if let other = dimOfTag[tag], other != d { info.sharedPhysicalTags = true }
                    dimOfTag[tag] = d
                }
            } else if t == "$Entities" {
                // binary files store the counts as size_t; only the ASCII form is read here
                if !info.binary, let f = lines.next() {
                    let p = f.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if p.count >= 4 { info.volumes = p[3] }
                }
                break
            } else if t == "$Nodes" || t == "$Elements" {
                break
            }
        }
        return info
    }
}
