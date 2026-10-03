import Foundation
import Metal

/// Metal backend for symmetric (pressure-type) systems: AMG-preconditioned CG in
/// single precision on the GPU, inside a double-precision iterative-refinement loop.
///
/// Apple GPUs have no FP64, so each refinement step solves A d = r in fp32 to a modest
/// tolerance and the correction is accumulated in double on the CPU (unified memory,
/// no copies). The AMG hierarchy (aggregates, Galerkin operators) comes from the CPU
/// setup; the V-cycle uses damped Jacobi smoothing, which is symmetric and parallel.
public final class GPUAccelerator: @unchecked Sendable {
    public static let shared: GPUAccelerator? = GPUAccelerator()

    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipelines: [String: MTLComputePipelineState] = [:]
    /// Systems smaller than this stay on the CPU (dispatch overhead dominates).
    public var minimumRows = 30_000
    public var jacobiOmega: Float = 0.7
    public var smoothingSweeps = 2
    public var coarseSweeps = 40
    public private(set) var lastSolveSeconds = 0.0
    public var name: String { device.name }

    final class GPULevel {
        let n: Int
        let nnz: Int
        let rowPtr: MTLBuffer, colIdx: MTLBuffer, values: MTLBuffer, diagInv: MTLBuffer
        let x: MTLBuffer, b: MTLBuffer, r: MTLBuffer, tmp: MTLBuffer
        var agg: MTLBuffer? = nil          // fine row -> coarse row
        var memberPtr: MTLBuffer? = nil    // coarse row -> fine members (CSR)
        var members: MTLBuffer? = nil
        init?(device d: MTLDevice, A: SparseMatrix) {
            n = A.n; nnz = A.pattern.nnz
            let rp = A.pattern.rowPtr, ci = A.pattern.colIdx
            guard let a = d.makeBuffer(bytes: rp, length: rp.count * 4, options: .storageModeShared),
                  let c = d.makeBuffer(bytes: ci, length: max(ci.count, 1) * 4, options: .storageModeShared),
                  let v = d.makeBuffer(length: max(nnz, 1) * 4, options: .storageModeShared),
                  let di = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let x = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let b = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let r = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let t = d.makeBuffer(length: n * 4, options: .storageModeShared) else { return nil }
            rowPtr = a; colIdx = c; values = v; diagInv = di; self.x = x; self.b = b; self.r = r; tmp = t
        }
        func upload(_ A: SparseMatrix) {
            let v = values.contents().bindMemory(to: Float.self, capacity: nnz)
            let di = diagInv.contents().bindMemory(to: Float.self, capacity: n)
            A.values.withUnsafeBufferPointer { src in
                for k in 0..<nnz { v[k] = Float(src[k]) }
            }
            for i in 0..<n {
                let d = A.values[Int(A.pattern.diag[i])]
                di[i] = d != 0 ? Float(1 / d) : 0
            }
        }
    }

    // Krylov work buffers (fine level)
    final class Work {
        let n: Int
        let p: MTLBuffer, q: MTLBuffer, z: MTLBuffer, r: MTLBuffer, x: MTLBuffer
        let partials: MTLBuffer, scalars: MTLBuffer
        let groups: Int
        init?(device d: MTLDevice, n: Int) {
            self.n = n
            groups = max(1, min(1024, (n + 255) / 256))
            guard let p = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let q = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let z = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let r = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let x = d.makeBuffer(length: n * 4, options: .storageModeShared),
                  let part = d.makeBuffer(length: 1024 * 4, options: .storageModeShared),
                  let sc = d.makeBuffer(length: 16 * 4, options: .storageModeShared) else { return nil }
            self.p = p; self.q = q; self.z = z; self.r = r; self.x = x; partials = part; scalars = sc
        }
    }

    var levels: [GPULevel] = []
    var hierarchyKey: [Int] = []
    var hierarchyID: ObjectIdentifier? = nil
    var work: Work?

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void residual(device const int* rp [[buffer(0)]], device const int* ci [[buffer(1)]], device const float* v [[buffer(2)]],
                         device const float* x [[buffer(3)]], device const float* b [[buffer(4)]], device float* r [[buffer(5)]],
                         constant uint& n [[buffer(6)]], uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        float s = b[i];
        for (int k = rp[i]; k < rp[i + 1]; ++k) s -= v[k] * x[ci[k]];
        r[i] = s;
    }
    kernel void spmv(device const int* rp [[buffer(0)]], device const int* ci [[buffer(1)]], device const float* v [[buffer(2)]],
                     device const float* x [[buffer(3)]], device float* y [[buffer(4)]], constant uint& n [[buffer(5)]],
                     uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        float s = 0.0f;
        for (int k = rp[i]; k < rp[i + 1]; ++k) s += v[k] * x[ci[k]];
        y[i] = s;
    }
    // xout = xin + w * Dinv * (b - A xin)
    kernel void jacobi(device const int* rp [[buffer(0)]], device const int* ci [[buffer(1)]], device const float* v [[buffer(2)]],
                       device const float* dinv [[buffer(3)]], device const float* b [[buffer(4)]], device const float* xin [[buffer(5)]],
                       device float* xout [[buffer(6)]], constant uint& n [[buffer(7)]], constant float& w [[buffer(8)]],
                       uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        float s = b[i];
        for (int k = rp[i]; k < rp[i + 1]; ++k) s -= v[k] * xin[ci[k]];
        xout[i] = xin[i] + w * dinv[i] * s;
    }
    // first sweep from a zero guess: x = w Dinv b
    kernel void jacobiZero(device const float* dinv [[buffer(0)]], device const float* b [[buffer(1)]], device float* x [[buffer(2)]],
                           constant uint& n [[buffer(3)]], constant float& w [[buffer(4)]], uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        x[i] = w * dinv[i] * b[i];
    }
    kernel void restrictSum(device const int* mp [[buffer(0)]], device const int* mem [[buffer(1)]], device const float* r [[buffer(2)]],
                            device float* bc [[buffer(3)]], constant uint& nc [[buffer(4)]], uint I [[thread_position_in_grid]]) {
        if (I >= nc) return;
        float s = 0.0f;
        for (int k = mp[I]; k < mp[I + 1]; ++k) s += r[mem[k]];
        bc[I] = s;
    }
    kernel void prolongAdd(device const int* agg [[buffer(0)]], device const float* ec [[buffer(1)]], device float* x [[buffer(2)]],
                           constant uint& n [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        x[i] += ec[agg[i]];
    }
    kernel void copyv(device const float* a [[buffer(0)]], device float* b [[buffer(1)]], constant uint& n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        b[i] = a[i];
    }
    kernel void dotPartial(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]], device float* part [[buffer(2)]],
                           constant uint& n [[buffer(3)]], constant uint& groups [[buffer(4)]],
                           uint gid [[threadgroup_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                           uint tpg [[threads_per_threadgroup]]) {
        threadgroup float sh[256];
        float s = 0.0f;
        for (uint i = gid * tpg + lid; i < n; i += groups * tpg) s += a[i] * b[i];
        sh[lid] = s;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint st = tpg / 2; st > 0; st >>= 1) {
            if (lid < st) sh[lid] += sh[lid + st];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lid == 0) part[gid] = sh[0];
    }
    // scalars: [0] rz, [1] rzOld, [2] alpha, [3] beta, [4] pq, [5] rr
    kernel void finalize(device const float* part [[buffer(0)]], device float* sc [[buffer(1)]], constant uint& groups [[buffer(2)]],
                         constant uint& mode [[buffer(3)]], uint lid [[thread_position_in_threadgroup]]) {
        threadgroup float sh[256];
        float s = 0.0f;
        for (uint i = lid; i < groups; i += 256) s += part[i];
        sh[lid] = s;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint st = 128; st > 0; st >>= 1) {
            if (lid < st) sh[lid] += sh[lid + st];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lid == 0) {
            float t = sh[0];
            if (mode == 0) {            // rz -> beta
                sc[3] = sc[1] > 0.0f ? t / sc[1] : 0.0f;
                sc[0] = t; sc[1] = t;
            } else if (mode == 1) {     // pq -> alpha
                sc[4] = t;
                sc[2] = t > 0.0f ? sc[0] / t : 0.0f;
            } else {                    // rr
                sc[5] = t;
            }
        }
    }
    kernel void updateP(device const float* z [[buffer(0)]], device float* p [[buffer(1)]], device const float* sc [[buffer(2)]],
                        constant uint& n [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        p[i] = z[i] + sc[3] * p[i];
    }
    kernel void updateXR(device const float* p [[buffer(0)]], device const float* q [[buffer(1)]], device float* x [[buffer(2)]],
                         device float* r [[buffer(3)]], device const float* sc [[buffer(4)]], constant uint& n [[buffer(5)]],
                         uint i [[thread_position_in_grid]]) {
        if (i >= n) return;
        float a = sc[2];
        x[i] += a * p[i];
        r[i] -= a * q[i];
    }
    """

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        do {
            let lib = try d.makeLibrary(source: GPUAccelerator.source, options: nil)
            for name in ["residual", "spmv", "jacobi", "jacobiZero", "restrictSum", "prolongAdd", "copyv", "dotPartial", "finalize", "updateP", "updateXR"] {
                guard let f = lib.makeFunction(name: name) else { return nil }
                pipelines[name] = try d.makeComputePipelineState(function: f)
            }
        } catch {
            return nil
        }
    }

    // MARK: Hierarchy mirroring

    func prepare(_ amg: AMGHierarchy) -> Bool {
        let key = amg.levelSizes
        let id = ObjectIdentifier(amg)
        if key != hierarchyKey || id != hierarchyID || levels.count != amg.levels.count {
            levels = []
            for L in amg.levels {
                guard let g = GPULevel(device: device, A: L.A) else { return false }
                levels.append(g)
            }
            for l in 0..<(amg.levels.count - 1) {
                let L = amg.levels[l]
                let nc = L.nCoarse
                var mp = [Int32](repeating: 0, count: nc + 1)
                for a in L.agg { mp[Int(a) + 1] += 1 }
                for I in 0..<nc { mp[I + 1] += mp[I] }
                var fill = Array(mp[0..<nc])
                var mem = [Int32](repeating: 0, count: L.agg.count)
                for (i, a) in L.agg.enumerated() { mem[Int(fill[Int(a)])] = Int32(i); fill[Int(a)] += 1 }
                levels[l].agg = device.makeBuffer(bytes: L.agg, length: max(L.agg.count, 1) * 4, options: .storageModeShared)
                levels[l].memberPtr = device.makeBuffer(bytes: mp, length: mp.count * 4, options: .storageModeShared)
                levels[l].members = device.makeBuffer(bytes: mem, length: max(mem.count, 1) * 4, options: .storageModeShared)
            }
            hierarchyKey = key
            hierarchyID = id
            work = Work(device: device, n: amg.levels[0].A.n)
        }
        for (l, L) in amg.levels.enumerated() { levels[l].upload(L.A) }
        return work != nil
    }

    // MARK: Encoding helpers

    func dispatch(_ enc: MTLComputeCommandEncoder, _ name: String, _ n: Int, _ setup: (MTLComputeCommandEncoder) -> Void) {
        let p = pipelines[name]!
        enc.setComputePipelineState(p)
        setup(enc)
        let w = min(p.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: max(n, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    func setU32(_ enc: MTLComputeCommandEncoder, _ v: Int, _ index: Int) {
        var u = UInt32(v); enc.setBytes(&u, length: 4, index: index)
    }

    /// z = M^-1 r via one V-cycle (levels[0].b holds the right-hand side; result in levels[0].x).
    func encodeVCycle(_ enc: MTLComputeCommandEncoder, level l: Int) {
        let L = levels[l]
        var w = jacobiOmega
        let sweeps = l == levels.count - 1 ? coarseSweeps : smoothingSweeps
        // x = w Dinv b, then (sweeps-1) Jacobi sweeps ping-ponging x <-> tmp
        dispatch(enc, "jacobiZero", L.n) { e in
            e.setBuffer(L.diagInv, offset: 0, index: 0); e.setBuffer(L.b, offset: 0, index: 1); e.setBuffer(L.x, offset: 0, index: 2)
            setU32(e, L.n, 3); e.setBytes(&w, length: 4, index: 4)
        }
        func sweep() {
            dispatch(enc, "jacobi", L.n) { e in
                e.setBuffer(L.rowPtr, offset: 0, index: 0); e.setBuffer(L.colIdx, offset: 0, index: 1); e.setBuffer(L.values, offset: 0, index: 2)
                e.setBuffer(L.diagInv, offset: 0, index: 3); e.setBuffer(L.b, offset: 0, index: 4); e.setBuffer(L.x, offset: 0, index: 5)
                e.setBuffer(L.tmp, offset: 0, index: 6); setU32(e, L.n, 7); e.setBytes(&w, length: 4, index: 8)
            }
            dispatch(enc, "copyv", L.n) { e in e.setBuffer(L.tmp, offset: 0, index: 0); e.setBuffer(L.x, offset: 0, index: 1); setU32(e, L.n, 2) }
        }
        for _ in 1..<max(sweeps, 1) { sweep() }
        if l == levels.count - 1 { return }
        let C = levels[l + 1]
        dispatch(enc, "residual", L.n) { e in
            e.setBuffer(L.rowPtr, offset: 0, index: 0); e.setBuffer(L.colIdx, offset: 0, index: 1); e.setBuffer(L.values, offset: 0, index: 2)
            e.setBuffer(L.x, offset: 0, index: 3); e.setBuffer(L.b, offset: 0, index: 4); e.setBuffer(L.r, offset: 0, index: 5); setU32(e, L.n, 6)
        }
        dispatch(enc, "restrictSum", C.n) { e in
            e.setBuffer(L.memberPtr!, offset: 0, index: 0); e.setBuffer(L.members!, offset: 0, index: 1); e.setBuffer(L.r, offset: 0, index: 2)
            e.setBuffer(C.b, offset: 0, index: 3); setU32(e, C.n, 4)
        }
        encodeVCycle(enc, level: l + 1)
        dispatch(enc, "prolongAdd", L.n) { e in
            e.setBuffer(L.agg!, offset: 0, index: 0); e.setBuffer(C.x, offset: 0, index: 1); e.setBuffer(L.x, offset: 0, index: 2); setU32(e, L.n, 3)
        }
        for _ in 0..<smoothingSweeps { sweep() }
    }

    func encodeDot(_ enc: MTLComputeCommandEncoder, _ a: MTLBuffer, _ b: MTLBuffer, mode: Int) {
        guard let w = work else { return }
        let p = pipelines["dotPartial"]!
        enc.setComputePipelineState(p)
        enc.setBuffer(a, offset: 0, index: 0); enc.setBuffer(b, offset: 0, index: 1); enc.setBuffer(w.partials, offset: 0, index: 2)
        setU32(enc, w.n, 3); setU32(enc, w.groups, 4)
        enc.dispatchThreadgroups(MTLSize(width: w.groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        let f = pipelines["finalize"]!
        enc.setComputePipelineState(f)
        enc.setBuffer(w.partials, offset: 0, index: 0); enc.setBuffer(w.scalars, offset: 0, index: 1)
        setU32(enc, w.groups, 2); setU32(enc, mode, 3)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// fp32 PCG on the GPU for A d = r (r in work.r on entry, d returned in work.x). Returns iterations.
    func pcg(tolerance: Float, maxIterations: Int, initialNorm2: Float) -> Int {
        guard let w = work else { return 0 }
        let L0 = levels[0]
        let sc = w.scalars.contents().bindMemory(to: Float.self, capacity: 16)
        for i in 0..<16 { sc[i] = 0 }
        memset(w.x.contents(), 0, w.n * 4)
        memset(w.p.contents(), 0, w.n * 4)
        let target = tolerance * tolerance * initialNorm2
        var it = 0
        let check = 4
        while it < maxIterations {
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { break }
            for _ in 0..<check {
                // z = M r
                dispatch(enc, "copyv", w.n) { e in e.setBuffer(w.r, offset: 0, index: 0); e.setBuffer(L0.b, offset: 0, index: 1); setU32(e, w.n, 2) }
                encodeVCycle(enc, level: 0)
                dispatch(enc, "copyv", w.n) { e in e.setBuffer(L0.x, offset: 0, index: 0); e.setBuffer(w.z, offset: 0, index: 1); setU32(e, w.n, 2) }
                encodeDot(enc, w.r, w.z, mode: 0)               // rz, beta
                dispatch(enc, "updateP", w.n) { e in e.setBuffer(w.z, offset: 0, index: 0); e.setBuffer(w.p, offset: 0, index: 1); e.setBuffer(w.scalars, offset: 0, index: 2); setU32(e, w.n, 3) }
                dispatch(enc, "spmv", w.n) { e in
                    e.setBuffer(L0.rowPtr, offset: 0, index: 0); e.setBuffer(L0.colIdx, offset: 0, index: 1); e.setBuffer(L0.values, offset: 0, index: 2)
                    e.setBuffer(w.p, offset: 0, index: 3); e.setBuffer(w.q, offset: 0, index: 4); setU32(e, w.n, 5)
                }
                encodeDot(enc, w.p, w.q, mode: 1)               // pq, alpha
                dispatch(enc, "updateXR", w.n) { e in
                    e.setBuffer(w.p, offset: 0, index: 0); e.setBuffer(w.q, offset: 0, index: 1); e.setBuffer(w.x, offset: 0, index: 2)
                    e.setBuffer(w.r, offset: 0, index: 3); e.setBuffer(w.scalars, offset: 0, index: 4); setU32(e, w.n, 5)
                }
            }
            encodeDot(enc, w.r, w.r, mode: 2)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            it += check
            let rr = sc[5]
            if !rr.isFinite || rr <= target { break }
        }
        return it
    }
}

extension GPUAccelerator: LinearAccelerator {
    public func shouldHandle(n: Int, method: LinearMethod) -> Bool { n >= minimumRows && method == .amgCG }

    public func solve(_ A: SparseMatrix, x: inout [Double], b: [Double], settings: LinearSolverSettings, amg: AMGHierarchy) -> LinearSolveStats {
        let t0 = Date()
        let n = A.n
        var r = [Double](repeating: 0, count: n)
        A.residual(x: x, b: b, into: &r)
        let r0 = sqrt(dotp(r, r))
        guard r0 > settings.absTol, prepare(amg), let w = work else {
            return LinearSolveStats(iterations: 0, initialResidual: r0, finalResidual: r0, converged: true)
        }
        var rn = r0
        var total = 0
        let target = max(settings.relTol * r0, settings.absTol)
        for _ in 0..<8 {
            if rn <= target { break }
            // normalised fp32 residual on the GPU
            let scale = rn
            let rf = w.r.contents().bindMemory(to: Float.self, capacity: n)
            var norm2: Float = 0
            for i in 0..<n { let v = Float(r[i] / scale); rf[i] = v; norm2 += v * v }
            let inner = Float(max(settings.relTol, 1e-3)) * 0.5
            total += pcg(tolerance: max(inner, 1e-4), maxIterations: settings.maxIterations, initialNorm2: norm2)
            let d = w.x.contents().bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { x[i] += scale * Double(d[i]) }
            A.residual(x: x, b: b, into: &r)
            rn = sqrt(dotp(r, r))
            if !rn.isFinite { break }
        }
        lastSolveSeconds = Date().timeIntervalSince(t0)
        return LinearSolveStats(iterations: total, initialResidual: r0, finalResidual: rn, converged: rn <= target)
    }
}
