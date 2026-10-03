import Foundation

public enum LinearMethod: String, Codable, CaseIterable, Sendable {
    /// Flexible CG preconditioned by AMG (symmetric systems: pressure, wall distance).
    case amgCG = "amg-cg"
    /// BiCGStab preconditioned by an AMG V-cycle (nonsymmetric transport equations).
    case amgBiCGStab = "amg-bicgstab"
    /// AMG cycles used directly as the solver (Fluent's default style).
    case amg
    /// Plain Gauss-Seidel sweeps.
    case gaussSeidel = "gauss-seidel"
}

public struct LinearSolverSettings: Codable, Sendable, Equatable {
    public var method: LinearMethod
    public var cycle: AMGCycle
    /// Stop when ||r|| <= relTol * ||r0|| (Fluent's AMG "termination criterion").
    public var relTol: Double
    public var absTol: Double
    public var maxIterations: Int
    /// Rebuild aggregates every N solves (coarse values are refreshed every solve).
    public var rebuildInterval: Int

    public init(method: LinearMethod, cycle: AMGCycle = .v, relTol: Double = 0.1, absTol: Double = 1e-20,
                maxIterations: Int = 50, rebuildInterval: Int = 50) {
        self.method = method; self.cycle = cycle; self.relTol = relTol; self.absTol = absTol
        self.maxIterations = maxIterations; self.rebuildInterval = rebuildInterval
    }
    public static let pressure = LinearSolverSettings(method: .amgCG, cycle: .k, relTol: 0.01, maxIterations: 100)
    public static let transport = LinearSolverSettings(method: .amgBiCGStab, cycle: .v, relTol: 0.1, maxIterations: 30)
}

public struct LinearSolveStats: Sendable {
    public var iterations: Int
    public var initialResidual: Double
    public var finalResidual: Double
    public var converged: Bool
}

/// Owns the AMG hierarchy and work vectors for one equation.
public final class LinearSolver: @unchecked Sendable {
    public var settings: LinearSolverSettings
    public let amg = AMGHierarchy()
    var solveCount = 0
    var builtFor: ObjectIdentifier? = nil
    var r: [Double] = [], z: [Double] = [], p: [Double] = [], q: [Double] = []
    var rhat: [Double] = [], v: [Double] = [], s: [Double] = [], t: [Double] = [], phat: [Double] = [], shat: [Double] = []
    var snapshot: [Double] = []
    /// Optional GPU backend; when set and the system is large it handles the solve.
    public var accelerator: LinearAccelerator? = nil

    public init(_ settings: LinearSolverSettings) { self.settings = settings }

    func ensure(_ n: Int) {
        if r.count != n {
            r = [Double](repeating: 0, count: n)
            z = r; p = r; q = r; rhat = r; v = r; s = r; t = r; phat = r; shat = r; snapshot = r
        }
    }

    func prepareAMG(_ A: SparseMatrix) {
        let id = ObjectIdentifier(A.pattern)
        if builtFor != id || solveCount % max(settings.rebuildInterval, 1) == 0 {
            amg.setup(A); builtFor = id
        } else {
            amg.updateValues(A)
        }
        solveCount += 1
    }

    @discardableResult
    public func solve(_ A: SparseMatrix, x: inout [Double], b: [Double]) -> LinearSolveStats {
        let n = A.n
        ensure(n)
        if let acc = accelerator, acc.shouldHandle(n: n, method: settings.method) {
            prepareAMG(A)
            return acc.solve(A, x: &x, b: b, settings: settings, amg: amg)
        }
        switch settings.method {
        case .gaussSeidel: return solveGS(A, &x, b)
        case .amg: prepareAMG(A); return solveAMG(A, &x, b)
        case .amgCG: prepareAMG(A); return solveFCG(A, &x, b)
        case .amgBiCGStab: prepareAMG(A); return solveBiCGStab(A, &x, b)
        }
    }

    func norm2(_ a: [Double]) -> Double { sqrt(dotp(a, a)) }

    func solveGS(_ A: SparseMatrix, _ x: inout [Double], _ b: [Double]) -> LinearSolveStats {
        A.residual(x: x, b: b, into: &r)
        let r0 = norm2(r)
        var rn = r0, it = 0
        if r0 <= settings.absTol { return LinearSolveStats(iterations: 0, initialResidual: r0, finalResidual: r0, converged: true) }
        while it < settings.maxIterations {
            Smoother.gaussSeidel(A, x: &x, b: b, snapshot: &snapshot, forward: true)
            Smoother.gaussSeidel(A, x: &x, b: b, snapshot: &snapshot, forward: false)
            it += 1
            A.residual(x: x, b: b, into: &r)
            rn = norm2(r)
            if rn <= settings.relTol * r0 || rn <= settings.absTol { break }
        }
        return LinearSolveStats(iterations: it, initialResidual: r0, finalResidual: rn, converged: rn <= settings.relTol * r0)
    }

    func solveAMG(_ A: SparseMatrix, _ x: inout [Double], _ b: [Double]) -> LinearSolveStats {
        A.residual(x: x, b: b, into: &r)
        let r0 = norm2(r)
        var rn = r0, it = 0
        if r0 <= settings.absTol { return LinearSolveStats(iterations: 0, initialResidual: r0, finalResidual: r0, converged: true) }
        let cyc: AMGCycle = settings.cycle == .k ? .w : settings.cycle
        while it < settings.maxIterations {
            amg.apply(r, into: &z, cycle: cyc)
            for i in 0..<n(x) { x[i] += z[i] }
            it += 1
            A.residual(x: x, b: b, into: &r)
            rn = norm2(r)
            if rn <= settings.relTol * r0 || rn <= settings.absTol { break }
        }
        return LinearSolveStats(iterations: it, initialResidual: r0, finalResidual: rn, converged: rn <= settings.relTol * r0)
    }

    @inline(__always) func n(_ a: [Double]) -> Int { a.count }

    /// Flexible conjugate gradients (FCG(1) / GCR form), robust to nonlinear preconditioners.
    func solveFCG(_ A: SparseMatrix, _ x: inout [Double], _ b: [Double]) -> LinearSolveStats {
        let N = A.n
        A.residual(x: x, b: b, into: &r)
        let r0 = norm2(r)
        var rn = r0, it = 0
        if r0 <= settings.absTol { return LinearSolveStats(iterations: 0, initialResidual: r0, finalResidual: r0, converged: true) }
        var pq = 0.0
        while it < settings.maxIterations {
            amg.apply(r, into: &z, cycle: settings.cycle)
            if it == 0 {
                p = z
            } else {
                let beta = -dotp(z, q) / pq
                for i in 0..<N { p[i] = z[i] + beta * p[i] }
            }
            A.multiply(p, into: &q)
            pq = dotp(p, q)
            if pq <= 0 || !pq.isFinite { break }
            let alpha = dotp(p, r) / pq
            x.withUnsafeMutableBufferPointer { xp in r.withUnsafeMutableBufferPointer { rp in
                p.withUnsafeBufferPointer { pp in q.withUnsafeBufferPointer { qp in
                    let X = SharedPtr(xp.baseAddress!), R = SharedPtr(rp.baseAddress!)
                    let P = pp.baseAddress!, Q = qp.baseAddress!
                    Parallel.forEach(N) { range in for i in range { X[i] += alpha * P[i]; R[i] -= alpha * Q[i] } }
                }}
            }}
            it += 1
            rn = norm2(r)
            if rn <= settings.relTol * r0 || rn <= settings.absTol { break }
        }
        return LinearSolveStats(iterations: it, initialResidual: r0, finalResidual: rn, converged: rn <= settings.relTol * r0)
    }

    /// Right-preconditioned BiCGStab with a fixed AMG V-cycle.
    func solveBiCGStab(_ A: SparseMatrix, _ x: inout [Double], _ b: [Double]) -> LinearSolveStats {
        let N = A.n
        A.residual(x: x, b: b, into: &r)
        let r0 = norm2(r)
        var rn = r0, it = 0
        if r0 <= settings.absTol { return LinearSolveStats(iterations: 0, initialResidual: r0, finalResidual: r0, converged: true) }
        let cyc: AMGCycle = settings.cycle == .k ? .v : settings.cycle
        rhat = r
        var rho = 1.0, alpha = 1.0, omega = 1.0
        fill(&v, 0); fill(&p, 0)
        while it < settings.maxIterations {
            let rhoNew = dotp(rhat, r)
            if abs(rhoNew) < 1e-300 { break }
            let beta = (rhoNew / rho) * (alpha / omega)
            rho = rhoNew
            for i in 0..<N { p[i] = r[i] + beta * (p[i] - omega * v[i]) }
            amg.apply(p, into: &phat, cycle: cyc)
            A.multiply(phat, into: &v)
            let rv = dotp(rhat, v)
            if abs(rv) < 1e-300 { break }
            alpha = rho / rv
            for i in 0..<N { s[i] = r[i] - alpha * v[i] }
            let sn = norm2(s)
            it += 1
            if sn <= settings.relTol * r0 || sn <= settings.absTol {
                for i in 0..<N { x[i] += alpha * phat[i] }
                rn = sn
                break
            }
            amg.apply(s, into: &shat, cycle: cyc)
            A.multiply(shat, into: &t)
            let tt = dotp(t, t)
            omega = tt > 0 ? dotp(t, s) / tt : 0
            for i in 0..<N { x[i] += alpha * phat[i] + omega * shat[i]; r[i] = s[i] - omega * t[i] }
            rn = norm2(r)
            if rn <= settings.relTol * r0 || rn <= settings.absTol || omega == 0 { break }
        }
        return LinearSolveStats(iterations: it, initialResidual: r0, finalResidual: rn, converged: rn <= settings.relTol * r0)
    }
}

/// Hook for GPU (or other) linear-solve backends.
public protocol LinearAccelerator: AnyObject {
    func shouldHandle(n: Int, method: LinearMethod) -> Bool
    func solve(_ A: SparseMatrix, x: inout [Double], b: [Double], settings: LinearSolverSettings, amg: AMGHierarchy) -> LinearSolveStats
}
