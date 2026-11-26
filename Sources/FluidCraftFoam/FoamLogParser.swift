import Foundation
import FluidCraftMesh

// MARK: - Events

/// Something worth acting on in an OpenFOAM log line.
public enum FoamLogEvent: Sendable, Equatable {
    case time(Double)
    case residual(field: String, initial: Double, final: Double, iterations: Int)
    case courant(mean: Double, max: Double)
    /// A scalar reported by a function object: `object` is its name in controlDict (a FluidCraft
    /// report name), `quantity` e.g. `Cd`, `Cl`, `CmPitch`, `areaAverage(p)`, `sum(phi)`.
    case functionValue(object: String, quantity: String, value: Double)
    /// A vector reported by a function object (`forces` totals, vector surface averages).
    case functionVector(object: String, quantity: String, value: Vec3)
    case meshCells(Int)
    case checkMesh(ok: Bool, failedChecks: Int)
    case maxNonOrthogonality(Double)
    case maxSkewness(Double)
    case snappyFinished(illegalFaces: Int)
    case layerCoverage(patch: String, faces: Int, targetLayers: Int, meshLayers: Double, thickness: Double, percent: Double)
    case yPlus(patch: String, min: Double, max: Double, average: Double)
    case warning(String)
    case fatal(String)
    case executionTime(Double)
    case end
}

// MARK: - Parser

/// Line-by-line recogniser for OpenFOAM (ESI v2xxx) solver, mesher and function-object
/// output. The residual, Courant and checkMesh patterns come from Chisel's parser, which was
/// checked against the v2606 sources; function objects are attributed to the object whose
/// `<type> <name> write:` header was seen last.
public struct FoamLogParser: Sendable {
    private var fatalLines: [String]? = nil
    private var currentObject: String? = nil
    private var currentType: String? = nil
    private var forceSection: String? = nil
    private var inLayerTable = false

    public init() {}

    public mutating func parse(_ line: String) -> [FoamLogEvent] {
        if var block = fatalLines {
            block.append(line)
            if line.contains("FOAM exiting") || line.contains("FOAM aborting") || block.count > 40 {
                fatalLines = nil
                return [.fatal(block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n"))]
            }
            fatalLines = block
            return []
        }
        if line.hasPrefix("--> FOAM FATAL") { fatalLines = [line]; return [] }
        if line.hasPrefix("--> FOAM Warning") { return [.warning(line)] }

        if line.hasPrefix("Time = ") {
            let t = line.dropFirst(7).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "s", with: "")
            currentObject = nil
            return Double(t).map { [.time($0)] } ?? []
        }
        if line == "End" { return [.end] }

        // snappyHexMesh layer table
        if line.hasPrefix("patch"), line.contains("faces"), line.contains("layers") { inLayerTable = true; return [] }
        if inLayerTable {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { inLayerTable = false; return [] }
            if let r = Self.layerRow.firstMatch(line), let faces = Int(r[2]), let target = Int(r[3]),
               let mesh = Double(r[4]), let thick = Double(r[5]), let pct = Double(r[6]) {
                return [.layerCoverage(patch: r[1], faces: faces, targetLayers: target, meshLayers: mesh, thickness: thick, percent: pct)]
            }
            return []
        }

        if let r = Self.residual.firstMatch(line), let i = Double(r[2]), let f = Double(r[3]), let n = Int(r[4]) {
            return [.residual(field: r[1], initial: i, final: f, iterations: n)]
        }
        if let r = Self.courant.firstMatch(line), let mean = Double(r[1]), let mx = Double(r[2]) {
            return [.courant(mean: mean, max: mx)]
        }
        if let r = Self.objectHeader.firstMatch(line) {
            currentType = r[1]; currentObject = r[2]; forceSection = nil
            return []
        }
        if let r = Self.yPlusLine.firstMatch(line), let mn = Double(r[2]), let mx = Double(r[3]), let av = Double(r[4]) {
            return [.yPlus(patch: r[1], min: mn, max: mx, average: av)]
        }
        if let obj = currentObject {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Sum of forces") { forceSection = "force"; return [] }
            if trimmed.hasPrefix("Sum of moments") { forceSection = "moment"; return [] }
            if let sec = forceSection, let r = Self.vectorEntry.firstMatch(line), r[1] == "Total",
               let x = Double(r[2]), let y = Double(r[3]), let z = Double(r[4]) {
                return [.functionVector(object: obj, quantity: sec, value: Vec3(x, y, z))]
            }
            if currentType == "forceCoeffs", let r = Self.coefficient.firstMatch(line), let v = Double(r[2]) {
                return [.functionValue(object: obj, quantity: r[1], value: v)]
            }
            if let r = Self.fieldValue.firstMatch(line) {
                let q = "\(r[1])(\(r[3]))"
                if let v = Double(r[4]) { return [.functionValue(object: obj, quantity: q, value: v)] }
                if let vr = Self.vectorValue.firstMatch(r[4]), let x = Double(vr[1]), let y = Double(vr[2]), let z = Double(vr[3]) {
                    return [.functionVector(object: obj, quantity: q, value: Vec3(x, y, z))]
                }
            }
            if let r = Self.minMax.firstMatch(line), let v = Double(r[3]) {
                return [.functionValue(object: obj, quantity: "\(r[1])(\(r[2]))", value: v)]
            }
        }
        if let r = Self.executionTime.firstMatch(line), let s = Double(r[1]) { return [.executionTime(s)] }
        if let r = Self.cells.firstMatch(line), let n = Int(r[1]) { return [.meshCells(n)] }
        if let r = Self.snappyCells.firstMatch(line), let n = Int(r[1]) { return [.meshCells(n)] }
        if line.contains("Finished meshing without any errors") { return [.snappyFinished(illegalFaces: 0)] }
        if let r = Self.snappyIllegal.firstMatch(line), let n = Int(r[1]) { return [.snappyFinished(illegalFaces: n)] }
        if line.trimmingCharacters(in: .whitespaces) == "Mesh OK." { return [.checkMesh(ok: true, failedChecks: 0)] }
        if let r = Self.failedChecks.firstMatch(line), let n = Int(r[1]) { return [.checkMesh(ok: false, failedChecks: n)] }
        if let r = Self.nonOrtho.firstMatch(line), let v = Double(r[1]) { return [.maxNonOrthogonality(v)] }
        if let r = Self.skewness.firstMatch(line), let v = Double(r[1]) { return [.maxSkewness(v)] }
        return []
    }

    // `smoothSolver:  Solving for Ux, Initial residual = 1, Final residual = 0.088, No Iterations 12`
    static let residual = FoamRegex(#"^\w+:\s+Solving for (\S+), Initial residual = ([^,]+), Final residual = ([^,]+), No Iterations (\d+)"#)
    static let courant = FoamRegex(#"^Courant Number mean: (\S+) max: (\S+)"#)
    // `forceCoeffs drag write:` / `surfaceFieldValue inletP write:` / `fieldMinMax minMax execute:`
    static let objectHeader = FoamRegex(#"^(\w+) (\S+) (?:write|execute):\s*$"#)
    // forceCoeffs v2606: `    Cd       : 0.4213` (also `Cd(f)`, `CmPitch`)
    static let coefficient = FoamRegex(#"^\s+(C[A-Za-z]+(?:\([fr]\))?)\s*:\s*([-+0-9.eE]+)"#)
    // forces: `        Total    : (1.2 0 0)`
    static let vectorEntry = FoamRegex(#"^\s+(Total|Pressure|Viscous|Porous)\s*:\s*\(([-+0-9.eE]+) ([-+0-9.eE]+) ([-+0-9.eE]+)\)"#)
    // surfaceFieldValue / volFieldValue: `    areaAverage(inlet) of p = 0.51` / `    sum(outlet) of phi = -0.02`
    static let fieldValue = FoamRegex(#"^\s+(\w+)\(([^)]*)\) of (\S+) = (.+)$"#)
    static let vectorValue = FoamRegex(#"^\(([-+0-9.eE]+) ([-+0-9.eE]+) ([-+0-9.eE]+)\)"#)
    static let minMax = FoamRegex(#"^\s+(min|max)\((\w[\w.]*)\) = ([-+0-9.eE]+)"#)
    static let executionTime = FoamRegex(#"^ExecutionTime = ([0-9.eE+-]+) s"#)
    static let cells = FoamRegex(#"^\s*(?:cells|nCells):\s+(\d+)"#)
    static let snappyCells = FoamRegex(#"mesh : cells:(\d+)"#)
    static let snappyIllegal = FoamRegex(#"Finished meshing with (\d+) illegal faces"#)
    static let failedChecks = FoamRegex(#"Failed (\d+) mesh checks"#)
    static let nonOrtho = FoamRegex(#"non-orthogonality (?:Max:|= )\s*([0-9.eE+-]+)"#)
    static let skewness = FoamRegex(#"Max skewness = ([0-9.eE+-]+)"#)
    static let layerRow = FoamRegex(#"^(\S+)\s+(\d+)\s+(\d+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s*$"#)
    static let yPlusLine = FoamRegex(#"^\s+patch (\S+) y\+ : min = ([0-9.eE+-]+), max = ([0-9.eE+-]+), average = ([0-9.eE+-]+)"#)
}

/// One-line regex helper.
struct FoamRegex: @unchecked Sendable {
    private let re: NSRegularExpression
    init(_ pattern: String) { re = (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression() }
    /// Capture groups 0…n as strings, or nil.
    func firstMatch(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

// MARK: - Metrics

/// Run state accumulated from events, in the shape FluidCraft's residual and report charts use.
public struct FoamRunMetrics: Sendable {
    public var currentTime = 0.0
    public var timeSteps = 0
    /// Initial residual of the first solve of each field in a time step (what
    /// residualControl judges), keyed by OpenFOAM field name (Ux, p, k …).
    public var residuals: [String: [(time: Double, value: Double)]] = [:]
    public var functionValues: [String: Double] = [:]
    public var functionVectors: [String: Vec3] = [:]
    public var courantMax = 0.0
    public var meshCells: Int?
    public var checkMeshOK: Bool?
    public var failedChecks = 0
    public var maxNonOrthogonality: Double?
    public var maxSkewness: Double?
    public var illegalFaces: Int?
    public var fatal: String?
    public var warnings: [String] = []
    public var executionTime: Double?
    public var ended = false
    public var layerCoverage: [String: Double] = [:]
    public var yPlus: [String: (min: Double, max: Double, average: Double)] = [:]
    private var seenThisStep: Set<String> = []

    public init() {}

    /// Returns true when the event starts a new time step (callers record a row then).
    @discardableResult
    public mutating func apply(_ e: FoamLogEvent) -> Bool {
        switch e {
        case .time(let t):
            currentTime = t; timeSteps += 1; seenThisStep.removeAll()
            return true
        case .residual(let f, let initial, _, _):
            guard seenThisStep.insert(f).inserted else { break }
            residuals[f, default: []].append((currentTime, max(initial, 1e-30)))
        case .courant(_, let mx): courantMax = mx
        case .functionValue(let o, let q, let v): functionValues["\(o)/\(q)"] = v
        case .functionVector(let o, let q, let v): functionVectors["\(o)/\(q)"] = v
        case .meshCells(let n): meshCells = n
        case .checkMesh(let ok, let n): checkMeshOK = ok; failedChecks = n
        case .maxNonOrthogonality(let v): maxNonOrthogonality = v
        case .maxSkewness(let v): maxSkewness = v
        case .snappyFinished(let n): illegalFaces = n
        case .layerCoverage(let p, _, _, _, _, let pct): layerCoverage[p] = pct
        case .yPlus(let p, let mn, let mx, let av): yPlus[p] = (mn, mx, av)
        case .warning(let w): if warnings.count < 200 { warnings.append(w) }
        case .fatal(let f): fatal = f
        case .executionTime(let s): executionTime = s
        case .end: ended = true
        }
        return false
    }

    /// Latest initial residual per field.
    public var latestResiduals: [String: Double] {
        residuals.compactMapValues { $0.last?.value }
    }
}
