import Foundation

public enum Smoother {
    /// One Gauss-Seidel sweep. Large systems use a deterministic hybrid scheme:
    /// rows are split into fixed chunks swept in parallel; couplings that cross
    /// chunk boundaries read the values from before the sweep (`snapshot`).
    public static func gaussSeidel(_ A: SparseMatrix, x: inout [Double], b: [Double],
                                   snapshot: inout [Double], forward: Bool) {
        let n = A.n
        let chunks = Parallel.chunkCount(n, minChunk: 4096)
        if snapshot.count != n { snapshot = [Double](repeating: 0, count: n) }
        if chunks > 1 { snapshot.withUnsafeMutableBufferPointer { s in x.withUnsafeBufferPointer { xs in s.baseAddress!.update(from: xs.baseAddress!, count: n) } } }
        A.pattern.rowPtr.withUnsafeBufferPointer { rp in
        A.pattern.colIdx.withUnsafeBufferPointer { cp in
        A.pattern.diag.withUnsafeBufferPointer { dp in
        A.values.withUnsafeBufferPointer { vp in
        b.withUnsafeBufferPointer { bp in
        snapshot.withUnsafeBufferPointer { sp in
        x.withUnsafeMutableBufferPointer { xp in
            let R = rp.baseAddress!, C = cp.baseAddress!, D = dp.baseAddress!, V = vp.baseAddress!
            let B = bp.baseAddress!, S = sp.baseAddress!, X = SharedPtr(xp.baseAddress!)
            if chunks == 1 {
                if forward {
                    for i in 0..<n { sweepRow(i, R, C, D, V, B, X) }
                } else {
                    var i = n - 1
                    while i >= 0 { sweepRow(i, R, C, D, V, B, X); i -= 1 }
                }
                return
            }
            let Rc = ConstPtr(R), Cc = ConstPtr(C), Dc = ConstPtr(D), Vc = ConstPtr(V), Bc = ConstPtr(B), Sc = ConstPtr(S)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let R = Rc, C = Cc, D = Dc, V = Vc, B = Bc, S = Sc
                let r = Parallel.range(c, of: chunks, n: n)
                let lo = Int32(r.lowerBound), hi = Int32(r.upperBound)
                @inline(__always) func row(_ i: Int) {
                    var s = B[i]
                    let dk = Int(D[i])
                    for k in Int(R[i])..<Int(R[i + 1]) where k != dk {
                        let j = C[k]
                        s -= V[k] * ((j >= lo && j < hi) ? X[Int(j)] : S[Int(j)])
                    }
                    let a = V[dk]
                    if a != 0 { X[i] = s / a }
                }
                if forward { for i in r { row(i) } }
                else { var i = r.upperBound - 1; while i >= r.lowerBound { row(i); i -= 1 } }
            }
        }}}}}}}
    }

    @inline(__always) static func sweepRow(_ i: Int, _ R: UnsafePointer<Int32>, _ C: UnsafePointer<Int32>,
                                           _ D: UnsafePointer<Int32>, _ V: UnsafePointer<Double>,
                                           _ B: UnsafePointer<Double>, _ X: SharedPtr<Double>) {
        var s = B[i]
        let dk = Int(D[i])
        for k in Int(R[i])..<Int(R[i + 1]) where k != dk { s -= V[k] * X[Int(C[k])] }
        let a = V[dk]
        if a != 0 { X[i] = s / a }
    }

    /// Damped Jacobi sweep.
    public static func jacobi(_ A: SparseMatrix, x: inout [Double], b: [Double], work: inout [Double], omega: Double = 0.8) {
        let n = A.n
        if work.count != n { work = [Double](repeating: 0, count: n) }
        A.residual(x: x, b: b, into: &work)
        for i in 0..<n {
            let a = A.diagonal(i)
            if a != 0 { x[i] += omega * work[i] / a }
        }
    }
}
