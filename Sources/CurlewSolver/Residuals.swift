import Foundation

/// Scaled residual history (Fluent conventions).
public struct ResidualHistory: Codable, Sendable {
    public var names: [String] = []
    /// iteration -> residual per equation (aligned with names; NaN when not solved)
    public var iterations: [Int] = []
    public var values: [[Double]] = []
    /// Continuity normalisation: max imbalance over the first five iterations.
    public var continuityScale = 0.0
    var continuitySamples = 0

    public init() {}

    public mutating func record(iteration: Int, _ residuals: [String: Double]) {
        for k in residuals.keys.sorted() where !names.contains(k) {
            names.append(k)
            for i in 0..<values.count { values[i].append(.nan) }
        }
        iterations.append(iteration)
        values.append(names.map { residuals[$0] ?? .nan })
    }

    public func latest(_ name: String) -> Double? {
        guard let i = names.firstIndex(of: name), let last = values.last else { return nil }
        return last[i]
    }

    public func series(_ name: String) -> [(Int, Double)] {
        guard let i = names.firstIndex(of: name) else { return [] }
        return zip(iterations, values).compactMap { it, v in v[i].isNaN ? nil : (it, v[i]) }
    }

    /// Fluent: continuity residual / max of first five continuity residuals.
    public mutating func scaleContinuity(_ raw: Double) -> Double {
        if continuitySamples < 5 {
            continuityScale = max(continuityScale, raw)
            continuitySamples += 1
        }
        return continuityScale > 0 ? raw / continuityScale : raw
    }
}

/// Values of report definitions over iterations / time.
public struct ReportHistory: Codable, Sendable {
    public var names: [String] = []
    public var x: [Double] = []
    public var values: [[Double]] = []
    public init() {}
    public mutating func record(x: Double, _ v: [String: Double]) {
        for k in v.keys.sorted() where !names.contains(k) {
            names.append(k)
            for i in 0..<values.count { values[i].append(.nan) }
        }
        self.x.append(x)
        values.append(names.map { v[$0] ?? .nan })
    }
    public func series(_ name: String) -> [(Double, Double)] {
        guard let i = names.firstIndex(of: name) else { return [] }
        return zip(x, values).compactMap { a, v in v[i].isNaN ? nil : (a, v[i]) }
    }
}
