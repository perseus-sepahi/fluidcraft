import Foundation

/// A scalar input that is either a constant or an expression in x, y, z, t and
/// named expressions (Fluent's "expression" inputs). Encodes as a JSON number
/// or string.
public enum Quantity: Codable, Sendable, Equatable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, CustomStringConvertible {
    case constant(Double)
    case expression(String)

    public init(floatLiteral v: Double) { self = .constant(v) }
    public init(integerLiteral v: Int) { self = .constant(Double(v)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .constant(d); return }
        let s = try c.decode(String.self)
        if let d = Double(s.trimmingCharacters(in: .whitespaces)) { self = .constant(d) } else { self = .expression(s) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .constant(let d): try c.encode(d)
        case .expression(let s): try c.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .constant(let d): return Quantity.format(d)
        case .expression(let s): return s
        }
    }
    public static func format(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.0f", d) }
        return String(format: "%.6g", d)
    }
    /// Parse user text: a number becomes a constant, anything else an expression.
    public static func parse(_ text: String) -> Quantity {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let d = Double(t) { return .constant(d) }
        return .expression(t)
    }
    public var constantValue: Double? { if case .constant(let d) = self { return d }; return nil }
    public var isSpatiallyVarying: Bool {
        guard case .expression(let s) = self else { return false }
        return s.range(of: "[xyzt]", options: .regularExpression) != nil
    }
}
