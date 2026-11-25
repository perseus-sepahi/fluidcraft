import Foundation
import CurlewMesh

public struct SolverError: Error, LocalizedError, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A flow solution on a Curlew mesh: fields computed by OpenFOAM (or initial fields written
/// for it), with everything post-processing derives from them — material properties,
/// gradients, boundary values and wall quantities. Contours, vectors, pathlines, reports,
/// XY plots, exports and the PINN module all read from this object.
public final class Solution: @unchecked Sendable {
    public let mesh: Mesh
    public let geo: FVGeometry
    public private(set) var setup: CaseSetup
    public let state: FlowState
    public private(set) var bc: BoundaryData
    public private(set) var exprs: [String: Expr]

    public let isSolidCell: [Bool]
    public private(set) var zoneMaterial: [Material]

    /// Cell gradients of pressure and of the three velocity components (least squares).
    public private(set) var gradP: [Vec3]
    public private(set) var gradU: [[Vec3]] = [[], [], []]

    public internal(set) var residuals = ResidualHistory()
    public internal(set) var reportHistory = ReportHistory()
    public var log: (String) -> Void = { _ in }
    var _locator: CellLocator? = nil

    public var iteration: Int { state.iteration }
    public var isTransient: Bool { setup.general.time == .transient }
    public var isDensityBased: Bool { setup.general.solver == .densityBased }

    public init(mesh: Mesh, setup inSetup: CaseSetup) throws {
        var s = inSetup
        s.adopt(mesh: mesh)
        self.mesh = mesh
        self.setup = s
        geo = FVGeometry(mesh: mesh)
        state = FlowState(nCells: mesh.nCells, nBoundary: mesh.nBoundaryFaces, nFaces: mesh.nFaces)
        exprs = try Expr.compileNamed(s.expressions.map { ($0.name, $0.definition) })
        bc = try BoundaryData(mesh: mesh, setup: s, exprs: exprs, time: 0)
        zoneMaterial = try Solution.materials(mesh, s)
        var solid = [Bool](repeating: false, count: mesh.nCells)
        for c in 0..<mesh.nCells { solid[c] = (s.cellZones[mesh.cellZones[Int(mesh.cellZone[c])].name]?.kind ?? .fluid) == .solid }
        isSolidCell = solid
        gradP = [Vec3](repeating: .zero, count: mesh.nCells)
        state.scalars = s.models.passiveScalars.map { _ in [Double](repeating: 0, count: mesh.nCells) }
        state.bScalars = s.models.passiveScalars.map { _ in [Double](repeating: 0, count: mesh.nBoundaryFaces) }
        updateProperties()
    }

    static func materials(_ mesh: Mesh, _ s: CaseSetup) throws -> [Material] {
        try mesh.cellZones.map { z in
            let cs = s.cellZones[z.name] ?? CellZoneSettings()
            guard let mat = s.material(named: cs.material) else { throw SolverError("cell zone '\(z.name)' uses unknown material '\(cs.material)'") }
            return mat
        }
    }

    /// Replace settings that do not change the field layout (reference values, reports,
    /// materials, boundary values); scalar fields are kept by name.
    public func updateSetup(_ s: CaseSetup) throws {
        var s2 = s
        s2.adopt(mesh: mesh)
        let oldNames = setup.models.passiveScalars.map(\.name)
        setup = s2
        exprs = try Expr.compileNamed(s2.expressions.map { ($0.name, $0.definition) })
        bc = try BoundaryData(mesh: mesh, setup: s2, exprs: exprs, time: state.time)
        zoneMaterial = try Solution.materials(mesh, s2)
        let newNames = s2.models.passiveScalars.map(\.name)
        if oldNames != newNames || state.scalars.count != newNames.count {
            var cells: [[Double]] = [], bnd: [[Double]] = []
            for n in newNames {
                if let j = oldNames.firstIndex(of: n), j < state.scalars.count, j < state.bScalars.count {
                    cells.append(state.scalars[j]); bnd.append(state.bScalars[j])
                } else {
                    cells.append([Double](repeating: 0, count: mesh.nCells))
                    bnd.append([Double](repeating: 0, count: mesh.nBoundaryFaces))
                }
            }
            state.scalars = cells; state.bScalars = bnd
        }
        updateProperties()
    }

    public func restoreHistory(residuals r: ResidualHistory, reports: ReportHistory) {
        residuals = r
        reportHistory = reports
    }

    // MARK: Properties

    /// Density, viscosity, heat capacity and conductivity from the zone materials and the
    /// current temperature/pressure (a density OpenFOAM wrote is kept when `keepDensity`).
    func updateProperties(keepDensity: Bool = false) {
        let pop = setup.general.operatingPressure
        for c in 0..<mesh.nCells {
            let mat = zoneMaterial[Int(mesh.cellZone[c])]
            if !keepDensity {
                switch mat.densityMethod {
                case .constant, .boussinesq: state.rho[c] = mat.density
                case .incompressibleIdealGas: state.rho[c] = pop / (mat.gasConstant * max(state.T[c], 1))
                case .idealGas: state.rho[c] = (pop + state.p[c]) / (mat.gasConstant * max(state.T[c], 1))
                }
            }
            switch mat.viscosityMethod {
            case .constant, .powerLaw: state.mu[c] = mat.viscosity
            case .sutherland:
                let T = max(state.T[c], 1)
                state.mu[c] = mat.viscosity * pow(T / mat.sutherlandT0, 1.5) * (mat.sutherlandT0 + mat.sutherlandS) / (T + mat.sutherlandS)
            }
            state.cp[c] = mat.specificHeat
            state.conductivity[c] = mat.thermalConductivity
        }
        if zoneMaterial.contains(where: { $0.viscosityMethod == .powerLaw }) && gradU[0].count == mesh.nCells {
            for c in 0..<mesh.nCells {
                let mat = zoneMaterial[Int(mesh.cellZone[c])]
                guard mat.viscosityMethod == .powerLaw else { continue }
                state.mu[c] = min(max(mat.powerLawK * pow(max(strainRateMagnitude(c), 1e-12), mat.powerLawN - 1), mat.powerLawMin), mat.powerLawMax)
            }
        }
    }

    /// sqrt(2 S_ij S_ij)
    @inline(__always) public func strainRateMagnitude(_ c: Int) -> Double {
        guard gradU[0].count == mesh.nCells else { return 0 }
        let gx = gradU[0][c], gy = gradU[1][c], gz = gradU[2][c]
        let sxx = gx.x, syy = gy.y, szz = gz.z
        let sxy = 0.5 * (gx.y + gy.x), sxz = 0.5 * (gx.z + gz.x), syz = 0.5 * (gy.z + gz.y)
        return sqrt(2 * (sxx * sxx + syy * syy + szz * szz + 2 * (sxy * sxy + sxz * sxz + syz * syz)))
    }

    var fluidMaterial: Material { zoneMaterial.first { $0.kind == .fluid } ?? Material(name: "air") }
    public var gasGamma: Double {
        let m = fluidMaterial
        return m.specificHeat / max(m.specificHeat - m.gasConstant, 1e-12)
    }
    public var gasR: Double { fluidMaterial.gasConstant }

    // MARK: Gradients

    public func computeGradients() {
        Gradient.compute(geo, state.p, boundary: state.bP, scheme: .leastSquares, into: &gradP)
        var scratch: [Double] = [], scratchB: [Double] = []
        Gradient.compute(geo, state.u, boundary: state.bU, scheme: .leastSquares, into: &gradU, scratch: &scratch, scratchB: &scratchB)
    }

    // MARK: Loading fields

    /// Boundary values implied by the cell values and the boundary conditions, used where a
    /// field file carries no patch values (and for initial fields).
    func fillBoundaryValues() {
        let nI = mesh.nInternalFaces
        let st = state
        for bf in 0..<mesh.nBoundaryFaces {
            let P = Int(mesh.owner[bf + nI])
            switch bc.kind[bf] {
            case .wall: st.bU[bf] = bc.uSpec[bf]
            case .velocityInlet, .farField: st.bU[bf] = bc.uSpec[bf]
            case .symmetry, .slipWall:
                let n = normalized(mesh.faceAreas[bf + nI])
                st.bU[bf] = st.u[P] - dot(st.u[P], n) * n
            default: st.bU[bf] = st.u[P]
            }
            switch bc.kind[bf] {
            case .pressureOutlet, .pressureInlet, .farField: st.bP[bf] = bc.pSpec[bf]
            default: st.bP[bf] = st.p[P]
            }
            st.bT[bf] = bc.thermal.kind[bf] == .fixedValue ? bc.thermal.value[bf] : st.T[P]
            st.bK[bf] = bc.k.kind[bf] == .fixedValue ? bc.k.value[bf] : st.k[P]
            st.bOmega[bf] = bc.omega.kind[bf] == .fixedValue ? bc.omega.value[bf] : st.omega[P]
            st.bEpsilon[bf] = bc.epsilon.kind[bf] == .fixedValue ? bc.epsilon.value[bf] : st.epsilon[P]
            st.bNuTilda[bf] = bc.nuTilda.kind[bf] == .fixedValue ? bc.nuTilda.value[bf] : st.nuTilda[P]
            for si in 0..<st.scalars.count where si < bc.scalars.count {
                st.bScalars[si][bf] = bc.scalars[si].kind[bf] == .fixedValue ? bc.scalars[si].value[bf] : st.scalars[si][P]
            }
        }
    }

    /// Face mass fluxes by linear interpolation of ρu (when the solver wrote none).
    func interpolateMassFluxes() {
        let st = state, nI = mesh.nInternalFaces
        for f in 0..<nI {
            let P = Int(mesh.owner[f]), N = Int(mesh.neighbour[f])
            if isSolidCell[P] || isSolidCell[N] { st.massFlux[f] = 0; continue }
            let w = geo.weight[f]
            st.massFlux[f] = (w * st.rho[P] + (1 - w) * st.rho[N]) * dot(w * st.u[P] + (1 - w) * st.u[N], mesh.faceAreas[f])
        }
        for f in nI..<mesh.nFaces {
            let bf = f - nI, P = Int(mesh.owner[f])
            switch bc.kind[bf] {
            case .empty, .wall, .slipWall, .symmetry: st.massFlux[f] = 0
            default: st.massFlux[f] = isSolidCell[P] ? 0 : st.rho[P] * dot(st.bU[bf], mesh.faceAreas[f])
            }
        }
    }

    /// Wall shear (force per area the fluid exerts on the wall), y+ and wall heat flux from the
    /// near-wall cells, used when OpenFOAM did not write them (laminar estimate).
    func estimateWallQuantities(shear: Bool, yPlus: Bool, heatFlux: Bool) {
        let st = state, nI = mesh.nInternalFaces
        for bf in 0..<mesh.nBoundaryFaces where bc.kind[bf] == .wall || bc.kind[bf] == .slipWall {
            let f = bf + nI, P = Int(mesh.owner[f])
            let dn = geo.normalDistance(f)
            if shear || yPlus {
                let n = normalized(mesh.faceAreas[f])
                var du = st.u[P] - st.bU[bf]
                du -= dot(du, n) * n
                let tau = bc.kind[bf] == .slipWall ? Vec3.zero : (st.mu[P] + st.muT[P]) * du / dn
                if shear { st.bWallShear[bf] = tau }
                if yPlus {
                    let ut = sqrt(norm(tau) / max(st.rho[P], 1e-300))
                    st.bYPlus[bf] = st.rho[P] * ut * dn / max(st.mu[P], 1e-300)
                }
            }
            if heatFlux {
                // conduction with the turbulent conductivity of the wall cell (Pr_t = 0.85)
                let ke = st.conductivity[P] + st.cp[P] * st.muT[P] / 0.85
                st.bHeatFlux[bf] = ke * (st.bT[bf] - st.T[P]) / dn
            }
        }
    }

    /// Replace the solution with fields computed by OpenFOAM on this mesh, then rebuild what
    /// Curlew derives from them (properties, gradients, wall quantities).
    public func load(external e: ExternalSolution) throws {
        let n = mesh.nCells, nB = mesh.nBoundaryFaces, nF = mesh.nFaces
        func check(_ a: Int, _ want: Int, _ what: String) throws {
            guard a == want else { throw SolverError("\(what): \(a) values for \(want) \(what.hasPrefix("b") ? "boundary faces" : "cells")") }
        }
        try check(e.u.count, n, "U"); try check(e.p.count, n, "p")
        let st = state
        st.u = e.u
        st.p = e.p
        if let v = e.T { try check(v.count, n, "T"); st.T = v }
        if let v = e.k { try check(v.count, n, "k"); st.k = v }
        if let v = e.omega { try check(v.count, n, "omega"); st.omega = v }
        if let v = e.epsilon { try check(v.count, n, "epsilon"); st.epsilon = v }
        if let v = e.nuTilda { try check(v.count, n, "nuTilda"); st.nuTilda = v }
        st.muT = e.muT ?? [Double](repeating: 0, count: n)
        if st.muT.count != n { throw SolverError("nut: \(st.muT.count) values for \(n) cells") }
        for (i, sc) in setup.models.passiveScalars.enumerated() where i < st.scalars.count {
            if let v = e.scalars[sc.name], v.count == n { st.scalars[i] = v }
        }
        if let rho = e.rho, rho.count == n { st.rho = rho; updateProperties(keepDensity: true) } else { updateProperties() }
        fillBoundaryValues()
        if let v = e.bU, v.count == nB { st.bU = v }
        if let v = e.bP, v.count == nB { st.bP = v }
        if let v = e.bT, v.count == nB { st.bT = v }
        if let v = e.bK, v.count == nB { st.bK = v }
        if let v = e.bOmega, v.count == nB { st.bOmega = v }
        if let v = e.bEpsilon, v.count == nB { st.bEpsilon = v }
        if let v = e.bNuTilda, v.count == nB { st.bNuTilda = v }
        for (i, sc) in setup.models.passiveScalars.enumerated() where i < st.bScalars.count {
            if let v = e.bScalars[sc.name], v.count == nB { st.bScalars[i] = v }
        }
        if let mf = e.massFlux, mf.count == nF { st.massFlux = mf } else { interpolateMassFluxes() }
        computeGradients()
        if zoneMaterial.contains(where: { $0.viscosityMethod == .powerLaw }) { updateProperties(keepDensity: e.rho != nil) }
        st.bWallShear = [Vec3](repeating: .zero, count: nB)
        st.bYPlus = [Double](repeating: 0, count: nB)
        st.bHeatFlux = [Double](repeating: 0, count: nB)
        let shear = e.bWallShear?.count == nB, yp = e.bYPlus?.count == nB, hf = e.bHeatFlux?.count == nB
        estimateWallQuantities(shear: !shear, yPlus: !yp, heatFlux: !hf && e.T != nil)
        let nI = mesh.nInternalFaces
        for bf in 0..<nB where bc.kind[bf] == .wall || bc.kind[bf] == .slipWall {
            if shear { st.bWallShear[bf] = e.bWallShear![bf] }
            if yp { st.bYPlus[bf] = e.bYPlus![bf] }
            if hf { st.bHeatFlux[bf] = e.bHeatFlux![bf] }
        }
        _ = nI
        st.time = e.time
        st.iteration = e.iteration
        st.timeStep = e.timeStep
        st.isInitialization = false
    }

    /// Initial fields (Curlew's standard initialization) as a solution, for display and for
    /// writing nonuniform `0/` fields.
    public func loadInitialFields() {
        InitialFields.fill(self)
        updateProperties()
        fillBoundaryValues()
        interpolateMassFluxes()
        computeGradients()
        let nB = mesh.nBoundaryFaces
        state.bWallShear = [Vec3](repeating: .zero, count: nB)
        state.bYPlus = [Double](repeating: 0, count: nB)
        state.bHeatFlux = [Double](repeating: 0, count: nB)
        state.iteration = 0; state.time = 0; state.timeStep = 0
        state.isInitialization = true
        residuals = ResidualHistory(); reportHistory = ReportHistory()
    }

    /// Recompute derived quantities after reading archived data.
    public func afterRestore() {
        updateProperties(keepDensity: true)
        computeGradients()
    }

    public func formatResiduals(_ r: [String: Double]) -> String {
        var s = String(format: "%6d ", state.iteration)
        for name in residuals.names { if let v = r[name] { s += String(format: " %@ %.4e", name, v) } }
        return s
    }
}
