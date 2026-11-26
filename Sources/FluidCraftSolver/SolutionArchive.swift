import Foundation
import FluidCraftMesh

/// Binary solution data (".dat" equivalent) for a pressure-based run.
public enum SolutionArchive {
    static let magic: UInt32 = 0x54414443 // "CDAT"

    struct Header: Codable {
        var nCells: Int, nBoundary: Int, nFaces: Int
        var iteration: Int, time: Double, timeStep: Int
        var arrays: [String]
        var scalarCount: Int
    }

    public static func write(_ s: Solution) throws -> Data {
        let st = s.state
        var arrays: [(String, [Double])] = [
            ("u", st.u.flatMap { [$0.x, $0.y, $0.z] }), ("p", st.p), ("T", st.T), ("k", st.k), ("omega", st.omega),
            ("epsilon", st.epsilon), ("nuTilda", st.nuTilda), ("muT", st.muT),
            ("bU", st.bU.flatMap { [$0.x, $0.y, $0.z] }), ("bP", st.bP), ("bT", st.bT), ("bK", st.bK),
            ("bOmega", st.bOmega), ("bEpsilon", st.bEpsilon), ("bNuTilda", st.bNuTilda),
            ("bWallShear", st.bWallShear.flatMap { [$0.x, $0.y, $0.z] }), ("bHeatFlux", st.bHeatFlux), ("bYPlus", st.bYPlus),
            ("massFlux", st.massFlux),
        ]
        for (i, a) in st.scalars.enumerated() { arrays.append(("scalar\(i)", a)); arrays.append(("bScalar\(i)", st.bScalars[i])) }
        if !st.uOld.isEmpty {
            arrays.append(("uOld", st.uOld.flatMap { [$0.x, $0.y, $0.z] }))
            arrays.append(("massFluxOld", st.massFluxOld))
        }
        if !st.meanU.isEmpty {
            arrays.append(("meanU", st.meanU.flatMap { [$0.x, $0.y, $0.z] }))
            arrays.append(("meanP", st.meanP))
        }
        let header = Header(nCells: st.nCells, nBoundary: st.nBoundary, nFaces: st.nFaces, iteration: st.iteration,
                            time: st.time, timeStep: st.timeStep, arrays: arrays.map(\.0), scalarCount: st.scalars.count)
        var d = Data()
        var m = magic.littleEndian
        withUnsafeBytes(of: &m) { d.append(contentsOf: $0) }
        let h = try JSONEncoder().encode(header)
        var hl = UInt64(h.count).littleEndian
        withUnsafeBytes(of: &hl) { d.append(contentsOf: $0) }
        d.append(h)
        for (_, a) in arrays {
            var n = UInt64(a.count).littleEndian
            withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
            a.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        return d
    }

    public static func read(_ data: Data, into s: Solution) throws {
        let b = [UInt8](data)
        var o = 0
        func u64() throws -> Int {
            guard o + 8 <= b.count else { throw SolverError("truncated solution data") }
            let v = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
            o += 8; return Int(UInt64(littleEndian: v))
        }
        guard b.count > 12, b.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == magic else { throw SolverError("not a FluidCraft data file") }
        o = 4
        let hl = try u64()
        let header = try JSONDecoder().decode(Header.self, from: Data(b[o..<(o + hl)]))
        o += hl
        let st = s.state
        guard header.nCells == st.nCells, header.nFaces == st.nFaces else { throw SolverError("solution data does not match the mesh") }
        var arrays: [String: [Double]] = [:]
        for name in header.arrays {
            let n = try u64()
            guard o + n * 8 <= b.count else { throw SolverError("truncated array \(name)") }
            let a = [Double](unsafeUninitializedCapacity: n) { buf, c in
                b.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress! + o, n * 8) }
                c = n
            }
            o += n * 8
            arrays[name] = a
        }
        func vec(_ a: [Double]?) -> [Vec3]? {
            guard let a else { return nil }
            return (0..<(a.count / 3)).map { Vec3(a[3 * $0], a[3 * $0 + 1], a[3 * $0 + 2]) }
        }
        if let v = vec(arrays["u"]) { st.u = v }
        if let v = arrays["p"] { st.p = v }
        if let v = arrays["T"] { st.T = v }
        if let v = arrays["k"] { st.k = v }
        if let v = arrays["omega"] { st.omega = v }
        if let v = arrays["epsilon"] { st.epsilon = v }
        if let v = arrays["nuTilda"] { st.nuTilda = v }
        if let v = arrays["muT"] { st.muT = v }
        if let v = vec(arrays["bU"]) { st.bU = v }
        if let v = arrays["bP"] { st.bP = v }
        if let v = arrays["bT"] { st.bT = v }
        if let v = arrays["bK"] { st.bK = v }
        if let v = arrays["bOmega"] { st.bOmega = v }
        if let v = arrays["bEpsilon"] { st.bEpsilon = v }
        if let v = arrays["bNuTilda"] { st.bNuTilda = v }
        if let v = vec(arrays["bWallShear"]) { st.bWallShear = v }
        if let v = arrays["bHeatFlux"] { st.bHeatFlux = v }
        if let v = arrays["bYPlus"] { st.bYPlus = v }
        if let v = arrays["massFlux"] { st.massFlux = v }
        for i in 0..<min(header.scalarCount, st.scalars.count) {
            if let v = arrays["scalar\(i)"] { st.scalars[i] = v }
            if let v = arrays["bScalar\(i)"] { st.bScalars[i] = v }
        }
        if let v = vec(arrays["uOld"]) { st.uOld = v; st.uOldOld = v }
        if let v = arrays["massFluxOld"] { st.massFluxOld = v; st.massFluxOldOld = v }
        if let v = vec(arrays["meanU"]) { st.meanU = v }
        if let v = arrays["meanP"] { st.meanP = v }
        st.iteration = header.iteration
        st.time = header.time
        st.timeStep = header.timeStep
        s.afterRestore()
    }
}
