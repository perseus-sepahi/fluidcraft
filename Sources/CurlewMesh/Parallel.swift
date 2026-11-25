import Foundation

/// Deterministic data-parallel helpers. Chunk counts depend only on problem
/// size (never on core count) so reductions produce bit-identical results on
/// every machine.
public enum Parallel {
    public static var maxChunks = 64
    public static var minChunk = 2048
    /// Set to 1 to force serial execution (debugging, tiny problems).
    public static var enabled = true

    @inline(__always) public static func chunkCount(_ n: Int, minChunk: Int = Parallel.minChunk) -> Int {
        guard enabled, n > minChunk else { return 1 }
        return min(maxChunks, (n + minChunk - 1) / minChunk)
    }

    @inline(__always) public static func range(_ i: Int, of chunks: Int, n: Int) -> Range<Int> {
        let base = n / chunks, extra = n % chunks
        let s = i * base + min(i, extra)
        return s..<(s + base + (i < extra ? 1 : 0))
    }

    /// Run `body` over contiguous sub-ranges of 0..<n.
    public static func forEach(_ n: Int, minChunk: Int = Parallel.minChunk, _ body: (Range<Int>) -> Void) {
        let c = chunkCount(n, minChunk: minChunk)
        if c == 1 { if n > 0 { body(0..<n) }; return }
        DispatchQueue.concurrentPerform(iterations: c) { i in body(range(i, of: c, n: n)) }
    }

    /// Deterministic parallel sum of `body(range)` partials.
    public static func sum(_ n: Int, minChunk: Int = Parallel.minChunk, _ body: (Range<Int>) -> Double) -> Double {
        let c = chunkCount(n, minChunk: minChunk)
        if c == 1 { return n > 0 ? body(0..<n) : 0 }
        var partial = [Double](repeating: 0, count: c)
        partial.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            DispatchQueue.concurrentPerform(iterations: c) { i in base[i] = body(range(i, of: c, n: n)) }
        }
        var s = 0.0
        for v in partial { s += v }
        return s
    }

    /// Deterministic parallel sums of two quantities at once.
    public static func sum2(_ n: Int, minChunk: Int = Parallel.minChunk, _ body: (Range<Int>) -> (Double, Double)) -> (Double, Double) {
        let c = chunkCount(n, minChunk: minChunk)
        if c == 1 { return n > 0 ? body(0..<n) : (0, 0) }
        var partial = [Double](repeating: 0, count: 2 * c)
        partial.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            DispatchQueue.concurrentPerform(iterations: c) { i in
                let (a, b) = body(range(i, of: c, n: n))
                base[2 * i] = a; base[2 * i + 1] = b
            }
        }
        var a = 0.0, b = 0.0
        for i in 0..<c { a += partial[2 * i]; b += partial[2 * i + 1] }
        return (a, b)
    }

    public static func max(_ n: Int, minChunk: Int = Parallel.minChunk, _ body: (Range<Int>) -> Double) -> Double {
        let c = chunkCount(n, minChunk: minChunk)
        if c == 1 { return n > 0 ? body(0..<n) : -Double.infinity }
        var partial = [Double](repeating: -Double.infinity, count: c)
        partial.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            DispatchQueue.concurrentPerform(iterations: c) { i in base[i] = body(range(i, of: c, n: n)) }
        }
        return partial.max() ?? -Double.infinity
    }
}

/// Unsafe pointer wrapper that can be captured by concurrent closures.
public struct SharedPtr<T>: @unchecked Sendable {
    public let p: UnsafeMutablePointer<T>
    public init(_ p: UnsafeMutablePointer<T>) { self.p = p }
    @inline(__always) public subscript(i: Int) -> T {
        get { p[i] }
        nonmutating set { p[i] = newValue }
    }
}

/// Read-only pointer wrapper that can be captured by concurrent closures.
public struct ConstPtr<T>: @unchecked Sendable {
    public let p: UnsafePointer<T>
    public init(_ p: UnsafePointer<T>) { self.p = p }
    @inline(__always) public subscript(i: Int) -> T { p[i] }
}
