import Foundation

public struct ExpressionError: Error, LocalizedError, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Compiled arithmetic expression (Fluent "named expressions" subset).
///
/// Grammar: numbers, identifiers (x y z t pi e and named expressions), + - * / ^,
/// unary minus, parentheses, comparison (< > <= >= == !=, yielding 0/1) and
/// functions sin cos tan asin acos atan atan2 sinh cosh tanh exp log log10 sqrt
/// abs min max pow if(cond, a, b) step(x). Units in square brackets (e.g.
/// `2 [m/s]`) are accepted and ignored; values are SI. This is a pure arithmetic
/// tree walker: nothing is executed beyond the listed math functions.
public final class Expr: @unchecked Sendable {
    indirect enum Node {
        case num(Double)
        case variable(Int)            // 0 x, 1 y, 2 z, 3 t
        case named(String)
        case unary(Character, Node)
        case binary(String, Node, Node)
        case call(String, [Node])
    }
    let root: Node
    public let source: String
    var named: [String: Expr] = [:]

    static let arity: [String: ClosedRange<Int>] = [
        "sin": 1...1, "cos": 1...1, "tan": 1...1, "asin": 1...1, "acos": 1...1, "atan": 1...1, "atan2": 2...2,
        "sinh": 1...1, "cosh": 1...1, "tanh": 1...1, "exp": 1...1, "log": 1...1, "ln": 1...1, "log10": 1...1,
        "sqrt": 1...1, "abs": 1...1, "min": 2...8, "max": 2...8, "pow": 2...2, "if": 3...3, "step": 1...1,
        "floor": 1...1, "ceil": 1...1, "sign": 1...1, "mod": 2...2]

    public init(_ text: String, named: [String: Expr] = [:]) throws {
        source = text
        var p = ExprParser(text)
        root = try p.parseExpression()
        p.skipSpace()
        guard p.atEnd else { throw ExpressionError(message: "unexpected '\(p.rest)' in expression '\(text)'") }
        self.named = named
        try validate(root, depth: 0)
    }

    init(root: Node, source: String) { self.root = root; self.source = source }

    func validate(_ n: Node, depth: Int) throws {
        guard depth < 64 else { throw ExpressionError(message: "expression nested too deeply (recursive named expression?)") }
        switch n {
        case .named(let name):
            guard let e = named[name] else { throw ExpressionError(message: "unknown name '\(name)'") }
            try e.validate(e.root, depth: depth + 1)
        case .unary(_, let a): try validate(a, depth: depth)
        case .binary(_, let a, let b): try validate(a, depth: depth); try validate(b, depth: depth)
        case .call(let f, let args):
            guard let r = Expr.arity[f] else { throw ExpressionError(message: "unknown function '\(f)'") }
            guard r.contains(args.count) else { throw ExpressionError(message: "\(f) takes \(r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)") arguments") }
            for a in args { try validate(a, depth: depth) }
        default: break
        }
    }

    public func value(x: Double = 0, y: Double = 0, z: Double = 0, t: Double = 0) -> Double {
        compute(root, x, y, z, t)
    }

    func compute(_ n: Node, _ x: Double, _ y: Double, _ z: Double, _ t: Double) -> Double {
        switch n {
        case .num(let v): return v
        case .variable(let i): return i == 0 ? x : i == 1 ? y : i == 2 ? z : t
        case .named(let name): return named[name]?.value(x: x, y: y, z: z, t: t) ?? .nan
        case .unary(_, let a): return -compute(a, x, y, z, t)
        case .binary(let op, let a, let b):
            let l = compute(a, x, y, z, t), r = compute(b, x, y, z, t)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return l / r
            case "^": return pow(l, r)
            case "<": return l < r ? 1 : 0
            case ">": return l > r ? 1 : 0
            case "<=": return l <= r ? 1 : 0
            case ">=": return l >= r ? 1 : 0
            case "==": return l == r ? 1 : 0
            case "!=": return l != r ? 1 : 0
            case "&&": return (l != 0 && r != 0) ? 1 : 0
            case "||": return (l != 0 || r != 0) ? 1 : 0
            default: return .nan
            }
        case .call(let f, let args):
            let v = args.map { compute($0, x, y, z, t) }
            switch f {
            case "sin": return sin(v[0])
            case "cos": return cos(v[0])
            case "tan": return tan(v[0])
            case "asin": return asin(v[0])
            case "acos": return acos(v[0])
            case "atan": return atan(v[0])
            case "atan2": return atan2(v[0], v[1])
            case "sinh": return sinh(v[0])
            case "cosh": return cosh(v[0])
            case "tanh": return tanh(v[0])
            case "exp": return exp(v[0])
            case "log", "ln": return log(v[0])
            case "log10": return log10(v[0])
            case "sqrt": return sqrt(v[0])
            case "abs": return abs(v[0])
            case "min": return v.min()!
            case "max": return v.max()!
            case "pow": return pow(v[0], v[1])
            case "if": return v[0] != 0 ? v[1] : v[2]
            case "step": return v[0] >= 0 ? 1 : 0
            case "floor": return floor(v[0])
            case "ceil": return ceil(v[0])
            case "sign": return v[0] > 0 ? 1 : (v[0] < 0 ? -1 : 0)
            case "mod": return fmod(v[0], v[1])
            default: return .nan
            }
        }
    }

    /// Compile a set of named expressions that may reference one another.
    public static func compileNamed(_ list: [(String, String)]) throws -> [String: Expr] {
        var out: [String: Expr] = [:]
        var parsed: [(String, Expr)] = []
        for (name, text) in list {
            var p = ExprParser(text)
            let root = try p.parseExpression()
            p.skipSpace()
            guard p.atEnd else { throw ExpressionError(message: "unexpected '\(p.rest)' in '\(name)'") }
            parsed.append((name, Expr(root: root, source: text)))
        }
        for (n, e) in parsed { out[n] = e }
        for (_, e) in parsed { e.named = out }
        for (_, e) in parsed { try e.validate(e.root, depth: 0) }
        return out
    }
}

struct ExprParser {
    let chars: [Character]
    var i = 0
    init(_ s: String) { chars = Array(s) }
    var atEnd: Bool { i >= chars.count }
    var rest: String { String(chars[i...]) }

    mutating func skipSpace() {
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            if chars[i] == "[" { // units annotation
                while i < chars.count && chars[i] != "]" { i += 1 }
                i += 1; continue
            }
            break
        }
    }
    mutating func peek(_ s: String) -> Bool {
        skipSpace()
        let a = Array(s)
        guard i + a.count <= chars.count else { return false }
        for k in 0..<a.count where chars[i + k] != a[k] { return false }
        return true
    }
    mutating func eat(_ s: String) -> Bool {
        if peek(s) { i += s.count; return true }
        return false
    }

    mutating func parseExpression() throws -> Expr.Node { try parseOr() }

    mutating func parseOr() throws -> Expr.Node {
        var l = try parseAnd()
        while eat("||") { l = .binary("||", l, try parseAnd()) }
        return l
    }
    mutating func parseAnd() throws -> Expr.Node {
        var l = try parseComparison()
        while eat("&&") { l = .binary("&&", l, try parseComparison()) }
        return l
    }
    mutating func parseComparison() throws -> Expr.Node {
        let l = try parseSum()
        for op in ["<=", ">=", "==", "!=", "<", ">"] where eat(op) {
            return .binary(op, l, try parseSum())
        }
        return l
    }
    mutating func parseSum() throws -> Expr.Node {
        var l = try parseProduct()
        while true {
            if eat("+") { l = .binary("+", l, try parseProduct()) }
            else if eat("-") { l = .binary("-", l, try parseProduct()) }
            else { return l }
        }
    }
    mutating func parseProduct() throws -> Expr.Node {
        var l = try parseUnary()
        while true {
            if peek("**") { return l }
            if eat("*") { l = .binary("*", l, try parseUnary()) }
            else if eat("/") { l = .binary("/", l, try parseUnary()) }
            else { return l }
        }
    }
    mutating func parseUnary() throws -> Expr.Node {
        if eat("-") { return .unary("-", try parseUnary()) }
        if eat("+") { return try parseUnary() }
        return try parsePower()
    }
    mutating func parsePower() throws -> Expr.Node {
        let base = try parseAtom()
        if eat("^") || eat("**") { return .binary("^", base, try parseUnary()) }
        return base
    }
    mutating func parseAtom() throws -> Expr.Node {
        skipSpace()
        guard i < chars.count else { throw ExpressionError(message: "unexpected end of expression") }
        let c = chars[i]
        if c == "(" {
            i += 1
            let e = try parseExpression()
            guard eat(")") else { throw ExpressionError(message: "missing ')'") }
            return e
        }
        if c.isNumber || c == "." {
            let s = i
            while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
            if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
                let save = i
                i += 1
                if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                if i < chars.count && chars[i].isNumber { while i < chars.count && chars[i].isNumber { i += 1 } } else { i = save }
            }
            guard let v = Double(String(chars[s..<i])) else { throw ExpressionError(message: "bad number") }
            return .num(v)
        }
        if c.isLetter || c == "_" {
            let s = i
            while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == ".") { i += 1 }
            let name = String(chars[s..<i])
            if eat("(") {
                var args: [Expr.Node] = []
                if !eat(")") {
                    repeat { args.append(try parseExpression()) } while eat(",")
                    guard eat(")") else { throw ExpressionError(message: "missing ')' after arguments of \(name)") }
                }
                return .call(name.lowercased(), args)
            }
            switch name {
            case "x": return .variable(0)
            case "y": return .variable(1)
            case "z": return .variable(2)
            case "t", "Time", "time": return .variable(3)
            case "pi", "PI": return .num(Double.pi)
            case "e": return .num(M_E)
            default: return .named(name)
            }
        }
        throw ExpressionError(message: "unexpected character '\(c)'")
    }
}

// MARK: - OpenFOAM translation

extension Expr {
    /// True when the expression (or a named expression it uses) depends on time `t`.
    public var dependsOnTime: Bool { usesTime(root, depth: 0) }

    func usesTime(_ n: Node, depth: Int) -> Bool {
        guard depth < 64 else { return false }
        switch n {
        case .variable(let i): return i == 3
        case .named(let name): return named[name].map { $0.usesTime($0.root, depth: depth + 1) } ?? false
        case .unary(_, let a): return usesTime(a, depth: depth)
        case .binary(_, let a, let b): return usesTime(a, depth: depth) || usesTime(b, depth: depth)
        case .call(_, let args): return args.contains { usesTime($0, depth: depth) }
        case .num: return false
        }
    }

    /// The expression in OpenFOAM's expression syntax (exprField sources, exprFixedValue
    /// boundary conditions): x, y, z become cell or face centre components `pos().x()`…,
    /// t becomes `time()`, named expressions are inlined, `^` becomes `pow`, comparisons
    /// used as numbers become `(c ? 1 : 0)` and `if(c, a, b)` becomes `(c ? a : b)`.
    public func openFOAM() -> String { foam(root, bool: false, depth: 0) }

    public static func foamNumber(_ v: Double) -> String {
        var s = "\(abs(v))"          // shortest round-trip form
        if !s.contains(".") && !s.contains("e") { s += ".0" }
        if v < 0 { s = "-" + s }
        return v < 0 ? "(\(s))" : s
    }

    func foam(_ n: Node, bool: Bool, depth: Int) -> String {
        func val(_ x: Node) -> String { foam(x, bool: false, depth: depth) }
        func cond(_ x: Node) -> String { foam(x, bool: true, depth: depth) }
        let comparisons: Set<String> = ["<", ">", "<=", ">=", "==", "!="]
        switch n {
        case .num(let v):
            return bool ? "(\(Expr.foamNumber(v)) != 0)" : Expr.foamNumber(v)
        case .variable(let i):
            let s = ["pos().x()", "pos().y()", "pos().z()", "time()"][i]
            return bool ? "(\(s) != 0)" : s
        case .named(let name):
            guard let e = named[name], depth < 64 else { return "0" }
            return "(" + e.foam(e.root, bool: bool, depth: depth + 1) + ")"
        case .unary(_, let a):
            return bool ? "(-\(val(a)) != 0)" : "(-\(val(a)))"
        case .binary(let op, let a, let b):
            if comparisons.contains(op) {
                let c = "(\(val(a)) \(op) \(val(b)))"
                return bool ? c : "(\(c) ? 1.0 : 0.0)"
            }
            if op == "&&" || op == "||" {
                let c = "(\(cond(a)) \(op) \(cond(b)))"
                return bool ? c : "(\(c) ? 1.0 : 0.0)"
            }
            let v = op == "^" ? "pow(\(val(a)), \(val(b)))" : "(\(val(a)) \(op) \(val(b)))"
            return bool ? "(\(v) != 0)" : v
        case .call(let f, let args):
            let v: String
            switch f {
            case "if": v = "(\(cond(args[0])) ? \(val(args[1])) : \(val(args[2])))"
            case "abs": v = "mag(\(val(args[0])))"
            case "ln": v = "log(\(val(args[0])))"
            case "step": v = "((\(val(args[0])) >= 0) ? 1.0 : 0.0)"
            case "sign": v = "((\(val(args[0])) > 0) ? 1.0 : ((\(val(args[0])) < 0) ? -1.0 : 0.0))"
            case "mod":
                let a = val(args[0]), b = val(args[1])
                v = "(\(a) - \(b)*(((\(a))/(\(b)) >= 0) ? floor((\(a))/(\(b))) : ceil((\(a))/(\(b)))))"
            case "log10": v = "(log(\(val(args[0])))/log(10.0))"
            case "atan2":
                // patch expressions have no atan2
                let a = val(args[0]), b = val(args[1])
                v = "((\(b) > 0) ? atan((\(a))/(\(b))) : ((\(b) < 0) ? (atan((\(a))/(\(b))) + ((\(a) >= 0) ? pi() : -pi())) : ((\(a) >= 0) ? 0.5*pi() : -0.5*pi())))"
            case "min", "max":
                var acc = val(args[0])
                for x in args.dropFirst() { acc = "\(f)(\(acc), \(val(x)))" }
                v = acc
            default:
                v = "\(f)(" + args.map(val).joined(separator: ", ") + ")"
            }
            return bool ? "(\(v) != 0)" : v
        }
    }
}
