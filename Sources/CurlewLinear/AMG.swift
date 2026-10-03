import Foundation

public enum AMGCycle: String, Codable, CaseIterable, Sendable {
    case v = "V", w = "W", f = "F"
    /// Krylov-accelerated cycle (Notay). Nonlinear: use with flexible CG only.
    case k = "K"
}

/// Aggregation-based algebraic multigrid with additive-correction
/// (piecewise-constant) transfer operators and Galerkin coarse matrices.
public final class AMGHierarchy: @unchecked Sendable {
    final class Level {
        var A: SparseMatrix
        /// Map from rows of this level to rows of the next coarser level.
        var agg: [Int32] = []
        /// Coarse nnz index for every nnz of this level's matrix.
        var nnzMap: [Int32] = []
        var nCoarse = 0
        var x: [Double], b: [Double], r: [Double], snapshot: [Double]
        // K-cycle work vectors (on the coarse level they feed)
        var c: [Double] = [], v: [Double] = [], d: [Double] = [], w: [Double] = [], r2: [Double] = []
        init(_ A: SparseMatrix) {
            self.A = A
            x = [Double](repeating: 0, count: A.n)
            b = x; r = x; snapshot = x
        }
    }

    public var preSweeps = 1
    public var postSweeps = 2
    public var coarsestSize = 120
    public var maxLevels = 25
    /// Strength-of-connection threshold for aggregation.
    public var strength = 0.25
    /// Target number of fine rows per aggregate (2 = one pairwise pass).
    public var targetRatio = 4.0

    var levels: [Level] = []
    var dense: DenseLU? = nil
    public var levelCount: Int { levels.count }
    public var levelSizes: [Int] { levels.map { $0.A.n } }

    public init() {}

    /// Build aggregates and coarse operators for `A`.
    public func setup(_ A: SparseMatrix) {
        levels = [Level(A)]
        while levels.count < maxLevels {
            let L = levels[levels.count - 1]
            if L.A.n <= coarsestSize { break }
            var (agg, nc) = AMGHierarchy.pairwise(L.A, beta: strength)
            // Additional pairwise passes on the intermediate coarse matrix.
            var ratio = Double(L.A.n) / Double(max(nc, 1))
            var passes = 1
            while ratio < targetRatio * 0.9 && passes < 3 && nc > coarsestSize {
                let tmp = AMGHierarchy.galerkin(L.A, agg: agg, nc: nc)
                let (agg2, nc2) = AMGHierarchy.pairwise(tmp.matrix, beta: strength)
                if Double(nc) / Double(max(nc2, 1)) < 1.15 { break }
                for i in 0..<agg.count { agg[i] = agg2[Int(agg[i])] }
                nc = nc2
                ratio = Double(L.A.n) / Double(max(nc, 1))
                passes += 1
            }
            if Double(L.A.n) / Double(max(nc, 1)) < 1.2 { break } // stagnated
            let g = AMGHierarchy.galerkin(L.A, agg: agg, nc: nc)
            L.agg = agg; L.nnzMap = g.nnzMap; L.nCoarse = nc
            let next = Level(g.matrix)
            levels.append(next)
            next.c = [Double](repeating: 0, count: nc); next.v = next.c; next.d = next.c; next.w = next.c; next.r2 = next.c
        }
        factorCoarsest()
    }

    /// Refresh coarse matrix values after the fine values changed (same pattern).
    public func updateValues(_ A: SparseMatrix) {
        guard !levels.isEmpty else { setup(A); return }
        levels[0].A = A
        for l in 0..<(levels.count - 1) {
            let fine = levels[l].A, coarse = levels[l + 1].A
            coarse.zero()
            fine.values.withUnsafeBufferPointer { fv in
                levels[l].nnzMap.withUnsafeBufferPointer { map in
                    coarse.values.withUnsafeMutableBufferPointer { cv in
                        for k in 0..<fv.count { cv[Int(map[k])] += fv[k] }
                    }
                }
            }
        }
        factorCoarsest()
    }

    func factorCoarsest() {
        let last = levels[levels.count - 1].A
        dense = last.n <= max(coarsestSize * 4, 600) ? DenseLU(last) : nil
    }

    // MARK: Cycles

    /// Apply one cycle as preconditioner: x = M^-1 b (x is overwritten, zero initial guess).
    public func apply(_ b: [Double], into x: inout [Double], cycle: AMGCycle) {
        let L0 = levels[0]
        L0.b = b
        fill(&L0.x, 0)
        run(0, cycle)
        x = L0.x
    }

    func run(_ l: Int, _ cycle: AMGCycle) {
        let L = levels[l]
        if l == levels.count - 1 {
            if let dense { dense.solve(L.b, into: &L.x) }
            else { for _ in 0..<20 { Smoother.gaussSeidel(L.A, x: &L.x, b: L.b, snapshot: &L.snapshot, forward: true)
                                     Smoother.gaussSeidel(L.A, x: &L.x, b: L.b, snapshot: &L.snapshot, forward: false) } }
            return
        }
        for _ in 0..<preSweeps { Smoother.gaussSeidel(L.A, x: &L.x, b: L.b, snapshot: &L.snapshot, forward: true) }
        L.A.residual(x: L.x, b: L.b, into: &L.r)
        let C = levels[l + 1]
        restrict(L, into: &C.b)
        fill(&C.x, 0)
        switch cycle {
        case .v: run(l + 1, .v)
        case .w:
            run(l + 1, .w)
            if l + 1 < levels.count - 1 { coarseRepeat(l + 1, .w) }
        case .f:
            run(l + 1, .f)
            if l + 1 < levels.count - 1 { coarseRepeat(l + 1, .v) }
        case .k:
            if l + 1 == levels.count - 1 { run(l + 1, .k) } else { kcycle(l + 1) }
        }
        prolongAdd(L, from: C.x)
        for _ in 0..<postSweeps { Smoother.gaussSeidel(L.A, x: &L.x, b: L.b, snapshot: &L.snapshot, forward: false) }
    }

    /// Second visit of a coarse level for W/F cycles: correct the existing coarse x.
    func coarseRepeat(_ l: Int, _ cycle: AMGCycle) {
        let C = levels[l]
        // Solve A e = b - A x with one more cycle, then add.
        let saveB = C.b, saveX = C.x
        C.A.residual(x: saveX, b: saveB, into: &C.r)
        C.b = C.r
        fill(&C.x, 0)
        run(l, cycle)
        for i in 0..<C.x.count { C.x[i] += saveX[i] }
        C.b = saveB
    }

    /// Notay's K-cycle: two flexible-CG iterations on level `l` preconditioned by the cycle below.
    func kcycle(_ l: Int) {
        let C = levels[l]
        let rc = C.b
        // c = B(rc)
        run(l, .k)
        C.c = C.x
        C.A.multiply(C.c, into: &C.v)
        let rho1 = dotp(C.c, C.v), alpha1 = dotp(C.c, rc)
        guard rho1 > 0 else { return }
        let s1 = alpha1 / rho1
        for i in 0..<rc.count { C.r2[i] = rc[i] - s1 * C.v[i] }
        let n0 = dotp(rc, rc), n2 = dotp(C.r2, C.r2)
        if n2 <= 0.0625 * n0 {
            for i in 0..<rc.count { C.x[i] = s1 * C.c[i] }
            C.b = rc
            return
        }
        C.b = C.r2
        fill(&C.x, 0)
        run(l, .k)
        C.d = C.x
        C.A.multiply(C.d, into: &C.w)
        let gamma = dotp(C.d, C.v), beta = dotp(C.d, C.w), alpha2 = dotp(C.d, C.r2)
        let rho2 = beta - gamma * gamma / rho1
        C.b = rc
        if rho2 <= 1e-300 {
            for i in 0..<rc.count { C.x[i] = s1 * C.c[i] }
            return
        }
        let a = s1 - gamma * alpha2 / (rho1 * rho2), bcoef = alpha2 / rho2
        for i in 0..<rc.count { C.x[i] = a * C.c[i] + bcoef * C.d[i] }
    }

    func restrict(_ L: Level, into bc: inout [Double]) {
        fill(&bc, 0)
        L.agg.withUnsafeBufferPointer { agg in
            L.r.withUnsafeBufferPointer { r in
                bc.withUnsafeMutableBufferPointer { b in
                    for i in 0..<r.count { b[Int(agg[i])] += r[i] }
                }
            }
        }
    }

    func prolongAdd(_ L: Level, from xc: [Double]) {
        let n = L.A.n
        L.agg.withUnsafeBufferPointer { agg in
            xc.withUnsafeBufferPointer { c in
                L.x.withUnsafeMutableBufferPointer { x in
                    let X = SharedPtr(x.baseAddress!), A = agg.baseAddress!, Cp = c.baseAddress!
                    Parallel.forEach(n) { range in for i in range { X[i] += Cp[Int(A[i])] } }
                }
            }
        }
    }

    // MARK: Setup kernels

    /// One pass of pairwise matching along strongest negative couplings.
    static func pairwise(_ A: SparseMatrix, beta: Double) -> ([Int32], Int) {
        let n = A.n
        var agg = [Int32](repeating: -1, count: n)
        var nc: Int32 = 0
        let R = A.pattern.rowPtr, C = A.pattern.colIdx, V = A.values
        R.withUnsafeBufferPointer { R in C.withUnsafeBufferPointer { C in V.withUnsafeBufferPointer { V in
            agg.withUnsafeMutableBufferPointer { G in
                for i in 0..<n where G[i] < 0 {
                    var maxNeg = 0.0
                    for k in Int(R[i])..<Int(R[i + 1]) where Int(C[k]) != i { maxNeg = max(maxNeg, -V[k]) }
                    var best = -1, bestVal = 0.0
                    if maxNeg > 0 {
                        let thr = beta * maxNeg
                        for k in Int(R[i])..<Int(R[i + 1]) {
                            let j = Int(C[k])
                            if j == i || G[j] >= 0 { continue }
                            let s = -V[k]
                            if s >= thr && s > bestVal { bestVal = s; best = j }
                        }
                    }
                    G[i] = nc
                    if best >= 0 { G[best] = nc }
                    nc += 1
                }
            }
        }}}
        return (agg, Int(nc))
    }

    static func galerkin(_ A: SparseMatrix, agg: [Int32], nc: Int) -> (matrix: SparseMatrix, nnzMap: [Int32]) {
        let n = A.n
        let R = A.pattern.rowPtr, C = A.pattern.colIdx
        // members of each aggregate
        var mPtr = [Int32](repeating: 0, count: nc + 1)
        for i in 0..<n { mPtr[Int(agg[i]) + 1] += 1 }
        for I in 0..<nc { mPtr[I + 1] += mPtr[I] }
        var fill = Array(mPtr[0..<nc])
        var members = [Int32](repeating: 0, count: n)
        for i in 0..<n { let I = Int(agg[i]); members[Int(fill[I])] = Int32(i); fill[I] += 1 }

        var marker = [Int32](repeating: -1, count: nc)
        var rowPtr = [Int32](repeating: 0, count: nc + 1)
        var cols: [Int32] = []
        cols.reserveCapacity(A.pattern.nnz / 2)
        for I in 0..<nc {
            let start = cols.count
            for m in Int(mPtr[I])..<Int(mPtr[I + 1]) {
                let i = Int(members[m])
                for k in Int(R[i])..<Int(R[i + 1]) {
                    let J = agg[Int(C[k])]
                    if marker[Int(J)] != Int32(I) { marker[Int(J)] = Int32(I); cols.append(J) }
                }
            }
            cols[start..<cols.count].sort()
            rowPtr[I + 1] = Int32(cols.count)
        }
        let pat = SparsePattern(n: nc, rowPtr: rowPtr, colIdx: cols)
        // nnz map: position of (agg[i], agg[j]) for every fine entry. Use a per-row
        // scatter table to avoid binary searches.
        var map = [Int32](repeating: 0, count: A.pattern.nnz)
        var pos = [Int32](repeating: -1, count: nc)
        for I in 0..<nc {
            for k in Int(rowPtr[I])..<Int(rowPtr[I + 1]) { pos[Int(cols[k])] = Int32(k) }
            for m in Int(mPtr[I])..<Int(mPtr[I + 1]) {
                let i = Int(members[m])
                for k in Int(R[i])..<Int(R[i + 1]) { map[k] = pos[Int(agg[Int(C[k])])] }
            }
        }
        let M = SparseMatrix(pattern: pat)
        for k in 0..<A.pattern.nnz { M.values[Int(map[k])] += A.values[k] }
        return (M, map)
    }
}

@inline(__always) func fill(_ a: inout [Double], _ v: Double) {
    a.withUnsafeMutableBufferPointer { p in p.baseAddress!.update(repeating: v, count: p.count) }
}

@inline(__always) func dotp(_ a: [Double], _ b: [Double]) -> Double {
    a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
        let A = ap.baseAddress!, B = bp.baseAddress!
        return Parallel.sum(ap.count) { r in var s = 0.0; for i in r { s += A[i] * B[i] }; return s }
    }}
}

/// Dense LU with partial pivoting for the coarsest level.
final class DenseLU {
    let n: Int
    var a: [Double]
    var piv: [Int]
    init(_ A: SparseMatrix) {
        n = A.n
        a = [Double](repeating: 0, count: n * n)
        piv = Array(0..<n)
        for i in 0..<n {
            for k in Int(A.pattern.rowPtr[i])..<Int(A.pattern.rowPtr[i + 1]) {
                a[i * n + Int(A.pattern.colIdx[k])] += A.values[k]
            }
        }
        var scale = 0.0
        for i in 0..<n { scale = max(scale, abs(a[i * n + i])) }
        let tiny = max(scale, 1e-300) * 1e-13
        for k in 0..<n {
            var p = k, mv = abs(a[k * n + k])
            for i in (k + 1)..<max(n, k + 1) where abs(a[i * n + k]) > mv { mv = abs(a[i * n + k]); p = i }
            if p != k {
                for j in 0..<n { a.swapAt(k * n + j, p * n + j) }
                piv.swapAt(k, p)
            }
            if abs(a[k * n + k]) < tiny {
                // Singular direction (e.g. pure-Neumann pressure): regularise.
                a[k * n + k] = a[k * n + k] >= 0 ? max(tiny, scale) : -max(tiny, scale)
            }
            let inv = 1 / a[k * n + k]
            for i in (k + 1)..<max(n, k + 1) {
                let f = a[i * n + k] * inv
                if f == 0 { continue }
                a[i * n + k] = f
                for j in (k + 1)..<n { a[i * n + j] -= f * a[k * n + j] }
            }
        }
    }
    func solve(_ b: [Double], into x: inout [Double]) {
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n { y[i] = b[piv[i]] }
        for i in 0..<n {
            var s = y[i]
            for j in 0..<i { s -= a[i * n + j] * y[j] }
            y[i] = s
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for j in (i + 1)..<max(n, i + 1) { s -= a[i * n + j] * y[j] }
            y[i] = s / a[i * n + i]
        }
        x = y
    }
}
