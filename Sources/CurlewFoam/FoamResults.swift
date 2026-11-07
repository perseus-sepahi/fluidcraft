import Foundation
import CurlewMesh
import CurlewSolver

/// Reads a time directory of an OpenFOAM case written by Curlew (same cell and face numbering
/// as the Curlew mesh) and converts it to Curlew's conventions.
public enum FoamResults {
    public struct Loaded: Sendable {
        public var solution: ExternalSolution
        public var timeName: String
        public var fieldsRead: [String]
    }

    /// - Parameter time: directory name; nil = the latest time.
    public static func load(caseDirectory dir: URL, mesh m: Mesh, setup inSetup: CaseSetup, time: String? = nil) throws -> Loaded {
        guard let t = time.map({ ($0, Double($0) ?? 0) }) ?? FoamTimes.latest(dir) else {
            throw SolverError("\(dir.path) has no time directories")
        }
        var setup = inSetup
        setup.adopt(mesh: m)
        let app = FoamCaseWriter.resolvedApplication(setup)
        var (sol, read) = app.isMultiRegion
            ? try loadRegions(dir.appendingPathComponent(t.0), mesh: m, setup: setup, app: app)
            : try loadFields(dir.appendingPathComponent(t.0), mesh: m, setup: setup, app: app)
        sol.time = t.1
        if app.isTransient {
            let dt = setup.openfoam.deltaT ?? setup.run.timeStepSize
            sol.timeStep = Int((t.1 / max(dt, 1e-300)).rounded())
            sol.iteration = sol.timeStep
        } else {
            sol.iteration = Int(t.1.rounded())
            sol.time = 0
        }
        return Loaded(solution: sol, timeName: t.0, fieldsRead: read)
    }

    /// Multi-region (CHT) case: each region is read on its own sub-mesh and mapped back.
    static func loadRegions(_ tdir: URL, mesh m: Mesh, setup: CaseSetup, app: FoamApplication) throws -> (ExternalSolution, [String]) {
        let (regionOfZone, fluidNames, _) = try FoamCHTWriter.regionNames(m, setup)
        let regions = try MeshRegions.split(m, regionOfZone: regionOfZone)
        let n = m.nCells, nI = m.nInternalFaces, nB = m.nBoundaryFaces
        let T0 = setup.initialization.temperature.constantValue ?? 300
        var g = ExternalSolution(u: [Vec3](repeating: .zero, count: n), p: [Double](repeating: 0, count: n))
        var T = [Double](repeating: T0, count: n)
        var bT = [Double](repeating: T0, count: nB)
        var read: [String] = []
        for r in regions {
            let rnI = r.mesh.nInternalFaces
            let rdir = tdir.appendingPathComponent(r.name)
            /// region boundary face → global boundary face (nil for interfaces)
            func globalBF(_ rf: Int) -> Int? { let gf = Int(r.faceMap[rf]); return gf >= nI ? gf - nI : nil }
            if fluidNames.contains(r.name) {
                var rs = setup
                rs.adopt(mesh: r.mesh)
                let (sol, names) = try loadFields(rdir, mesh: r.mesh, setup: rs, app: app)
                read += names.map { "\(r.name)/\($0)" }
                func cells<T>(_ a: [T]?, into out: inout [T]) { if let a { for (i, c) in r.cellMap.enumerated() { out[Int(c)] = a[i] } } }
                func bnd<T>(_ a: [T]?, into out: inout [T]) {
                    guard let a else { return }
                    for rf in rnI..<r.mesh.nFaces { if let bf = globalBF(rf) { out[bf] = a[rf - rnI] } }
                }
                cells(sol.u, into: &g.u); cells(sol.p, into: &g.p); cells(sol.T, into: &T); bnd(sol.bT, into: &bT)
                let zero = [Double](repeating: 0, count: n)
                if sol.k != nil { var a = g.k ?? zero; cells(sol.k, into: &a); g.k = a }
                if sol.omega != nil { var a = g.omega ?? zero; cells(sol.omega, into: &a); g.omega = a }
                if sol.epsilon != nil { var a = g.epsilon ?? zero; cells(sol.epsilon, into: &a); g.epsilon = a }
                if sol.nuTilda != nil { var a = g.nuTilda ?? zero; cells(sol.nuTilda, into: &a); g.nuTilda = a }
                if sol.muT != nil { var a = g.muT ?? zero; cells(sol.muT, into: &a); g.muT = a }
                if sol.bU != nil { var a = g.bU ?? [Vec3](repeating: .zero, count: nB); bnd(sol.bU, into: &a); g.bU = a }
                if sol.bP != nil { var a = g.bP ?? [Double](repeating: 0, count: nB); bnd(sol.bP, into: &a); g.bP = a }
                if let ws = sol.bWallShear { var a = g.bWallShear ?? [Vec3](repeating: .zero, count: nB); bnd(ws, into: &a); g.bWallShear = a }
                if let yp = sol.bYPlus { var a = g.bYPlus ?? [Double](repeating: 0, count: nB); bnd(yp, into: &a); g.bYPlus = a }
                if let mf = sol.massFlux {
                    var a = g.massFlux ?? [Double](repeating: 0, count: m.nFaces)
                    for rf in 0..<r.mesh.nFaces where rf < rnI || globalBF(rf) != nil { a[Int(r.faceMap[rf])] = mf[rf] }
                    g.massFlux = a
                }
            } else {
                guard let f = try? FoamFieldReader.read(url: rdir.appendingPathComponent("T")),
                      let v = f.internalField?.scalars(count: r.mesh.nCells) else { continue }
                read.append("\(r.name)/T")
                for (i, c) in r.cellMap.enumerated() { T[Int(c)] = v[i] }
                for z in r.mesh.boundaryZones {
                    guard let pv = f.patchValues[MeshWriters.foamName(z.name)]?.scalars(count: z.count) else { continue }
                    for i in 0..<z.count { if let bf = globalBF(z.start + i) { bT[bf] = pv[i] } }
                }
            }
        }
        g.T = T
        g.bT = bT
        return (g, read)
    }

    /// Fields of one (single-region or fluid-region) time directory on `m`.
    static func loadFields(_ tdir: URL, mesh m: Mesh, setup: CaseSetup, app: FoamApplication) throws -> (ExternalSolution, [String]) {
        let t = (tdir.lastPathComponent, 0.0)
        let thermal = app.isThermal
        let mat = FoamCaseWriter.fluidMaterial(setup) ?? Material(name: "air")
        let pop = setup.general.operatingPressure
        let n = m.nCells, nI = m.nInternalFaces, nB = m.nBoundaryFaces
        var read: [String] = []

        func file(_ name: String) -> FoamFieldFile? {
            guard let f = try? FoamFieldReader.read(url: tdir.appendingPathComponent(name)) else { return nil }
            read.append(name)
            return f
        }
        /// Boundary values per Curlew boundary face, from each patch's `value` (nil = not written).
        func boundaryScalars(_ f: FoamFieldFile?, fallback: [Double]) -> [Double]? {
            guard let f else { return nil }
            var out = [Double](repeating: 0, count: nB)
            var any = false
            for z in m.boundaryZones {
                let first = z.start - nI
                let vals = f.patchValues[MeshWriters.foamName(z.name)]?.scalars(count: z.count)
                for i in 0..<z.count { out[first + i] = vals?[i] ?? fallback[Int(m.owner[z.start + i])] }
                any = any || vals != nil
            }
            return any ? out : nil
        }
        func boundaryVectors(_ f: FoamFieldFile?, fallback: [Vec3]?) -> [Vec3]? {
            guard let f else { return nil }
            var out = [Vec3](repeating: .zero, count: nB)
            var any = false
            for z in m.boundaryZones {
                let first = z.start - nI
                let vals = f.patchValues[MeshWriters.foamName(z.name)]?.vectors(count: z.count)
                for i in 0..<z.count { out[first + i] = vals?[i] ?? fallback?[Int(m.owner[z.start + i])] ?? .zero }
                any = any || vals != nil
            }
            return any ? out : nil
        }

        guard let uf = file("U"), let u = uf.internalField?.vectors(count: n) else {
            throw SolverError("\(t.0)/U is missing or does not match the mesh (\(n) cells)")
        }
        guard let pf = file("p"), let praw = pf.internalField?.scalars(count: n) else {
            throw SolverError("\(t.0)/p is missing or does not match the mesh")
        }
        let T = file("T")?.internalField?.scalars(count: n)
        // Density per cell: written rho if any, else from the material.
        let rho: [Double] = file("rho")?.internalField?.scalars(count: n) ?? (0..<n).map { c in
            switch mat.densityMethod {
            case .idealGas: return (thermal ? praw[c] : pop) / (mat.gasConstant * max(T?[c] ?? 300, 1))
            case .incompressibleIdealGas: return pop / (mat.gasConstant * max(T?[c] ?? 300, 1))
            default: return mat.density
            }
        }
        func toGauge(_ v: Double, _ c: Int) -> Double { thermal ? v - pop : v * rho[c] }
        let p = (0..<n).map { toGauge(praw[$0], $0) }
        var sol = ExternalSolution(u: u, p: p)
        sol.T = T
        sol.bU = boundaryVectors(uf, fallback: u)
        if let bp = boundaryScalars(pf, fallback: praw) {
            var out = bp
            for z in m.boundaryZones {
                for f in z.faceRange { let bf = f - nI; out[bf] = toGauge(bp[bf], Int(m.owner[f])) }
            }
            sol.bP = out
        }
        if let Tf = file("T"), let T { sol.bT = boundaryScalars(Tf, fallback: T) }
        if let f = file("k"), let v = f.internalField?.scalars(count: n) { sol.k = v; sol.bK = boundaryScalars(f, fallback: v) }
        if let f = file("omega"), let v = f.internalField?.scalars(count: n) { sol.omega = v; sol.bOmega = boundaryScalars(f, fallback: v) }
        if let f = file("epsilon"), let v = f.internalField?.scalars(count: n) { sol.epsilon = v; sol.bEpsilon = boundaryScalars(f, fallback: v) }
        if let f = file("nuTilda"), let v = f.internalField?.scalars(count: n) { sol.nuTilda = v; sol.bNuTilda = boundaryScalars(f, fallback: v) }
        if let v = file("nut")?.internalField?.scalars(count: n) { sol.muT = (0..<n).map { v[$0] * rho[$0] } }
        for sc in setup.models.passiveScalars {
            let name = MeshWriters.foamName(sc.name)
            if let f = file(name), let v = f.internalField?.scalars(count: n) {
                sol.scalars[sc.name] = v
                sol.bScalars[sc.name] = boundaryScalars(f, fallback: v)
            }
        }
        // Face fluxes: phi is volumetric for incompressible applications.
        if let f = file("phi"), let inner = f.internalField?.scalars(count: nI) {
            var mf = [Double](repeating: 0, count: m.nFaces)
            var complete = true
            for i in 0..<nI {
                let P = Int(m.owner[i]), N = Int(m.neighbour[i])
                mf[i] = thermal ? inner[i] : inner[i] * 0.5 * (rho[P] + rho[N])
            }
            for z in m.boundaryZones {
                if z.kind == .empty { continue }
                guard let vals = f.patchValues[MeshWriters.foamName(z.name)]?.scalars(count: z.count) else { complete = false; continue }
                for i in 0..<z.count { let face = z.start + i; mf[face] = thermal ? vals[i] : vals[i] * rho[Int(m.owner[face])] }
            }
            if complete { sol.massFlux = mf }
        }
        // Wall shear: OpenFOAM reports the stress on the fluid (kinematic for incompressible);
        // Curlew stores the force per area the fluid exerts on the wall, in Pa.
        if let f = file("wallShearStress"), var ws = boundaryVectors(f, fallback: nil) {
            for z in m.boundaryZones where z.kind == .wall {
                for face in z.faceRange { let bf = face - nI; ws[bf] = -(thermal ? 1 : rho[Int(m.owner[face])]) * ws[bf] }
            }
            sol.bWallShear = ws
        }
        if let f = file("yPlus") { sol.bYPlus = boundaryScalars(f, fallback: [Double](repeating: 0, count: n)) }

        _ = t
        return (sol, read)
    }
}
