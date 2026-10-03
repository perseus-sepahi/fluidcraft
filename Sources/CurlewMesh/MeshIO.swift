import Foundation

public enum MeshFormat: String, CaseIterable, Sendable {
    case fluent, gmsh, openfoam, curlew

    public static func detect(_ url: URL) -> MeshFormat? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .openfoam }
        switch url.pathExtension.lowercased() {
        case "cas", "cas.h5": return .fluent
        case "msh":
            // Gmsh files start with $MeshFormat; Fluent files with '('.
            if let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 256) {
                let s = String(decoding: d, as: UTF8.self)
                return s.contains("$MeshFormat") ? .gmsh : .fluent
            }
            return .fluent
        case "crlmesh": return .curlew
        default: return nil
        }
    }
}

public enum MeshIO {
    public static func read(url: URL, depth2D: Double = 1) throws -> Mesh {
        guard let fmt = MeshFormat.detect(url) else { throw MeshError.unsupported("unknown mesh file type '\(url.pathExtension)'") }
        switch fmt {
        case .fluent: return try FluentMeshReader.read(url: url, depth2D: depth2D)
        case .gmsh: return try GmshReader.read(url: url, depth2D: depth2D)
        case .openfoam: return try FoamMeshReader.read(url: url)
        case .curlew: return try readBinary(Data(contentsOf: url))
        }
    }

    // MARK: Native binary archive (used inside .curlew case packages)

    static let magic: UInt32 = 0x4D4C5243 // "CRLM"

    public static func writeBinary(_ m: Mesh) throws -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i64(_ v: Int) { var x = Int64(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func arr<T>(_ a: [T]) { i64(a.count); a.withUnsafeBytes { d.append(contentsOf: $0) } }
        u32(magic); u32(1)
        i64(m.nCells)
        var pts = [Double](); pts.reserveCapacity(m.nPoints * 3)
        for p in m.points { pts.append(p.x); pts.append(p.y); pts.append(p.z) }
        arr(pts)
        arr(m.faceNodeOffsets); arr(m.faceNodes); arr(m.owner); arr(m.neighbour); arr(m.cellZone)
        let meta = try JSONEncoder().encode(MeshMeta(boundaryZones: m.boundaryZones, cellZones: m.cellZones))
        i64(meta.count); d.append(meta)
        return d
    }

    struct MeshMeta: Codable { var boundaryZones: [BoundaryZone]; var cellZones: [CellZone] }

    public static func readBinary(_ d: Data) throws -> Mesh {
        var o = 0
        let bytes = [UInt8](d)
        func need(_ n: Int) throws { guard o + n <= bytes.count else { throw MeshError.parse("truncated mesh archive") } }
        func u32() throws -> UInt32 {
            try need(4)
            let v = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
            o += 4; return UInt32(littleEndian: v)
        }
        func i64() throws -> Int {
            try need(8)
            let v = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) }
            o += 8; return Int(Int64(littleEndian: v))
        }
        func arr<T>(_ t: T.Type) throws -> [T] {
            let n = try i64()
            let size = n * MemoryLayout<T>.stride
            try need(size)
            var out = [T](unsafeUninitializedCapacity: n) { buf, count in
                bytes.withUnsafeBytes { src in
                    memcpy(UnsafeMutableRawPointer(buf.baseAddress!), src.baseAddress! + o, size)
                }
                count = n
            }
            if n == 0 { out = [] }
            o += size
            return out
        }
        guard try u32() == magic else { throw MeshError.parse("not a Curlew mesh archive") }
        _ = try u32()
        let nCells = try i64()
        let pts = try arr(Double.self)
        var points = [Vec3](repeating: .zero, count: pts.count / 3)
        for i in 0..<points.count { points[i] = Vec3(pts[3 * i], pts[3 * i + 1], pts[3 * i + 2]) }
        let offs = try arr(Int32.self), nodes = try arr(Int32.self), own = try arr(Int32.self)
        let nei = try arr(Int32.self), cz = try arr(Int32.self)
        let metaLen = try i64()
        try need(metaLen)
        let meta = try JSONDecoder().decode(MeshMeta.self, from: Data(bytes[o..<(o + metaLen)]))
        return Mesh(points: points, faceNodeOffsets: offs, faceNodes: nodes, owner: own, neighbour: nei,
                    nCells: nCells, boundaryZones: meta.boundaryZones, cellZones: meta.cellZones, cellZone: cz)
    }
}
