import Foundation

/// Sparsity pattern shared by all matrices assembled on the same mesh.
public final class SparsePattern: @unchecked Sendable {
    public let n: Int
    public let rowPtr: [Int32]
    public let colIdx: [Int32]
    /// Index of the diagonal entry of each row.
    public let diag: [Int32]
    public var nnz: Int { colIdx.count }

    public init(n: Int, rowPtr: [Int32], colIdx: [Int32]) {
        self.n = n; self.rowPtr = rowPtr; self.colIdx = colIdx
        var d = [Int32](repeating: -1, count: n)
        for i in 0..<n {
            for k in Int(rowPtr[i])..<Int(rowPtr[i + 1]) where Int(colIdx[k]) == i { d[i] = Int32(k); break }
        }
        diag = d
    }

    /// Pattern of a cell-centred FVM operator: diagonal plus one entry per
    /// owner/neighbour pair. Returns the pattern and, for each pair, the CSR
    /// positions of (owner,neighbour) and (neighbour,owner).
    public static func fromPairs(n: Int, owner: [Int32], neighbour: [Int32]) -> (SparsePattern, upper: [Int32], lower: [Int32]) {
        let nf = neighbour.count
        var counts = [Int32](repeating: 1, count: n + 1)
        counts[n] = 0
        for f in 0..<nf { counts[Int(owner[f])] += 1; counts[Int(neighbour[f])] += 1 }
        var rowPtr = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { rowPtr[i + 1] = rowPtr[i] + counts[i] }
        // Gather columns per row, then sort each row.
        var cols = [Int32](repeating: 0, count: Int(rowPtr[n]))
        var fill = Array(rowPtr[0..<n])
        for i in 0..<n { cols[Int(fill[i])] = Int32(i); fill[i] += 1 }
        for f in 0..<nf {
            let o = Int(owner[f]), ne = Int(neighbour[f])
            cols[Int(fill[o])] = Int32(ne); fill[o] += 1
            cols[Int(fill[ne])] = Int32(o); fill[ne] += 1
        }
        for i in 0..<n {
            let s = Int(rowPtr[i]), e = Int(rowPtr[i + 1])
            cols[s..<e].sort()
        }
        // Remove duplicate columns (several faces between the same cell pair).
        var newRowPtr = [Int32](repeating: 0, count: n + 1)
        var dedup: [Int32] = []
        dedup.reserveCapacity(cols.count)
        for i in 0..<n {
            let s = Int(rowPtr[i]), e = Int(rowPtr[i + 1])
            var last: Int32 = -1
            for k in s..<e where cols[k] != last { dedup.append(cols[k]); last = cols[k] }
            newRowPtr[i + 1] = Int32(dedup.count)
        }
        let pat = SparsePattern(n: n, rowPtr: newRowPtr, colIdx: dedup)
        var upper = [Int32](repeating: 0, count: nf)
        var lower = [Int32](repeating: 0, count: nf)
        for f in 0..<nf {
            upper[f] = Int32(pat.find(row: Int(owner[f]), col: Int(neighbour[f])))
            lower[f] = Int32(pat.find(row: Int(neighbour[f]), col: Int(owner[f])))
        }
        return (pat, upper, lower)
    }

    /// Binary search for (row, col); returns -1 if absent.
    public func find(row: Int, col: Int) -> Int {
        var lo = Int(rowPtr[row]), hi = Int(rowPtr[row + 1]) - 1
        let c = Int32(col)
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = colIdx[mid]
            if v == c { return mid }
            if v < c { lo = mid + 1 } else { hi = mid - 1 }
        }
        return -1
    }
}

/// CSR matrix with a shared pattern.
public final class SparseMatrix: @unchecked Sendable {
    public let pattern: SparsePattern
    public var values: [Double]
    public var n: Int { pattern.n }

    public init(pattern: SparsePattern) {
        self.pattern = pattern
        values = [Double](repeating: 0, count: pattern.nnz)
    }
    public init(pattern: SparsePattern, values: [Double]) {
        self.pattern = pattern; self.values = values
    }

    public func zero() {
        values.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.update(repeating: 0, count: p.count)
        }
    }

    public func copy() -> SparseMatrix { SparseMatrix(pattern: pattern, values: values) }

    @inline(__always) public func diagonal(_ i: Int) -> Double { values[Int(pattern.diag[i])] }

    /// y = A x
    public func multiply(_ x: [Double], into y: inout [Double]) {
        let n = pattern.n
        pattern.rowPtr.withUnsafeBufferPointer { rp in
        pattern.colIdx.withUnsafeBufferPointer { ci in
        values.withUnsafeBufferPointer { v in
        x.withUnsafeBufferPointer { xp in
        y.withUnsafeMutableBufferPointer { yp in
            let R = rp.baseAddress!, C = ci.baseAddress!, V = v.baseAddress!, X = xp.baseAddress!
            let Y = SharedPtr(yp.baseAddress!)
            Parallel.forEach(n) { range in
                for i in range {
                    var s = 0.0
                    for k in Int(R[i])..<Int(R[i + 1]) { s += V[k] * X[Int(C[k])] }
                    Y[i] = s
                }
            }
        }}}}}
    }

    /// r = b - A x, returns sum |r_i|.
    @discardableResult
    public func residual(x: [Double], b: [Double], into r: inout [Double]) -> Double {
        let n = pattern.n
        return pattern.rowPtr.withUnsafeBufferPointer { rp in
        pattern.colIdx.withUnsafeBufferPointer { ci in
        values.withUnsafeBufferPointer { v in
        x.withUnsafeBufferPointer { xp in
        b.withUnsafeBufferPointer { bp in
        r.withUnsafeMutableBufferPointer { rr in
            let R = rp.baseAddress!, C = ci.baseAddress!, V = v.baseAddress!, X = xp.baseAddress!, B = bp.baseAddress!
            let Rr = SharedPtr(rr.baseAddress!)
            return Parallel.sum(n) { range in
                var acc = 0.0
                for i in range {
                    var s = B[i]
                    for k in Int(R[i])..<Int(R[i + 1]) { s -= V[k] * X[Int(C[k])] }
                    Rr[i] = s
                    acc += abs(s)
                }
                return acc
            }
        }}}}}}
    }

    /// Sum over rows of |a_ii x_i| — Fluent's residual normalisation.
    public func diagonalNorm(x: [Double]) -> Double {
        var s = 0.0
        for i in 0..<pattern.n { s += abs(values[Int(pattern.diag[i])] * x[i]) }
        return s
    }
}
