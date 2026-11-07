import Foundation
import simd

// MARK: - CAD formats

/// Geometry file formats Curlew can mesh. B-rep formats (exact CAD) go through Gmsh's
/// OpenCASCADE kernel; triangulated formats are read here.
public enum CADFormat: String, CaseIterable, Sendable {
    case step, iges, brep, freecad, stl, obj, ply, off, threeMF = "3mf", gltf, amf, vtk
    /// Proprietary kernels (SolidWorks, CATIA, Parasolid, Creo/NX, Inventor, Solid Edge,
    /// Rhino, ACIS, JT): converted to STEP by an external converter the user configures.
    case native
    /// SolidCraft design (.sc), converted to exact STEP by SolidCraft's own command-line tool.
    case solidcraft

    public static func detect(_ url: URL) -> CADFormat? {
        switch url.pathExtension.lowercased() {
        case "step", "stp", "p21": return .step
        case "iges", "igs": return .iges
        case "brep", "brp": return .brep
        case "fcstd": return .freecad
        case "stl": return .stl
        case "obj": return .obj
        case "ply": return .ply
        case "off": return .off
        case "3mf": return .threeMF
        case "gltf", "glb": return .gltf
        case "amf": return .amf
        case "vtk": return .vtk
        case "sc", "solidcraft": return .solidcraft
        case _ where nativeExtensions.contains(url.pathExtension.lowercased()): return .native
        default: return nil
        }
    }

    /// Native formats of commercial CAD systems (need a converter).
    public static let nativeExtensions = ["sldprt", "sldasm", "catpart", "catproduct", "x_t", "x_b", "xmt_txt", "xmt_bin",
                                          "prt", "asm", "ipt", "iam", "par", "psm", "3dm", "sat", "sab", "jt", "neu", "ifc"]

    /// Every accepted file extension (for open panels).
    public static let extensions = ["step", "stp", "p21", "iges", "igs", "brep", "brp", "fcstd", "stl", "obj", "ply", "off",
                                    "3mf", "gltf", "glb", "amf", "vtk", "sc", "solidcraft"] + nativeExtensions

    /// Exact (B-rep) geometry that needs OpenCASCADE, as opposed to a triangulation.
    /// FreeCAD and native files are converted to B-rep first.
    public var isBRep: Bool { [.step, .iges, .brep, .freecad, .native, .solidcraft].contains(self) }

    public var displayName: String {
        switch self {
        case .step: return "STEP (AP203/AP214/AP242)"
        case .iges: return "IGES"
        case .brep: return "OpenCASCADE BREP"
        case .stl: return "STL (ASCII or binary)"
        case .obj: return "Wavefront OBJ"
        case .ply: return "Stanford PLY"
        case .off: return "OFF"
        case .threeMF: return "3D Manufacturing Format (3MF)"
        case .freecad: return "FreeCAD document"
        case .gltf: return "glTF 2.0 (.gltf/.glb)"
        case .amf: return "Additive Manufacturing Format (AMF)"
        case .vtk: return "VTK legacy polydata"
        case .native: return "native CAD format (needs a converter)"
        case .solidcraft: return "SolidCraft design (converted to STEP by SolidCraft)"
        }
    }
}

/// Length unit of the numbers in a CAD file; Curlew works in metres.
public enum CADUnit: String, Codable, CaseIterable, Sendable {
    case metre = "m", millimetre = "mm", centimetre = "cm", inch = "in", foot = "ft"
    public var toMetres: Double {
        switch self {
        case .metre: return 1
        case .millimetre: return 1e-3
        case .centimetre: return 1e-2
        case .inch: return 0.0254
        case .foot: return 0.3048
        }
    }
}

// MARK: - Triangulated surface

/// A closed (ideally) triangulated surface with named regions, e.g. an STL with several
/// `solid` blocks or an OBJ with groups. Regions become boundary patches.
public struct TriSurface: Sendable {
    public var points: [Vec3]
    /// Three point indices per triangle.
    public var triangles: [Int32]
    /// Region of each triangle (index into `regionNames`).
    public var triRegion: [Int32]
    public var regionNames: [String]

    public init(points: [Vec3] = [], triangles: [Int32] = [], triRegion: [Int32] = [], regionNames: [String] = []) {
        self.points = points; self.triangles = triangles; self.triRegion = triRegion; self.regionNames = regionNames
    }

    public var triangleCount: Int { triangles.count / 3 }

    @inline(__always) public func corners(_ t: Int) -> (Vec3, Vec3, Vec3) {
        (points[Int(triangles[3 * t])], points[Int(triangles[3 * t + 1])], points[Int(triangles[3 * t + 2])])
    }

    public var bounds: (min: Vec3, max: Vec3) {
        var lo = Vec3(.infinity, .infinity, .infinity), hi = -lo
        for p in points { lo = Vec3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z)); hi = Vec3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z)) }
        return (lo, hi)
    }

    public var area: Double {
        var a = 0.0
        for t in 0..<triangleCount { let (p, q, r) = corners(t); a += 0.5 * norm(cross(q - p, r - p)) }
        return a
    }

    /// Signed enclosed volume (positive for outward-oriented closed surfaces).
    public var signedVolume: Double {
        var v = 0.0
        for t in 0..<triangleCount { let (p, q, r) = corners(t); v += dot(p, cross(q, r)) / 6 }
        return v
    }

    public func scaled(by s: Double) -> TriSurface {
        var c = self
        if s != 1 { c.points = points.map { $0 * s } }
        return c
    }

    /// Edges used by other than exactly two triangles (0 for a watertight manifold surface).
    public var openOrNonManifoldEdges: Int {
        var count: [UInt64: Int] = [:]
        count.reserveCapacity(triangles.count)
        for t in 0..<triangleCount {
            for k in 0..<3 {
                let a = UInt64(triangles[3 * t + k]), b = UInt64(triangles[3 * t + (k + 1) % 3])
                count[Swift.min(a, b) << 32 | Swift.max(a, b), default: 0] += 1
            }
        }
        return count.values.filter { $0 != 2 }.count
    }

    /// Flip every triangle if the surface is inside-out (negative enclosed volume).
    public mutating func orientOutward() {
        guard signedVolume < 0 else { return }
        for t in 0..<triangleCount { triangles.swapAt(3 * t + 1, 3 * t + 2) }
    }

    /// Drop triangles with repeated corners or zero area.
    public mutating func removeDegenerate() {
        var tri: [Int32] = [], reg: [Int32] = []
        tri.reserveCapacity(triangles.count); reg.reserveCapacity(triRegion.count)
        for t in 0..<triangleCount {
            let a = triangles[3 * t], b = triangles[3 * t + 1], c = triangles[3 * t + 2]
            if a == b || b == c || a == c { continue }
            let (p, q, r) = corners(t)
            if norm(cross(q - p, r - p)) <= 0 { continue }
            tri += [a, b, c]; reg.append(triRegion[t])
        }
        triangles = tri; triRegion = reg
    }

    /// Merge points closer than `tolerance` (welds STL soup into a connected surface).
    public mutating func weld(tolerance: Double) {
        guard tolerance > 0, !points.isEmpty else { return }
        var map = [Int32](repeating: 0, count: points.count)
        var key: [SIMD3<Int64>: Int32] = [:]
        var out: [Vec3] = []
        let inv = 1 / tolerance
        for (i, p) in points.enumerated() {
            let k = SIMD3<Int64>(Int64((p.x * inv).rounded()), Int64((p.y * inv).rounded()), Int64((p.z * inv).rounded()))
            if let j = key[k] { map[i] = j } else { key[k] = Int32(out.count); map[i] = Int32(out.count); out.append(p) }
        }
        points = out
        for i in 0..<triangles.count { triangles[i] = map[Int(triangles[i])] }
        removeDegenerate()
    }

    /// Ray-parity point-in-solid test, majority of three skewed rays (robust to rays that
    /// graze an edge). Meaningful for closed surfaces.
    public func contains(_ p: Vec3) -> Bool {
        let dirs = [Vec3(1, 0.000123, 0.000317), Vec3(-0.000271, 1, 0.000193), Vec3(0.000157, -0.000229, 1)]
        var inside = 0
        for d in dirs where crossings(p, normalized(d)) % 2 == 1 { inside += 1 }
        return inside >= 2
    }

    private func crossings(_ o: Vec3, _ d: Vec3) -> Int {
        var n = 0
        for t in 0..<triangleCount {
            let (a, b, c) = corners(t)
            // Möller–Trumbore
            let e1 = b - a, e2 = c - a
            let h = cross(d, e2)
            let det = dot(e1, h)
            if abs(det) < 1e-300 { continue }
            let f = 1 / det
            let s = o - a
            let u = f * dot(s, h)
            if u < 0 || u > 1 { continue }
            let q = cross(s, e1)
            let v = f * dot(d, q)
            if v < 0 || u + v > 1 { continue }
            if f * dot(e2, q) > 0 { n += 1 }
        }
        return n
    }

    /// Distance from a point to the nearest triangle.
    public func distance(to p: Vec3) -> Double {
        var best = Double.infinity
        for t in 0..<triangleCount {
            let (a, b, c) = corners(t)
            best = Swift.min(best, TriSurface.pointTriangleDistance(p, a, b, c))
        }
        return best
    }

    static func pointTriangleDistance(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        // Ericson, Real-Time Collision Detection 5.1.5
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return norm(ap) }
        let bp = p - b
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return norm(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return norm(p - (a + v * ab)) }
        let cp = p - c
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return norm(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return norm(p - (a + w * ac)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return norm(p - (b + w * (c - b)))
        }
        let den = 1 / (va + vb + vc)
        let v = vb * den, w = vc * den
        return norm(p - (a + v * ab + w * ac))
    }

    /// An opening of an internal-flow body: a flat cap on the body's bounding box.
    public struct Opening: Sendable, Equatable {
        public var name: String
        public var triangles: [Int]
        public var normal: Vec3
        public var area: Double
        public var boxMin: Vec3
        public var boxMax: Vec3
    }

    /// Flat caps where an internal-flow body is cut off. Planar patches are grown across shared
    /// edges (normals within 0.5°, coplanar); a patch lying on one of the six bounding planes is
    /// a cap. Caps at the ends of the flow axis are inlets (minimum end) and outlets (maximum
    /// end); caps on the other bounding planes are extra outlets (an elbow's exit, a tee's
    /// branch) when they cover less than half of that face of the box, so the side walls of a
    /// rectangular duct are not mistaken for openings. Names: inlet, inlet2…, outlet, outlet2…,
    /// outlet_ymax, outlet_zmin2…
    public func detectOpenings(flowAxis: Int) -> [Opening] {
        let n = triangleCount
        guard n > 0 else { return [] }
        let (lo, hi) = bounds
        let size = hi - lo
        let L = Swift.max(size.x, size.y, size.z)
        let tol = 1e-5 * L
        var edgeTris: [UInt64: [Int]] = [:]
        for t in 0..<n {
            for k in 0..<3 {
                let a = UInt64(triangles[3 * t + k]), b = UInt64(triangles[3 * t + (k + 1) % 3])
                edgeTris[Swift.min(a, b) << 32 | Swift.max(a, b), default: []].append(t)
            }
        }
        let normals = (0..<n).map { t -> Vec3 in let (a, b, c) = corners(t); return normalized(cross(b - a, c - a)) }
        var patchOf = [Int](repeating: -1, count: n)
        var patches: [[Int]] = []
        for seed in 0..<n where patchOf[seed] < 0 {
            let n0 = normals[seed], p0 = corners(seed).0
            var stack = [seed], members: [Int] = []
            patchOf[seed] = patches.count
            while let t = stack.popLast() {
                members.append(t)
                for k in 0..<3 {
                    let a = UInt64(triangles[3 * t + k]), b = UInt64(triangles[3 * t + (k + 1) % 3])
                    for u in edgeTris[Swift.min(a, b) << 32 | Swift.max(a, b)] ?? [] where patchOf[u] < 0 {
                        let (ua, ub, uc) = corners(u)
                        if dot(normals[u], n0) > 0.99996 && abs(dot(ua - p0, n0)) < tol && abs(dot(ub - p0, n0)) < tol && abs(dot(uc - p0, n0)) < tol {
                            patchOf[u] = patches.count
                            stack.append(u)
                        }
                    }
                }
            }
            patches.append(members)
        }
        var out: [Opening] = []
        var counts: [String: Int] = [:]
        let axisName = ["x", "y", "z"]
        for members in patches {
            let nrm = normals[members[0]]
            guard let a = (0..<3).first(where: { abs(nrm[$0]) > 0.9999 }) else { continue }
            let maxSide = nrm[a] > 0
            var bmin = Vec3(repeating: .infinity), bmax = Vec3(repeating: -.infinity), area = 0.0
            for t in members {
                let (p, q, r) = corners(t)
                for v in [p, q, r] { bmin = simd_min(bmin, v); bmax = simd_max(bmax, v) }
                area += 0.5 * norm(cross(q - p, r - p))
            }
            let plane = maxSide ? hi[a] : lo[a]
            guard abs(bmin[a] - plane) < tol && abs(bmax[a] - plane) < tol else { continue }
            let base: String
            if a == flowAxis { base = maxSide ? "outlet" : "inlet" }
            else {
                let faceArea = size[(a + 1) % 3] * size[(a + 2) % 3]
                guard area < 0.5 * faceArea else { continue }
                base = "outlet_\(axisName[a])\(maxSide ? "max" : "min")"
            }
            let k = counts[base, default: 0] + 1
            counts[base] = k
            out.append(Opening(name: k == 1 ? base : "\(base)\(k)", triangles: members, normal: nrm, area: area, boxMin: bmin, boxMax: bmax))
        }
        return out
    }

    /// Internal flow: openings (see `detectOpenings`) become their own regions, everything
    /// else `wall`. Regions the file already names inlet/outlet are kept as they are.
    public func splitForInternalFlow(axis: Int) -> TriSurface {
        let named = regionNames.map { $0.lowercased() }
        if named.contains(where: { $0.contains("inlet") }) && named.contains(where: { $0.contains("outlet") }) { return self }
        let openings = detectOpenings(flowAxis: axis)
        var out = self
        out.regionNames = openings.map(\.name) + ["wall"]
        out.triRegion = [Int32](repeating: Int32(openings.count), count: triangleCount)
        for (i, o) in openings.enumerated() { for t in o.triangles { out.triRegion[t] = Int32(i) } }
        out.dropEmptyRegions()
        return out
    }

    /// Remove region names no triangle uses and renumber.
    public mutating func dropEmptyRegions() {
        var used = Set<Int32>(triRegion)
        if used.isEmpty { used = [] }
        var remap = [Int32](repeating: -1, count: regionNames.count)
        var names: [String] = []
        for (i, n) in regionNames.enumerated() where used.contains(Int32(i)) { remap[i] = Int32(names.count); names.append(n) }
        regionNames = names
        triRegion = triRegion.map { remap[Int($0)] }
    }

    /// Keep only the triangles of the given regions.
    public func subset(regions keep: Set<String>) -> TriSurface {
        var out = TriSurface(points: points, triangles: [], triRegion: [], regionNames: regionNames)
        for t in 0..<triangleCount where keep.contains(regionNames[Int(triRegion[t])]) {
            out.triangles += triangles[(3 * t)..<(3 * t + 3)]; out.triRegion.append(triRegion[t])
        }
        out.dropEmptyRegions()
        return out
    }

    /// Region names reduced to valid OpenFOAM/Gmsh words, made unique.
    public mutating func sanitizeRegionNames() {
        var seen = Set<String>()
        regionNames = regionNames.enumerated().map { i, n in
            var w = String(n.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if w.isEmpty || w.first!.isNumber { w = "region" + (w.isEmpty ? "\(i)" : "_" + w) }
            var u = w, k = 1
            while seen.contains(u) { k += 1; u = "\(w)\(k)" }
            seen.insert(u)
            return u
        }
    }
}

// MARK: - Readers

public enum SurfaceReader {
    /// Read any triangulated format (STL/OBJ/PLY/OFF/3MF). `unit` scales to metres; the
    /// result is welded, cleaned and oriented outward.
    public static func read(url: URL, unit: CADUnit = .metre) throws -> TriSurface {
        guard let fmt = CADFormat.detect(url) else { throw MeshError.unsupported("unknown surface format '\(url.pathExtension)'") }
        var s: TriSurface
        switch fmt {
        case .stl: s = try readSTL(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        case .obj: s = try readOBJ(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        case .ply: s = try readPLY(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        case .off: s = try readOFF(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        case .threeMF: s = try read3MF(url)
        case .gltf: s = try readGLTF(url)
        case .amf: s = try readAMF(url)
        case .vtk: s = try readVTK(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
        default: throw MeshError.unsupported("\(fmt.displayName) is exact CAD geometry: mesh it with Gmsh, or tessellate it first")
        }
        if s.triangleCount == 0 { throw MeshError.parse("\(url.lastPathComponent) contains no triangles") }
        // 3MF and AMF declare their unit and glTF is metres by definition; the rest use the caller's unit.
        s = s.scaled(by: [.threeMF, .amf, .gltf].contains(fmt) ? 1 : unit.toMetres)
        let (lo, hi) = s.bounds
        s.weld(tolerance: 1e-9 * Swift.max(norm(hi - lo), 1e-30))
        s.dropEmptyRegions()
        s.sanitizeRegionNames()
        s.orientOutward()
        return s
    }

    // MARK: STL

    public static func readSTL(_ data: Data, name: String = "body") throws -> TriSurface {
        let bytes = [UInt8](data)
        if bytes.count >= 84 {
            let n = Int(UInt32(bytes[80]) | UInt32(bytes[81]) << 8 | UInt32(bytes[82]) << 16 | UInt32(bytes[83]) << 24)
            let looksASCII = bytes.prefix(5).elementsEqual(Array("solid".utf8)) && bytes.prefix(1024).contains(UInt8(ascii: "\n"))
                && String(decoding: bytes.prefix(2048), as: UTF8.self).contains("facet")
            if 84 + 50 * n == bytes.count && !(looksASCII && n == 0) { return binarySTL(bytes, count: n, name: name) }
        }
        return try asciiSTL(bytes, name: name)
    }

    static func binarySTL(_ b: [UInt8], count n: Int, name: String) -> TriSurface {
        var s = TriSurface(regionNames: [name])
        s.points.reserveCapacity(3 * n); s.triangles.reserveCapacity(3 * n)
        b.withUnsafeBytes { raw in
            for t in 0..<n {
                let o = 84 + 50 * t + 12
                for k in 0..<3 {
                    let x = raw.loadUnaligned(fromByteOffset: o + 12 * k, as: Float32.self)
                    let y = raw.loadUnaligned(fromByteOffset: o + 12 * k + 4, as: Float32.self)
                    let z = raw.loadUnaligned(fromByteOffset: o + 12 * k + 8, as: Float32.self)
                    s.triangles.append(Int32(s.points.count))
                    s.points.append(Vec3(Double(x), Double(y), Double(z)))
                }
                s.triRegion.append(0)
            }
        }
        return s
    }

    static func asciiSTL(_ b: [UInt8], name: String) throws -> TriSurface {
        var s = TriSurface()
        var p = ByteParser(bytes: b)
        var region: Int32 = -1
        var corner = 0
        while let t = p.token() {
            switch t {
            case "solid":
                // A one-word solid name is a region name ("inlet", "wing"); exporter banners
                // such as "Created by Gmsh" or "ascii" are not, and the file name is used.
                let rest = p.line().trimmingCharacters(in: .whitespaces)
                let banner = rest.isEmpty || rest.contains(" ") || ["ascii", "binary", "stl", "solid"].contains(rest.lowercased())
                s.regionNames.append(banner ? (s.regionNames.isEmpty ? name : "\(name)\(s.regionNames.count + 1)") : rest)
                region = Int32(s.regionNames.count - 1)
            case "vertex":
                if region < 0 { s.regionNames.append(name); region = 0 }
                let x = try p.double(), y = try p.double(), z = try p.double()
                s.triangles.append(Int32(s.points.count))
                s.points.append(Vec3(x, y, z))
                corner += 1
                if corner == 3 { s.triRegion.append(region); corner = 0 }
            case "endfacet":
                if corner != 0 { throw MeshError.parse("STL facet with \(corner) vertices") }
            default: break
            }
        }
        return s
    }

    // MARK: OBJ

    public static func readOBJ(_ data: Data, name: String = "body") throws -> TriSurface {
        var s = TriSurface()
        var region: Int32 = -1
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0] {
            case "v":
                guard parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) else { throw MeshError.parse("bad OBJ vertex: \(line)") }
                s.points.append(Vec3(x, y, z))
            case "g", "o":
                let n = parts.count > 1 ? parts[1...].joined(separator: "_") : "group\(s.regionNames.count)"
                if let i = s.regionNames.firstIndex(of: n) { region = Int32(i) } else { s.regionNames.append(n); region = Int32(s.regionNames.count - 1) }
            case "f":
                if region < 0 { s.regionNames.append(name); region = 0 }
                var idx: [Int32] = []
                for v in parts.dropFirst() {
                    guard let i = Int(v.split(separator: "/", omittingEmptySubsequences: false).first ?? "") else { throw MeshError.parse("bad OBJ face: \(line)") }
                    let j = i > 0 ? i - 1 : s.points.count + i
                    guard j >= 0 && j < s.points.count else { throw MeshError.parse("OBJ face index out of range: \(line)") }
                    idx.append(Int32(j))
                }
                for k in stride(from: 1, to: idx.count - 1, by: 1) {
                    s.triangles += [idx[0], idx[k], idx[k + 1]]; s.triRegion.append(region)
                }
            default: break
            }
        }
        return s
    }

    // MARK: OFF

    public static func readOFF(_ data: Data, name: String = "body") throws -> TriSurface {
        var p = ByteParser(data: data)
        guard let magic = p.token(), magic.hasSuffix("OFF") else { throw MeshError.parse("not an OFF file") }
        let nv = try p.int(), nf = try p.int(); _ = try p.int()
        var s = TriSurface(regionNames: [name])
        for _ in 0..<nv { s.points.append(Vec3(try p.double(), try p.double(), try p.double())) }
        for _ in 0..<nf {
            let n = try p.int()
            var idx: [Int32] = []
            for _ in 0..<n { idx.append(Int32(try p.int())) }
            _ = p.line()   // optional colour
            for k in stride(from: 1, to: idx.count - 1, by: 1) { s.triangles += [idx[0], idx[k], idx[k + 1]]; s.triRegion.append(0) }
        }
        return s
    }

    // MARK: PLY

    public static func readPLY(_ data: Data, name: String = "body") throws -> TriSurface {
        let b = [UInt8](data)
        guard let end = findHeaderEnd(b) else { throw MeshError.parse("PLY header not terminated") }
        let header = String(decoding: b[0..<end.headerEnd], as: UTF8.self)
        struct Element { var name: String; var count: Int; var props: [(name: String, type: String, listCount: String?)] }
        var elements: [Element] = []
        var format = "ascii"
        for line in header.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let w = line.split(separator: " ").map(String.init)
            guard let k = w.first else { continue }
            if k == "format", w.count > 1 { format = w[1] }
            if k == "element", w.count > 2 { elements.append(Element(name: w[1], count: Int(w[2]) ?? 0, props: [])) }
            if k == "property", w.count > 2, !elements.isEmpty {
                if w[1] == "list", w.count > 4 { elements[elements.count - 1].props.append((w[4], w[3], w[2])) }
                else { elements[elements.count - 1].props.append((w[2], w[1], nil)) }
            }
        }
        var s = TriSurface(regionNames: [name])
        let little = format == "binary_little_endian"
        if format == "ascii" {
            var p = ByteParser(bytes: Array(b[end.dataStart...]))
            for e in elements {
                for _ in 0..<e.count {
                    var vals: [Double] = []
                    var list: [Int32] = []
                    for pr in e.props {
                        if pr.listCount != nil {
                            let n = try p.int()
                            for _ in 0..<n { list.append(Int32(try p.int())) }
                        } else { vals.append(try p.double()) }
                    }
                    try plyStore(e.name, e.props.map(\.name), vals, list, &s)
                }
            }
        } else if format == "binary_little_endian" || format == "binary_big_endian" {
            var o = end.dataStart
            func scalar(_ type: String) throws -> Double {
                let sizes: [String: Int] = ["char": 1, "int8": 1, "uchar": 1, "uint8": 1, "short": 2, "int16": 2, "ushort": 2, "uint16": 2,
                                            "int": 4, "int32": 4, "uint": 4, "uint32": 4, "float": 4, "float32": 4, "double": 8, "float64": 8]
                guard let n = sizes[type], o + n <= b.count else { throw MeshError.parse("PLY: bad property type \(type) or truncated data") }
                var raw: UInt64 = 0
                for k in 0..<n { raw |= UInt64(b[o + (little ? k : n - 1 - k)]) << (8 * UInt64(k)) }
                o += n
                switch type {
                case "char", "int8": return Double(Int8(truncatingIfNeeded: raw))
                case "short", "int16": return Double(Int16(truncatingIfNeeded: raw))
                case "int", "int32": return Double(Int32(truncatingIfNeeded: raw))
                case "float", "float32": return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
                case "double", "float64": return Double(bitPattern: raw)
                default: return Double(raw)
                }
            }
            for e in elements {
                for _ in 0..<e.count {
                    var vals: [Double] = []
                    var list: [Int32] = []
                    for pr in e.props {
                        if let lc = pr.listCount {
                            let n = Int(try scalar(lc))
                            for _ in 0..<n { list.append(Int32(try scalar(pr.type))) }
                        } else { vals.append(try scalar(pr.type)) }
                    }
                    try plyStore(e.name, e.props.map(\.name), vals, list, &s)
                }
            }
        } else { throw MeshError.unsupported("PLY format \(format)") }
        return s
    }

    private static func plyStore(_ element: String, _ names: [String], _ vals: [Double], _ list: [Int32], _ s: inout TriSurface) throws {
        if element == "vertex" {
            let scalarNames = names.filter { _ in true }
            func v(_ n: String) -> Double { scalarNames.firstIndex(of: n).flatMap { $0 < vals.count ? vals[$0] : nil } ?? 0 }
            s.points.append(Vec3(v("x"), v("y"), v("z")))
        } else if element == "face" {
            for k in stride(from: 1, to: list.count - 1, by: 1) { s.triangles += [list[0], list[k], list[k + 1]]; s.triRegion.append(0) }
        }
    }

    private static func findHeaderEnd(_ b: [UInt8]) -> (headerEnd: Int, dataStart: Int)? {
        let marker = Array("end_header".utf8)
        guard b.count > marker.count else { return nil }
        for i in 0...(b.count - marker.count) where b[i] == marker[0] && Array(b[i..<(i + marker.count)]) == marker {
            var j = i + marker.count
            while j < b.count && (b[j] == 0x0D || b[j] == 0x20) { j += 1 }
            if j < b.count && b[j] == 0x0A { j += 1 }
            return (i, j)
        }
        return nil
    }

    // MARK: 3MF

    /// 3MF is a zip; the mesh lives in `3D/3dmodel.model`. Each `<object>` becomes a region.
    /// The result is in metres (3MF declares its unit).
    public static func read3MF(_ url: URL) throws -> TriSurface {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, "3D/3dmodel.model"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { throw MeshError.parse("\(url.lastPathComponent): no 3D/3dmodel.model inside the 3MF package") }
        let parser = ThreeMFParser()
        let x = XMLParser(data: data)
        x.delegate = parser
        guard x.parse() else { throw MeshError.parse("3MF XML: \(x.parserError?.localizedDescription ?? "invalid")") }
        return parser.surface.scaled(by: parser.unitScale)
    }
}

private final class ThreeMFParser: NSObject, XMLParserDelegate {
    var surface = TriSurface()
    var base: Int32 = 0
    var region: Int32 = 0
    /// Metres per file unit (3MF's default unit is the millimetre).
    var unitScale = 1e-3

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name.split(separator: ":").last.map(String.init) ?? name {
        case "model":
            switch a["unit"] ?? "millimeter" {
            case "micron": unitScale = 1e-6
            case "centimeter": unitScale = 1e-2
            case "inch": unitScale = 0.0254
            case "foot": unitScale = 0.3048
            case "meter": unitScale = 1
            default: unitScale = 1e-3
            }
        case "object":
            surface.regionNames.append(a["name"] ?? "object\(a["id"] ?? "\(surface.regionNames.count + 1)")")
            region = Int32(surface.regionNames.count - 1)
            base = Int32(surface.points.count)
        case "vertex":
            surface.points.append(Vec3(Double(a["x"] ?? "0") ?? 0, Double(a["y"] ?? "0") ?? 0, Double(a["z"] ?? "0") ?? 0))
        case "triangle":
            if surface.regionNames.isEmpty { surface.regionNames = ["body"] }
            let v = ["v1", "v2", "v3"].map { base + Int32(a[$0] ?? "0")! }
            surface.triangles += v
            surface.triRegion.append(region)
        default: break
        }
    }
}

// MARK: - glTF, AMF, VTK

extension SurfaceReader {
    /// glTF 2.0 (JSON + .bin/data URI, or binary .glb): triangle primitives of every mesh in the
    /// default scene with their node transforms; one region per mesh. Metres by definition.
    public static func readGLTF(_ url: URL) throws -> TriSurface {
        let data = try Data(contentsOf: url)
        var json = data
        var bin: Data? = nil
        if data.count > 12, data.prefix(4) == Data("glTF".utf8) {
            var o = 12
            func u32(_ at: Int) -> Int { Int(UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24) }
            while o + 8 <= data.count {
                let len = u32(o), type = u32(o + 4)
                let chunk = data.subdata(in: (o + 8)..<min(o + 8 + len, data.count))
                if type == 0x4E4F534A { json = chunk } else if type == 0x004E4942 { bin = chunk }
                o += 8 + len
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw MeshError.parse("glTF: invalid JSON") }
        let buffers: [Data] = try ((root["buffers"] as? [[String: Any]]) ?? []).enumerated().map { i, b in
            if let uri = b["uri"] as? String {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") { return Data(base64Encoded: String(uri[uri.index(after: comma)...])) ?? Data() }
                return try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(uri.removingPercentEncoding ?? uri))
            }
            guard i == 0, let bin else { throw MeshError.parse("glTF: buffer \(i) has no data") }
            return bin
        }
        let views = (root["bufferViews"] as? [[String: Any]]) ?? []
        let accessors = (root["accessors"] as? [[String: Any]]) ?? []
        func read(_ ai: Int) throws -> [Double] {
            let a = accessors[ai]
            guard let vi = a["bufferView"] as? Int else { return [] }
            let v = views[vi]
            let buf = buffers[v["buffer"] as? Int ?? 0]
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? "SCALAR"] ?? 1
            let ct = a["componentType"] as? Int ?? 5126
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ct] ?? 4
            let count = a["count"] as? Int ?? 0
            let stride = (v["byteStride"] as? Int) ?? comps * size
            let base = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            var out: [Double] = []
            out.reserveCapacity(count * comps)
            try buf.withUnsafeBytes { raw in
                guard base + (count - 1) * stride + comps * size <= raw.count || count == 0 else { throw MeshError.parse("glTF: accessor out of range") }
                for i in 0..<count {
                    for c in 0..<comps {
                        let at = base + i * stride + c * size
                        switch ct {
                        case 5126: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: Float.self)))
                        case 5125: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                        case 5123: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                        case 5121: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self)))
                        case 5122: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)))
                        default: out.append(Double(raw.loadUnaligned(fromByteOffset: at, as: Int8.self)))
                        }
                    }
                }
            }
            return out
        }
        typealias M4 = [Double]   // column-major 4x4
        func mul(_ a: M4, _ b: M4) -> M4 { (0..<16).map { k in let r = k % 4, c = k / 4; return (0..<4).reduce(0.0) { $0 + a[$1 * 4 + r] * b[c * 4 + $1] } } }
        func local(_ n: [String: Any]) -> M4 {
            if let m = n["matrix"] as? [Double], m.count == 16 { return m }
            let t = n["translation"] as? [Double] ?? [0, 0, 0], q = n["rotation"] as? [Double] ?? [0, 0, 0, 1], sc = n["scale"] as? [Double] ?? [1, 1, 1]
            let (x, y, z, w) = (q[0], q[1], q[2], q[3])
            let r: [Double] = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
                               2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
                               2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0, 0, 0, 0, 1]
            var m = r
            for c in 0..<3 { for rr in 0..<3 { m[c * 4 + rr] *= sc[c] } }
            m[12] = t[0]; m[13] = t[1]; m[14] = t[2]
            return m
        }
        let nodes = (root["nodes"] as? [[String: Any]]) ?? []
        let meshes = (root["meshes"] as? [[String: Any]]) ?? []
        var s = TriSurface()
        func addMesh(_ mi: Int, _ m: M4) throws {
            let mesh = meshes[mi]
            let name = (mesh["name"] as? String) ?? "mesh\(mi)"
            s.regionNames.append(name)
            let region = Int32(s.regionNames.count - 1)
            for prim in (mesh["primitives"] as? [[String: Any]]) ?? [] where (prim["mode"] as? Int ?? 4) == 4 {
                guard let pa = (prim["attributes"] as? [String: Any])?["POSITION"] as? Int else { continue }
                let pos = try read(pa)
                let base = Int32(s.points.count)
                for i in stride(from: 0, to: pos.count, by: 3) {
                    let (x, y, z) = (pos[i], pos[i + 1], pos[i + 2])
                    s.points.append(Vec3(m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]))
                }
                let idx = try (prim["indices"] as? Int).map(read) ?? (0..<(pos.count / 3)).map(Double.init)
                for i in stride(from: 0, to: idx.count - 2, by: 3) {
                    s.triangles += [base + Int32(idx[i]), base + Int32(idx[i + 1]), base + Int32(idx[i + 2])]
                    s.triRegion.append(region)
                }
            }
        }
        func visit(_ ni: Int, _ parent: M4, depth: Int) throws {
            guard depth < 64, ni < nodes.count else { return }
            let n = nodes[ni]
            let m = mul(parent, local(n))
            if let mi = n["mesh"] as? Int { try addMesh(mi, m) }
            for c in (n["children"] as? [Int]) ?? [] { try visit(c, m, depth: depth + 1) }
        }
        let identity: M4 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let scenes = (root["scenes"] as? [[String: Any]]) ?? []
        if let si = (root["scene"] as? Int) ?? (scenes.isEmpty ? nil : 0), si < scenes.count {
            for ni in (scenes[si]["nodes"] as? [Int]) ?? [] { try visit(ni, identity, depth: 0) }
        } else {
            for mi in meshes.indices { try addMesh(mi, identity) }
        }
        return s
    }

    /// AMF (plain or zipped XML): each object's volumes become regions; the declared unit is applied.
    public static func readAMF(_ url: URL) throws -> TriSurface {
        var data = try Data(contentsOf: url)
        if data.prefix(2) == Data("PK".utf8) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        }
        let parser = AMFParser()
        let x = XMLParser(data: data)
        x.delegate = parser
        guard x.parse() else { throw MeshError.parse("AMF XML: \(x.parserError?.localizedDescription ?? "invalid")") }
        return parser.surface.scaled(by: parser.unitScale)
    }

    /// VTK legacy POLYDATA (ASCII or BINARY, classic POLYGONS or VTK 5 OFFSETS/CONNECTIVITY).
    public static func readVTK(_ data: Data, name: String = "body") throws -> TriSurface {
        let b = [UInt8](data)
        var s = TriSurface(regionNames: [name])
        func emit(_ ids: [Int], strips: Bool) {
            guard ids.count >= 3 else { return }
            if strips {
                for k in 0..<(ids.count - 2) {
                    let t = k % 2 == 0 ? [ids[k], ids[k + 1], ids[k + 2]] : [ids[k + 1], ids[k], ids[k + 2]]
                    s.triangles += t.map(Int32.init); s.triRegion.append(0)
                }
            } else {
                for k in 1..<(ids.count - 1) { s.triangles += [Int32(ids[0]), Int32(ids[k]), Int32(ids[k + 1])]; s.triRegion.append(0) }
            }
        }
        // header: 4 lines
        var lines: [String] = []
        var o = 0
        while lines.count < 4, o < b.count {
            var e = o
            while e < b.count && b[e] != 10 { e += 1 }
            lines.append(String(decoding: b[o..<e], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            o = e + 1
        }
        guard lines.count == 4, lines[0].hasPrefix("# vtk") else { throw MeshError.parse("not a VTK legacy file") }
        let binary = lines[2].uppercased().hasPrefix("BINARY")
        guard lines[3].uppercased().contains("POLYDATA") else { throw MeshError.unsupported("VTK dataset \(lines[3]); only POLYDATA surfaces are read") }
        var p = ByteParser(bytes: Array(b[o...]))
        func bigEndian(_ count: Int, _ size: Int, float: Bool) throws -> [Double] {
            p.skipSpace()
            var out: [Double] = []
            for _ in 0..<count {
                guard p.pos + size <= p.bytes.count - 1 else { throw MeshError.parse("VTK: truncated binary data") }
                var raw: UInt64 = 0
                for k in 0..<size { raw = raw << 8 | UInt64(p.bytes[p.pos + k]) }
                p.skip(bytes: size)
                if float { out.append(size == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw)) }
                else { out.append(Double(size == 4 ? Int64(Int32(bitPattern: UInt32(raw))) : Int64(bitPattern: raw))) }
            }
            return out
        }
        func numbers(_ n: Int, type: String) throws -> [Double] {
            if binary {
                let t = type.lowercased()
                return try bigEndian(n, t.contains("double") || t.contains("64") ? 8 : 4, float: t.contains("float") || t.contains("double"))
            }
            return try (0..<n).map { _ in try p.double() }
        }
        var offsets: [Int] = [], conn: [Int] = []
        while let t = p.token() {
            switch t.uppercased() {
            case "POINTS":
                let n = try p.int(); let type = p.token() ?? "float"
                let v = try numbers(3 * n, type: type)
                for i in 0..<n { s.points.append(Vec3(v[3 * i], v[3 * i + 1], v[3 * i + 2])) }
            case "POLYGONS", "TRIANGLE_STRIPS":
                let strips = t.uppercased() == "TRIANGLE_STRIPS"
                let a = try p.int(), b2 = try p.int()
                p.skipSpace()
                let save = p.pos
                if p.token()?.uppercased() == "OFFSETS" {
                    // VTK 5: OFFSETS <type> (a values) CONNECTIVITY <type> (b2 values)
                    let ot = p.token() ?? "vtktypeint64"
                    offsets = try numbers(a, type: ot).map { Int($0) }
                    _ = p.token(); let ct = p.token() ?? "vtktypeint64"
                    conn = try numbers(b2, type: ct).map { Int($0) }
                    for c in 0..<(a - 1) { let ids = Array(conn[offsets[c]..<offsets[c + 1]]); emit(ids, strips: strips) }
                } else {
                    p.pos = save
                    let v = try numbers(b2, type: "int").map { Int($0) }
                    var k = 0
                    for _ in 0..<a { let nv = v[k]; emit(Array(v[(k + 1)...(k + nv)]), strips: strips); k += nv + 1 }
                }
            case "POINT_DATA", "CELL_DATA", "LINES", "VERTICES":
                if t.uppercased() == "POINT_DATA" || t.uppercased() == "CELL_DATA" { return s }
                let _ = try p.int(); let sz = try p.int(); _ = try numbers(sz, type: "int")
            default: break
            }
        }
        return s
    }
}

private final class AMFParser: NSObject, XMLParserDelegate {
    var surface = TriSurface()
    var unitScale = 1e-3
    var base: Int32 = 0
    var text = ""
    var coord = [0.0, 0.0, 0.0]
    var tri: [Int32] = [0, 0, 0]
    var objectName = "object"
    var inMetadataName = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch name {
        case "amf":
            switch (a["unit"] ?? "millimeter").lowercased() {
            case "inch": unitScale = 0.0254
            case "feet", "foot": unitScale = 0.3048
            case "meter": unitScale = 1
            case "micron": unitScale = 1e-6
            default: unitScale = 1e-3
            }
        case "object": objectName = "object\(a["id"] ?? "\(surface.regionNames.count)")"; base = Int32(surface.points.count)
        case "metadata": inMetadataName = a["type"] == "name"
        case "volume": surface.regionNames.append(objectName)
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "x": coord[0] = Double(v) ?? 0
        case "y": coord[1] = Double(v) ?? 0
        case "z": coord[2] = Double(v) ?? 0
        case "vertex": surface.points.append(Vec3(coord[0], coord[1], coord[2]))
        case "v1": tri[0] = Int32(v) ?? 0
        case "v2": tri[1] = Int32(v) ?? 0
        case "v3": tri[2] = Int32(v) ?? 0
        case "triangle":
            if surface.regionNames.isEmpty { surface.regionNames = [objectName] }
            surface.triangles += tri.map { base + $0 }
            surface.triRegion.append(Int32(surface.regionNames.count - 1))
        case "metadata": if inMetadataName && !v.isEmpty { objectName = v }; inMetadataName = false
        default: break
        }
        text = ""
    }
}

// MARK: - Writer

public enum SurfaceWriter {
    /// ASCII STL with one `solid` per region, the layout snappyHexMesh and Gmsh both read
    /// region names from.
    public static func stl(_ s: TriSurface) -> String {
        var out = ""
        out.reserveCapacity(s.triangleCount * 260)
        let regions = s.regionNames.isEmpty ? ["body"] : s.regionNames
        for (ri, name) in regions.enumerated() {
            out += "solid \(name)\n"
            for t in 0..<s.triangleCount where s.triRegion.isEmpty || Int(s.triRegion[t]) == ri {
                let (a, b, c) = s.corners(t)
                let n = normalized(cross(b - a, c - a))
                out += "  facet normal \(f(n.x)) \(f(n.y)) \(f(n.z))\n    outer loop\n"
                for p in [a, b, c] { out += "      vertex \(f(p.x)) \(f(p.y)) \(f(p.z))\n" }
                out += "    endloop\n  endfacet\n"
            }
            out += "endsolid \(name)\n"
        }
        return out
    }

    static func f(_ v: Double) -> String { String(format: "%.10g", v.isFinite ? v : 0) }
}
