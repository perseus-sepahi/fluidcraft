import Foundation
import CurlewMesh
import CurlewLinear

public struct SolverError: Error, LocalizedError, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Wall face seen from the fluid: boundary walls and fluid/solid interfaces.
public struct WallFace: Sendable {
    public var face: Int
    public var cell: Int
    /// +1 if `cell` is the face owner (area vector points out of the fluid), else -1.
    public var sign: Double
    public var isInterface: Bool
}

/// Pressure-based segregated finite-volume solver (SIMPLE / SIMPLEC / PISO).
public final class PressureBasedSolver: @unchecked Sendable {
    public let mesh: Mesh
    public let geo: FVGeometry
    public private(set) var setup: CaseSetup
    public let state: FlowState
    public private(set) var bc: BoundaryData
    var exprs: [String: Expr]

    // Matrices and linear solvers
    let A: SparseMatrix
    let Ap: SparseMatrix
    let momSolver: LinearSolver
    let pSolver: LinearSolver
    let turbSolver: LinearSolver
    let energySolver: LinearSolver
    let scalarSolver: LinearSolver

    // Zone data
    public let isSolidCell: [Bool]
    /// Internal faces between fluid and solid cells.
    public let isInterfaceFace: [Bool]
    public let walls: [WallFace]
    /// Index into `walls` for each boundary face (-1 if not a wall).
    let wallIndexOfBoundary: [Int32]
    /// Index into `walls` for each internal interface face (-1 otherwise).
    var wallIndexOfFace: [Int32]
    let zoneMaterial: [Material]
    let zoneSettings: [CellZoneSettings]
    let hasSolids: Bool
    let refCell: Int

    // Work arrays
    public internal(set) var gradP: [Vec3]
    public internal(set) var gradU: [[Vec3]] = [[], [], []]
    var gradT: [Vec3] = []
    var aP: [Double]
    var Dcell: [Double]
    var pCorr: [Double]
    var gradPc: [Vec3] = []
    var bx: [Double], by: [Double], bz: [Double]
    var scratch: [Double] = [], scratchB: [Double] = []
    var uPrev: [Vec3] = []
    var massFluxPrev: [Double] = []
    /// Wall shear viscosity per wall face (laminar or wall-function value).
    public internal(set) var muWall: [Double]
    public internal(set) var yPlusWall: [Double]

    public internal(set) var residuals = ResidualHistory()
    public internal(set) var reportHistory = ReportHistory()
    public var log: (String) -> Void = { print($0) }
    public var stopRequested = false
    var _locator: CellLocator? = nil

    public var iteration: Int { state.iteration }
    public var isTransient: Bool { setup.general.time == .transient }

    public init(mesh: Mesh, setup inSetup: CaseSetup) throws {
        var s = inSetup
        s.adopt(mesh: mesh)
        self.mesh = mesh
        self.setup = s
        geo = FVGeometry(mesh: mesh)
        state = FlowState(nCells: mesh.nCells, nBoundary: mesh.nBoundaryFaces, nFaces: mesh.nFaces)
        exprs = try Expr.compileNamed(s.expressions.map { ($0.name, $0.definition) })
        bc = try BoundaryData(mesh: mesh, setup: s, exprs: exprs, time: 0)

        A = SparseMatrix(pattern: geo.pattern)
        Ap = SparseMatrix(pattern: geo.pattern)
        momSolver = LinearSolver(s.controls.linear.momentum)
        pSolver = LinearSolver(s.controls.linear.pressure)
        turbSolver = LinearSolver(s.controls.linear.turbulence)
        energySolver = LinearSolver(s.controls.linear.energy)
        scalarSolver = LinearSolver(s.controls.linear.scalars)

        // Zones
        var mats: [Material] = []
        var zs: [CellZoneSettings] = []
        for z in mesh.cellZones {
            let cs = s.cellZones[z.name] ?? CellZoneSettings()
            zs.append(cs)
            guard let mat = s.material(named: cs.material) else { throw SolverError("cell zone '\(z.name)' uses unknown material '\(cs.material)'") }
            mats.append(mat)
        }
        zoneMaterial = mats
        zoneSettings = zs
        var solid = [Bool](repeating: false, count: mesh.nCells)
        for c in 0..<mesh.nCells { solid[c] = zs[Int(mesh.cellZone[c])].kind == .solid }
        isSolidCell = solid
        hasSolids = solid.contains(true)
        var iface = [Bool](repeating: false, count: mesh.nInternalFaces)
        var wl: [WallFace] = []
        var wib = [Int32](repeating: -1, count: mesh.nBoundaryFaces)
        var wif = [Int32](repeating: -1, count: mesh.nInternalFaces)
        for f in 0..<mesh.nInternalFaces {
            let P = Int(mesh.owner[f]), N = Int(mesh.neighbour[f])
            if solid[P] != solid[N] {
                iface[f] = true
                wif[f] = Int32(wl.count)
                wl.append(WallFace(face: f, cell: solid[P] ? N : P, sign: solid[P] ? -1 : 1, isInterface: true))
            }
        }
        for f in mesh.nInternalFaces..<mesh.nFaces where bc.kind[f - mesh.nInternalFaces] == .wall {
            let P = Int(mesh.owner[f])
            if solid[P] { continue }
            wib[f - mesh.nInternalFaces] = Int32(wl.count)
            wl.append(WallFace(face: f, cell: P, sign: 1, isInterface: false))
        }
        isInterfaceFace = iface
        walls = wl
        wallIndexOfBoundary = wib
        wallIndexOfFace = wif
        muWall = [Double](repeating: 0, count: wl.count)
        yPlusWall = [Double](repeating: 0, count: wl.count)

        // Reference cell: nearest fluid cell to the reference location
        let rl = Vec3(s.general.referencePressureLocation[0], s.general.referencePressureLocation[1], s.general.referencePressureLocation[2])
        var best = 0, bd = Double.infinity
        for c in 0..<mesh.nCells where !solid[c] {
            let d = norm(mesh.cellCentres[c] - rl)
            if d < bd { bd = d; best = c }
        }
        refCell = best

        let n = mesh.nCells
        gradP = [Vec3](repeating: .zero, count: n)
        aP = [Double](repeating: 1, count: n)
        Dcell = [Double](repeating: 0, count: n)
        pCorr = [Double](repeating: 0, count: n)
        bx = [Double](repeating: 0, count: n); by = bx; bz = bx
        state.scalars = s.models.passiveScalars.map { _ in [Double](repeating: 0, count: n) }
        state.bScalars = s.models.passiveScalars.map { _ in [Double](repeating: 0, count: mesh.nBoundaryFaces) }

        if s.controls.linear.useGPU, let acc = GPUAccelerator.shared {
            pSolver.accelerator = acc
        }
        updateProperties()
        if setup.models.viscous.isTurbulent { try computeWallDistance() }
    }

    /// Replace settings that do not change the field layout (controls, methods, BC values...).
    public func updateSetup(_ s: CaseSetup) throws {
        var s2 = s
        s2.adopt(mesh: mesh)
        let turbChanged = s2.models.viscous != setup.models.viscous
        setup = s2
        exprs = try Expr.compileNamed(s2.expressions.map { ($0.name, $0.definition) })
        bc = try BoundaryData(mesh: mesh, setup: s2, exprs: exprs, time: state.time)
        momSolver.settings = s2.controls.linear.momentum
        pSolver.settings = s2.controls.linear.pressure
        turbSolver.settings = s2.controls.linear.turbulence
        energySolver.settings = s2.controls.linear.energy
        scalarSolver.settings = s2.controls.linear.scalars
        pSolver.accelerator = s2.controls.linear.useGPU ? GPUAccelerator.shared : nil
        if turbChanged && s2.models.viscous.isTurbulent && geo.wallDistance.isEmpty { try computeWallDistance() }
        if state.scalars.count != s2.models.passiveScalars.count {
            state.scalars = s2.models.passiveScalars.map { _ in [Double](repeating: 0, count: mesh.nCells) }
            state.bScalars = s2.models.passiveScalars.map { _ in [Double](repeating: 0, count: mesh.nBoundaryFaces) }
        }
        updateProperties()
    }

    // MARK: Properties

    func updateProperties() {
        let pop = setup.general.operatingPressure
        for c in 0..<mesh.nCells {
            let mat = zoneMaterial[Int(mesh.cellZone[c])]
            switch mat.densityMethod {
            case .constant, .boussinesq: state.rho[c] = mat.density
            case .incompressibleIdealGas: state.rho[c] = pop / (mat.gasConstant * max(state.T[c], 1))
            case .idealGas: state.rho[c] = (pop + state.p[c]) / (mat.gasConstant * max(state.T[c], 1))
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
        if zoneMaterial.contains(where: { $0.viscosityMethod == .powerLaw }) && !gradU[0].isEmpty {
            for c in 0..<mesh.nCells {
                let mat = zoneMaterial[Int(mesh.cellZone[c])]
                guard mat.viscosityMethod == .powerLaw else { continue }
                let gd = strainRateMagnitude(c)
                state.mu[c] = min(max(mat.powerLawK * pow(max(gd, 1e-12), mat.powerLawN - 1), mat.powerLawMin), mat.powerLawMax)
            }
        }
    }

    /// sqrt(2 S_ij S_ij)
    @inline(__always) func strainRateMagnitude(_ c: Int) -> Double {
        let gx = gradU[0][c], gy = gradU[1][c], gz = gradU[2][c]
        let sxx = gx.x, syy = gy.y, szz = gz.z
        let sxy = 0.5 * (gx.y + gy.x), sxz = 0.5 * (gx.z + gz.x), syz = 0.5 * (gy.z + gz.y)
        return sqrt(2 * (sxx * sxx + syy * syy + szz * szz + 2 * (sxy * sxy + sxz * sxz + syz * syz)))
    }

    @inline(__always) func operatingDensity() -> Double {
        if let d = setup.general.operatingDensity { return d }
        // Fluent default: for Boussinesq use rho0; otherwise the minimum density.
        if let m = zoneMaterial.first(where: { $0.kind == .fluid }) {
            if m.densityMethod == .boussinesq || m.densityMethod == .constant { return m.density }
        }
        var mn = Double.infinity
        for c in 0..<mesh.nCells where !isSolidCell[c] { mn = min(mn, state.rho[c]) }
        return mn.isFinite ? mn : 1
    }

    /// Buoyancy density difference (rho - rho_op) used in the body force.
    @inline(__always) func buoyancyDensity(_ c: Int, rhoOp: Double) -> Double {
        let mat = zoneMaterial[Int(mesh.cellZone[c])]
        if mat.densityMethod == .boussinesq {
            return -mat.density * mat.thermalExpansion * (state.T[c] - setup.general.operatingTemperature) + (mat.density - rhoOp)
        }
        return state.rho[c] - rhoOp
    }

    var gravity: Vec3 {
        guard setup.general.gravityEnabled else { return .zero }
        let g = setup.general.gravity
        return Vec3(g[0], g.count > 1 ? g[1] : 0, g.count > 2 ? g[2] : 0)
    }

    // MARK: Face helpers

    @inline(__always) func faceDensity(_ f: Int) -> Double {
        if f < geo.nInternal {
            let w = geo.weight[f]
            return w * state.rho[Int(mesh.owner[f])] + (1 - w) * state.rho[Int(mesh.neighbour[f])]
        }
        return state.rho[Int(mesh.owner[f])]
    }

    func effectiveViscosity() -> [Double] {
        var mu = state.mu
        if setup.models.viscous.isTurbulent { for c in 0..<mu.count { mu[c] += state.muT[c] } }
        if setup.models.viscous == .inviscid { for c in 0..<mu.count { mu[c] = 0 } }
        return mu
    }

    // MARK: Boundary values

    /// Update boundary face values of velocity and pressure from cell values.
    func updateFlowBoundaries() {
        let nI = geo.nInternal
        let second = setup.methods.pressure != .standard
        let g = gravity
        let bfw = setup.methods.pressure == .bodyForceWeighted && g != .zero
        let rhoOp = bfw ? operatingDensity() : 0
        for f in nI..<geo.nFaces {
            let bf = f - nI
            let P = Int(mesh.owner[f])
            let d = geo.delta[f]
            switch bc.kind[bf] {
            case .empty:
                state.bU[bf] = state.u[P]; state.bP[bf] = state.p[P]
            case .wall:
                state.bU[bf] = bc.uSpec[bf]
                state.bP[bf] = extrapolatedPressure(P, d, second: second, bfw: bfw, rhoOp: rhoOp, g: g)
            case .slipWall, .symmetry:
                let n = normalized(mesh.faceAreas[f])
                state.bU[bf] = state.u[P] - dot(state.u[P], n) * n
                state.bP[bf] = extrapolatedPressure(P, d, second: second, bfw: bfw, rhoOp: rhoOp, g: g)
            case .velocityInlet:
                state.bU[bf] = bc.uSpec[bf]
                state.bP[bf] = extrapolatedPressure(P, d, second: second, bfw: bfw, rhoOp: rhoOp, g: g)
            case .pressureOutlet:
                state.bU[bf] = state.u[P]
                state.bP[bf] = bc.pSpec[bf]
            case .pressureInlet:
                let n = normalized(mesh.faceAreas[f])
                let un = min(dot(state.u[P], n), 0)
                state.bU[bf] = un * n
                state.bP[bf] = bc.pSpec[bf] - 0.5 * state.rho[P] * un * un
            case .farField:
                let n = normalized(mesh.faceAreas[f])
                if dot(bc.uSpec[bf], n) < 0 { state.bU[bf] = bc.uSpec[bf] } else { state.bU[bf] = state.u[P] }
                state.bP[bf] = bc.pSpec[bf]
            case .outflow:
                state.bU[bf] = state.u[P]
                state.bP[bf] = extrapolatedPressure(P, d, second: second, bfw: bfw, rhoOp: rhoOp, g: g)
            }
        }
    }

    @inline(__always) func extrapolatedPressure(_ P: Int, _ d: Vec3, second: Bool, bfw: Bool, rhoOp: Double, g: Vec3) -> Double {
        if bfw { return state.p[P] + buoyancyDensity(P, rhoOp: rhoOp) * dot(g, d) }
        return second ? state.p[P] + dot(gradP[P], d) : state.p[P]
    }

    // MARK: Initialization

    public func initialize() throws {
        try Initialization.run(self)
    }

    // MARK: Gradients

    func computeGradients() {
        let scheme = setup.methods.gradient
        Gradient.compute(geo, state.p, boundary: state.bP, scheme: scheme, into: &gradP)
        Gradient.compute(geo, state.u, boundary: state.bU, scheme: scheme, into: &gradU, scratch: &scratch, scratchB: &scratchB)
    }

    // MARK: Momentum

    /// Assemble and solve momentum; returns scaled residuals for x, y, z.
    func solveMomentum(urf: Double) -> [Double] {
        let m = mesh, g = geo
        let nI = g.nInternal, nC = g.nCells
        let diag = g.pattern.diag
        let muEff = effectiveViscosity()
        let scheme = setup.methods.momentum
        let limitMom = setup.methods.limitMomentum
        let turbulent = setup.models.viscous.isTurbulent || zoneMaterial.contains { $0.viscosityMethod != .constant }
        let nonOrth = g.hasNonOrthogonality
        let grav = gravity
        let rhoOp = grav != .zero ? operatingDensity() : 0
        A.zero()
        for c in 0..<nC { bx[c] = 0; by[c] = 0; bz[c] = 0 }
        let flux = state.massFlux
        let u = state.u
        let gU = gradU

        A.values.withUnsafeMutableBufferPointer { V in
            // Interior faces
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                if isInterfaceFace[f] {
                    // wall seen from the fluid side
                    let wi = Int(wallIndexOfFace[f])
                    let fluid = isSolidCell[P] ? N : P
                    let dn = abs(dot(m.faceAreas[f], m.faceCentres[f] - m.cellCentres[fluid])) / max(m.faceAreaMag[f], 1e-300)
                    let dif = muWall[wi] * m.faceAreaMag[f] / max(dn, 1e-300)
                    V[Int(diag[fluid])] += dif
                    continue
                }
                if isSolidCell[P] { continue }
                let F = flux[f]
                let w = g.weight[f]
                let mu = w * muEff[P] + (1 - w) * muEff[N]
                let dif = mu * g.orthCoeff[f]
                let aPN = -(dif + max(-F, 0))
                let aNP = -(dif + max(F, 0))
                V[Int(g.upper[f])] += aPN; V[Int(diag[P])] -= aPN
                V[Int(g.lower[f])] += aNP; V[Int(diag[N])] -= aNP
                var corr = Vec3.zero
                if F != 0 && scheme != .firstOrderUpwind {
                    let cf = m.faceCentres[f]
                    let rP = cf - m.cellCentres[P], rN = cf - m.cellCentres[N]
                    let dd = g.delta[f]
                    for k in 0..<3 {
                        corr[k] = F * convectionCorrection(scheme, bounded: limitMom, F: F, phiP: u[P][k], phiN: u[N][k],
                                                           gradP: gU[k][P], gradN: gU[k][N], w: w, rP: rP, rN: rN, d: dd)
                    }
                }
                var expl = -corr
                if nonOrth {
                    let T = g.nonOrth[f]
                    for k in 0..<3 {
                        let gf = w * gU[k][P] + (1 - w) * gU[k][N]
                        expl[k] += mu * dot(gf, T)
                    }
                }
                if turbulent {
                    // div(mu (grad u)^T): sum_j (du_j/dx_i)_f S_j
                    let S = m.faceAreas[f]
                    var t = Vec3.zero
                    for j in 0..<3 {
                        let gj = w * gU[j][P] + (1 - w) * gU[j][N]
                        t += gj * S[j]
                    }
                    expl += mu * t
                }
                bx[P] += expl.x; by[P] += expl.y; bz[P] += expl.z
                bx[N] -= expl.x; by[N] -= expl.y; bz[N] -= expl.z
            }
            // Boundary faces
            for f in nI..<g.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                if isSolidCell[P] { continue }
                let F = flux[f]
                switch bc.kind[bf] {
                case .empty: continue
                case .wall:
                    let wi = Int(wallIndexOfBoundary[bf])
                    let muW = wi >= 0 ? muWall[wi] : muEff[P]
                    let dif = muW * g.orthCoeff[f]
                    V[Int(diag[P])] += dif
                    let uw = bc.uSpec[bf]
                    bx[P] += dif * uw.x; by[P] += dif * uw.y; bz[P] += dif * uw.z
                case .slipWall, .symmetry:
                    // normal stress -2 mu |S|/dn (u.n) n: implicit isotropic part + explicit tangential remainder
                    let n = normalized(m.faceAreas[f])
                    let c = 2 * muEff[P] * m.faceAreaMag[f] / g.normalDistance(f)
                    V[Int(diag[P])] += c
                    let ut = u[P] - dot(u[P], n) * n
                    bx[P] += c * ut.x; by[P] += c * ut.y; bz[P] += c * ut.z
                case .velocityInlet, .farField:
                    let ub = state.bU[bf]
                    let a = muEff[P] * g.orthCoeff[f] + max(-F, 0)
                    V[Int(diag[P])] += a
                    bx[P] += a * ub.x; by[P] += a * ub.y; bz[P] += a * ub.z
                case .pressureInlet:
                    // inflow carries the boundary velocity (normal to the boundary)
                    if F < 0 {
                        let ub = state.bU[bf]
                        V[Int(diag[P])] += -F
                        bx[P] += -F * ub.x; by[P] += -F * ub.y; bz[P] += -F * ub.z
                    }
                case .pressureOutlet, .outflow:
                    if F < 0 {
                        // backflow normal to the boundary
                        let n = normalized(m.faceAreas[f])
                        let ub = dot(u[P], n) * n
                        V[Int(diag[P])] += -F
                        bx[P] += -F * ub.x; by[P] += -F * ub.y; bz[P] += -F * ub.z
                    }
                }
            }
            // Cell sources: pressure gradient, buoyancy, porous media, MRF, transient
            let transient = isTransient
            let dt = setup.run.timeStepSize
            let second = setup.methods.transient == .secondOrderImplicit && state.timeStep > 1
            for c in 0..<nC {
                if isSolidCell[c] {
                    let R = g.pattern.rowPtr
                    for k in Int(R[c])..<Int(R[c + 1]) { V[k] = 0 }
                    V[Int(diag[c])] = 1
                    bx[c] = 0; by[c] = 0; bz[c] = 0
                    continue
                }
                let vol = m.cellVolumes[c]
                var src = -gradP[c] * vol
                if grav != .zero { src += buoyancyDensity(c, rhoOp: rhoOp) * grav * vol }
                let zs = zoneSettings[Int(m.cellZone[c])]
                if let por = zs.porous {
                    let speed = norm(u[c])
                    let ci = Vec3(state.mu[c] * por.viscousResistance[0] + 0.5 * state.rho[c] * por.inertialResistance[0] * speed,
                                  state.mu[c] * por.viscousResistance[1] + 0.5 * state.rho[c] * por.inertialResistance[1] * speed,
                                  state.mu[c] * por.viscousResistance[2] + 0.5 * state.rho[c] * por.inertialResistance[2] * speed) * vol
                    let cav = (ci.x + ci.y + ci.z) / 3
                    V[Int(diag[c])] += cav
                    src -= (ci - Vec3(repeating: cav)) * u[c]
                }
                if zs.frameMotion {
                    let a = normalized(Vec3(zs.rotationAxisDirection[0], zs.rotationAxisDirection[1], zs.rotationAxisDirection[2]))
                    // absolute-velocity formulation: -rho (Omega x u)
                    src -= state.rho[c] * cross(zs.rotationSpeed * a, u[c]) * vol
                }
                if zs.momentumSource.contains(where: { $0 != .constant(0) }) {
                    let cc = m.cellCentres[c]
                    for k in 0..<3 {
                        let q = zs.momentumSource[k]
                        let v: Double
                        switch q { case .constant(let d): v = d
                        case .expression(let s): v = (try? Expr(s, named: exprs).value(x: cc.x, y: cc.y, z: cc.z, t: state.time)) ?? 0 }
                        src[k] += v * vol
                    }
                }
                if transient {
                    let rv = state.rho[c] * vol / dt
                    if second {
                        V[Int(diag[c])] += 1.5 * rv
                        src += rv * (2 * state.uOld[c] - 0.5 * state.uOldOld[c])
                    } else {
                        V[Int(diag[c])] += rv
                        src += rv * state.uOld[c]
                    }
                }
                bx[c] += src.x; by[c] += src.y; bz[c] += src.z
            }
        }

        // Residuals (unrelaxed), Fluent scaling
        var r = [Double](repeating: 0, count: nC)
        var res = [Double](repeating: 0, count: 3)
        let comps = mesh.isTwoDimensional ? 2 : 3
        var xs: [[Double]] = (0..<3).map { k in u.map { $0[k] } }
        let bs = [bx, by, bz]
        for k in 0..<3 where !(mesh.isTwoDimensional && k == mesh.twoDimensionalAxis!) {
            let raw = A.residual(x: xs[k], b: bs[k], into: &r)
            let nrm = A.diagonalNorm(x: xs[k])
            res[k] = nrm > 1e-300 ? raw / nrm : raw
        }
        _ = comps

        // Under-relaxation (shared matrix)
        var bsR = bs
        A.values.withUnsafeMutableBufferPointer { V in
            for c in 0..<nC {
                let kd = Int(diag[c])
                if isSolidCell[c] { aP[c] = 1; continue }
                let d = V[kd]
                V[kd] = d / urf
                let extra = (1 - urf) / urf * d
                bsR[0][c] += extra * u[c].x; bsR[1][c] += extra * u[c].y; bsR[2][c] += extra * u[c].z
                aP[c] = V[kd]
            }
        }
        // Solve components
        for k in 0..<3 {
            if let ax = mesh.twoDimensionalAxis, ax == k { for c in 0..<nC { xs[k][c] = 0 }; continue }
            momSolver.solve(A, x: &xs[k], b: bsR[k])
        }
        for c in 0..<nC { state.u[c] = Vec3(xs[0][c], xs[1][c], xs[2][c]) }

        // Pressure-correction coefficient D = V / a_P (SIMPLE) or V / (a_P - sum|a_nb|) (SIMPLEC)
        let simplec = setup.methods.coupling == .simplec
        A.values.withUnsafeBufferPointer { V in
            let R = g.pattern.rowPtr
            for c in 0..<nC {
                if isSolidCell[c] { Dcell[c] = 0; continue }
                var a = aP[c]
                if simplec {
                    var off = 0.0
                    for k in Int(R[c])..<Int(R[c + 1]) where k != Int(diag[c]) { off += V[k] }
                    a = max(a + off, 0.05 * a)
                }
                Dcell[c] = m.cellVolumes[c] / a
            }
        }
        return res
    }

    // MARK: Mass fluxes

    /// Rhie-Chow face fluxes from the momentum-predicted velocity.
    func computeMassFluxes(urf: Double) {
        let m = mesh, g = geo
        let nI = g.nInternal
        let transient = isTransient
        let dt = setup.run.timeStepSize
        let second = setup.methods.transient == .secondOrderImplicit && state.timeStep > 1
        let haveOld = !massFluxPrev.isEmpty && !uPrev.isEmpty
        var flux = state.massFlux
        for f in 0..<nI {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            if isInterfaceFace[f] || isSolidCell[P] || isSolidCell[N] { flux[f] = 0; continue }
            let w = g.weight[f]
            let S = m.faceAreas[f]
            let rhof = w * state.rho[P] + (1 - w) * state.rho[N]
            let ubar = w * state.u[P] + (1 - w) * state.u[N]
            let Df = w * Dcell[P] + (1 - w) * Dcell[N]
            let gpbar = w * gradP[P] + (1 - w) * gradP[N]
            let oc = g.orthCoeff[f]
            var mf = rhof * (dot(ubar, S) - Df * oc * ((state.p[N] - state.p[P]) - dot(gpbar, g.delta[f])))
            if haveOld && urf < 1 {
                let ubarOld = w * uPrev[P] + (1 - w) * uPrev[N]
                mf += (1 - urf) * (massFluxPrev[f] - rhof * dot(ubarOld, S))
            }
            if transient && !state.massFluxOld.isEmpty {
                let c = rhof * Df / dt
                let uo = w * state.uOld[P] + (1 - w) * state.uOld[N]
                if second {
                    let uoo = w * state.uOldOld[P] + (1 - w) * state.uOldOld[N]
                    mf += c * (2 * (state.massFluxOld[f] / rhof - dot(uo, S)) - 0.5 * (state.massFluxOldOld[f] / rhof - dot(uoo, S)))
                } else {
                    mf += c * (state.massFluxOld[f] / rhof - dot(uo, S))
                }
            }
            flux[f] = mf
        }
        // Boundaries
        var outflowFaces: [Int] = []
        for f in nI..<g.nFaces {
            let bf = f - nI
            let P = Int(m.owner[f])
            if isSolidCell[P] { flux[f] = 0; continue }
            let S = m.faceAreas[f]
            switch bc.kind[bf] {
            case .empty, .wall, .slipWall, .symmetry: flux[f] = 0
            case .velocityInlet: flux[f] = state.rho[P] * dot(bc.uSpec[bf], S)
            case .pressureOutlet, .pressureInlet, .farField:
                let oc = g.orthCoeff[f]
                flux[f] = state.rho[P] * (dot(state.u[P], S) - Dcell[P] * oc * ((state.bP[bf] - state.p[P]) - dot(gradP[P], g.delta[f])))
                if bc.kind[bf] == .farField && dot(bc.uSpec[bf], S) < 0 {
                    // inflow part of the far field behaves like a velocity inlet
                    flux[f] = state.rho[P] * dot(bc.uSpec[bf], S)
                }
            case .outflow:
                flux[f] = state.rho[P] * dot(state.u[P], S)
                outflowFaces.append(f)
            }
        }
        // Outflow: scale to satisfy global continuity
        if !outflowFaces.isEmpty {
            var inflow = 0.0
            for f in nI..<g.nFaces where bc.kind[f - nI] != .outflow { inflow -= flux[f] }
            var out = 0.0
            for f in outflowFaces { out += max(flux[f], 0) }
            let total = outflowFaces.reduce(0.0) { $0 + m.faceAreaMag[$1] }
            for f in outflowFaces {
                flux[f] = out > 1e-300 ? max(flux[f], 0) * inflow / out : inflow * m.faceAreaMag[f] / max(total, 1e-300)
            }
        }
        state.massFlux = flux
    }

    // MARK: Pressure correction

    /// Solves the p' equation and corrects fluxes, velocities and pressure. Returns raw continuity imbalance.
    func correctPressure(urfP: Double, correctVelocity: Bool = true) -> Double {
        let m = mesh, g = geo
        let nI = g.nInternal, nC = g.nCells
        let diag = g.pattern.diag
        var rhs = [Double](repeating: 0, count: nC)
        var imbalance = 0.0
        // net outflow per cell
        for f in 0..<nI {
            let F = state.massFlux[f]
            rhs[Int(m.owner[f])] -= F
            rhs[Int(m.neighbour[f])] += F
        }
        for f in nI..<g.nFaces { rhs[Int(m.owner[f])] -= state.massFlux[f] }
        if isTransient {
            // variable density: rho change contributes to continuity
            let dt = setup.run.timeStepSize
            if !state.rhoOld.isEmpty {
                for c in 0..<nC where !isSolidCell[c] {
                    rhs[c] -= (state.rho[c] - state.rhoOld[c]) * m.cellVolumes[c] / dt
                }
            }
        }
        for c in 0..<nC where !isSolidCell[c] { imbalance += abs(rhs[c]) }

        Ap.zero()
        var faceCoeff = [Double](repeating: 0, count: g.nFaces)
        var anyDirichlet = false
        Ap.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                if isInterfaceFace[f] || isSolidCell[P] || isSolidCell[N] { continue }
                let w = g.weight[f]
                let rhof = w * state.rho[P] + (1 - w) * state.rho[N]
                let Df = w * Dcell[P] + (1 - w) * Dcell[N]
                let c = rhof * Df * g.orthCoeff[f]
                faceCoeff[f] = c
                V[Int(diag[P])] += c; V[Int(diag[N])] += c
                V[Int(g.upper[f])] -= c; V[Int(g.lower[f])] -= c
            }
            for f in nI..<g.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                if isSolidCell[P] { continue }
                let k = bc.kind[bf]
                let pressureFace = k == .pressureOutlet || k == .pressureInlet || (k == .farField && dot(bc.uSpec[bf], m.faceAreas[f]) >= 0)
                if pressureFace {
                    let c = state.rho[P] * Dcell[P] * g.orthCoeff[f]
                    faceCoeff[f] = c
                    V[Int(diag[P])] += c
                    anyDirichlet = true
                }
            }
            for c in 0..<nC where isSolidCell[c] {
                V[Int(diag[c])] = 1; rhs[c] = 0
            }
            if !anyDirichlet {
                // Soft pin of the reference cell removes the constant null space.
                let k = Int(diag[refCell])
                V[k] += V[k]
            }
        }
        for c in 0..<nC { pCorr[c] = 0 }
        pSolver.solve(Ap, x: &pCorr, b: rhs)

        // Optional extra non-orthogonal correctors are handled by the caller.
        // Correct face fluxes
        for f in 0..<nI where faceCoeff[f] != 0 {
            state.massFlux[f] -= faceCoeff[f] * (pCorr[Int(m.neighbour[f])] - pCorr[Int(m.owner[f])])
        }
        var pcb = [Double](repeating: 0, count: m.nBoundaryFaces)
        for f in nI..<g.nFaces {
            let bf = f - nI
            let P = Int(m.owner[f])
            if faceCoeff[f] != 0 {
                state.massFlux[f] += faceCoeff[f] * pCorr[P]
                pcb[bf] = 0
            } else {
                pcb[bf] = pCorr[P]
            }
        }
        // Cell velocity correction
        if correctVelocity {
            Gradient.compute(g, pCorr, boundary: pcb, scheme: setup.methods.gradient, into: &gradPc)
            for c in 0..<nC where !isSolidCell[c] {
                state.u[c] -= Dcell[c] * gradPc[c]
                if let ax = m.twoDimensionalAxis { state.u[c][ax] = 0 }
            }
        }
        // Pressure update
        for c in 0..<nC where !isSolidCell[c] { state.p[c] += urfP * pCorr[c] }
        if !anyDirichlet {
            let shift = state.p[refCell]
            for c in 0..<nC { state.p[c] -= shift }
        }
        return imbalance
    }

    /// PISO neighbour correction: du_P = -(sum_nb a_Pnb u'_nb) / a_P using the momentum matrix.
    func pisoNeighbourCorrection(_ uCorr: [Vec3]) {
        let g = geo, m = mesh
        let nC = g.nCells, nI = g.nInternal
        let R = g.pattern.rowPtr, C = g.pattern.colIdx, diag = g.pattern.diag
        var dU = [Vec3](repeating: .zero, count: nC)
        A.values.withUnsafeBufferPointer { V in
            for c in 0..<nC where !isSolidCell[c] {
                var s = Vec3.zero
                for k in Int(R[c])..<Int(R[c + 1]) where k != Int(diag[c]) { s += V[k] * uCorr[Int(C[k])] }
                dU[c] = -s / V[Int(diag[c])]
                if let ax = m.twoDimensionalAxis { dU[c][ax] = 0 }
            }
        }
        for f in 0..<nI where !isInterfaceFace[f] {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            if isSolidCell[P] || isSolidCell[N] { continue }
            let w = g.weight[f]
            let rhof = w * state.rho[P] + (1 - w) * state.rho[N]
            state.massFlux[f] += rhof * dot(w * dU[P] + (1 - w) * dU[N], m.faceAreas[f])
        }
        for f in nI..<g.nFaces {
            let k = bc.kind[f - nI]
            if k == .pressureOutlet || k == .pressureInlet {
                let P = Int(m.owner[f])
                state.massFlux[f] += state.rho[P] * dot(dU[P], m.faceAreas[f])
            }
        }
        for c in 0..<nC { state.u[c] += dU[c] }
    }

    // MARK: Energy & scalars

    func solveEnergy() -> Double {
        let m = mesh, g = geo
        let nI = g.nInternal, nC = g.nCells
        let prt = setup.models.turbulentPrandtl
        // effective conductivity per cell
        var kEff = state.conductivity
        if setup.models.viscous.isTurbulent {
            for c in 0..<nC where !isSolidCell[c] { kEff[c] += state.cp[c] * state.muT[c] / prt }
        }
        var gamma = [Double](repeating: 0, count: g.nFaces)
        var cpF = [Double](repeating: 0, count: g.nFaces)
        for f in 0..<nI {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            let w = g.weight[f]
            // harmonic mean (exact for conjugate interfaces)
            gamma[f] = 1 / ((1 - w) / max(kEff[P], 1e-300) + w / max(kEff[N], 1e-300))
            cpF[f] = w * state.cp[P] + (1 - w) * state.cp[N]
        }
        for f in nI..<g.nFaces {
            let P = Int(m.owner[f])
            let bf = f - nI
            var ke = kEff[P]
            // turbulent wall: thermal wall function through the effective conductivity
            if setup.models.viscous.isTurbulent, wallIndexOfBoundary[bf] >= 0 {
                ke = wallConductivity(Int(wallIndexOfBoundary[bf]), cell: P)
            }
            gamma[f] = ke
            cpF[f] = state.cp[P]
        }
        Gradient.compute(g, state.T, boundary: state.bT, scheme: setup.methods.gradient, into: &gradT)
        var Su = [Double](repeating: 0, count: nC), Sp = [Double](repeating: 0, count: nC)
        for c in 0..<nC {
            let zs = zoneSettings[Int(m.cellZone[c])]
            if zs.energySource != .constant(0) {
                let cc = m.cellCentres[c]
                let q: Double
                switch zs.energySource { case .constant(let d): q = d
                case .expression(let s): q = (try? Expr(s, named: exprs).value(x: cc.x, y: cc.y, z: cc.z, t: state.time)) ?? 0 }
                Su[c] += q * m.cellVolumes[c]
            }
            if isTransient {
                let rv = state.rho[c] * state.cp[c] * m.cellVolumes[c] / setup.run.timeStepSize
                if setup.methods.transient == .secondOrderImplicit && state.timeStep > 1 {
                    Sp[c] += 1.5 * rv; Su[c] += rv * (2 * state.TOld[c] - 0.5 * state.TOldOld[c])
                } else {
                    Sp[c] += rv; Su[c] += rv * state.TOld[c]
                }
            }
        }
        var eq = TransportEquation(phi: state.T, bPhi: state.bT, grad: gradT, gamma: gamma, convScale: cpF,
                                   scheme: setup.methods.energy, bounded: setup.methods.limitMomentum, bc: bc.thermal,
                                   Su: Su, Sp: Sp, relax: setup.controls.urf.energy)
        let asm = TransportAssembler(geo: g)
        var b = [Double](repeating: 0, count: nC)
        let (raw, nrm) = asm.assemble(&eq, flux: state.massFlux, A: A, b: &b)
        var x = state.T
        energySolver.solve(A, x: &x, b: b)
        let lim = setup.controls.limits
        for c in 0..<nC { x[c] = min(max(x[c], lim.minimumTemperature), lim.maximumTemperature) }
        eq.phi = x
        asm.updateBoundary(&eq, flux: state.massFlux)
        state.T = x
        state.bT = eq.bPhi
        // wall heat flux into the fluid (W/m2), positive into the domain
        for f in nI..<g.nFaces {
            let bf = f - nI
            let P = Int(m.owner[f])
            if bc.kind[bf] == .wall || bc.kind[bf] == .slipWall {
                state.bHeatFlux[bf] = gamma[f] * (state.bT[bf] - state.T[P]) / g.normalDistance(f)
            }
        }
        return nrm > 1e-300 ? raw / nrm : raw
    }

    func solveScalars() -> [Double] {
        let m = mesh, g = geo
        let nI = g.nInternal, nC = g.nCells
        var out: [Double] = []
        for (si, sc) in setup.models.passiveScalars.enumerated() {
            var gamma = [Double](repeating: 0, count: g.nFaces)
            for f in 0..<g.nFaces {
                let P = Int(m.owner[f])
                let N = f < nI ? Int(m.neighbour[f]) : P
                let w = f < nI ? g.weight[f] : 1
                let rhoF = w * state.rho[P] + (1 - w) * state.rho[N]
                let muTF = w * state.muT[P] + (1 - w) * state.muT[N]
                gamma[f] = rhoF * sc.diffusivity + (setup.models.viscous.isTurbulent ? muTF / sc.turbulentSchmidt : 0)
            }
            var grad: [Vec3] = []
            Gradient.compute(g, state.scalars[si], boundary: state.bScalars[si], scheme: setup.methods.gradient, into: &grad)
            var Su = [Double](repeating: 0, count: nC), Sp = Su
            if isTransient {
                for c in 0..<nC {
                    let rv = state.rho[c] * m.cellVolumes[c] / setup.run.timeStepSize
                    let old = state.scalarsOld.count > si ? state.scalarsOld[si][c] : state.scalars[si][c]
                    Sp[c] += rv; Su[c] += rv * old
                }
            }
            var fixed: [Bool]? = nil
            if hasSolids { fixed = isSolidCell }
            var eq = TransportEquation(phi: state.scalars[si], bPhi: state.bScalars[si], grad: grad, gamma: gamma,
                                       scheme: setup.methods.scalars, bounded: true, bc: bc.scalars[si],
                                       Su: Su, Sp: Sp, relax: setup.controls.urf.scalars,
                                       fixedMask: fixed, fixedValue: fixed == nil ? nil : [Double](repeating: 0, count: nC))
            let asm = TransportAssembler(geo: g)
            var b = [Double](repeating: 0, count: nC)
            let (raw, nrm) = asm.assemble(&eq, flux: state.massFlux, A: A, b: &b)
            var x = state.scalars[si]
            scalarSolver.solve(A, x: &x, b: b)
            eq.phi = x
            asm.updateBoundary(&eq, flux: state.massFlux)
            state.scalars[si] = x
            state.bScalars[si] = eq.bPhi
            out.append(nrm > 1e-300 ? raw / nrm : raw)
        }
        return out
    }

    // MARK: Iteration

    /// One outer SIMPLE-family iteration. Returns the residuals recorded.
    @discardableResult
    public func iterate() -> [String: Double] {
        let urfU = setup.controls.urf.momentum
        let urfP = setup.methods.coupling == .simple ? setup.controls.urf.pressure : max(setup.controls.urf.pressure, 1.0)
        computeGradients()
        updateProperties()
        if setup.models.viscous.isTurbulent { updateWallFunctions() } else { updateLaminarWalls() }
        uPrev = state.u
        massFluxPrev = state.massFlux
        let resU = solveMomentum(urf: urfU)
        computeMassFluxes(urf: urfU)
        let piso = setup.methods.coupling == .piso
        var uBefore = state.u
        let imbalance = correctPressure(urfP: piso ? 1.0 : urfP)
        if piso {
            for _ in 0..<max(setup.methods.pisoCorrectors, 1) {
                var du = state.u
                for c in 0..<du.count { du[c] -= uBefore[c] }
                pisoNeighbourCorrection(du)
                uBefore = state.u
                _ = correctPressure(urfP: 1)
            }
        }
        updateFlowBoundaries()

        var r: [String: Double] = [:]
        r["continuity"] = residuals.scaleContinuity(imbalance)
        let vnames = ["x-velocity", "y-velocity", "z-velocity"]
        for k in 0..<3 where k != mesh.twoDimensionalAxis { r[vnames[k]] = resU[k] }
        if setup.models.energy { r["energy"] = solveEnergy() }
        if setup.models.viscous.isTurbulent {
            computeGradients()
            for (k, v) in solveTurbulence() { r[k] = v }
        }
        if !setup.models.passiveScalars.isEmpty {
            for (i, v) in solveScalars().enumerated() { r[setup.models.passiveScalars[i].name] = v }
        }
        state.iteration += 1
        residuals.record(iteration: state.iteration, r)
        return r
    }

    /// Residuals below criteria?
    public func isConverged(_ r: [String: Double]) -> Bool {
        let c = setup.residuals
        guard c.checkConvergence else { return false }
        for (k, v) in r {
            let lim: Double
            switch k {
            case "continuity": lim = c.continuity
            case "x-velocity", "y-velocity", "z-velocity": lim = c.velocity
            case "energy": lim = c.energy
            case "k", "omega", "epsilon", "nut": lim = c.turbulence
            default: lim = c.scalars
            }
            if !(v <= lim) { return false }
        }
        return true
    }

    // MARK: Running

    public struct RunResult: Sendable {
        public var iterations: Int
        public var converged: Bool
        public var diverged: Bool
        public var stopped: Bool
    }

    /// Steady: iterate until convergence or `iterations`. Transient: advance time steps.
    public func run(iterations: Int? = nil, timeSteps: Int? = nil,
                    progress: ((PressureBasedSolver, [String: Double]) -> Void)? = nil) -> RunResult {
        stopRequested = false
        if isTransient { return runTransient(steps: timeSteps ?? setup.run.numberOfTimeSteps, progress: progress) }
        let n = iterations ?? setup.run.iterations
        var done = 0
        for _ in 0..<n {
            let r = iterate()
            done += 1
            if r.values.contains(where: { !$0.isFinite }) || state.u.contains(where: { !$0.x.isFinite }) {
                log("Divergence detected in AMG solver or residuals at iteration \(state.iteration).")
                return RunResult(iterations: done, converged: false, diverged: true, stopped: false)
            }
            recordReports(x: Double(state.iteration))
            progress?(self, r)
            if done % max(setup.run.reportingInterval, 1) == 0 { log(formatResiduals(r)) }
            if isConverged(r) {
                log("!  \(state.iteration) solution is converged")
                return RunResult(iterations: done, converged: true, diverged: false, stopped: false)
            }
            if stopRequested { return RunResult(iterations: done, converged: false, diverged: false, stopped: true) }
        }
        return RunResult(iterations: done, converged: false, diverged: false, stopped: false)
    }

    func runTransient(steps: Int, progress: ((PressureBasedSolver, [String: Double]) -> Void)?) -> RunResult {
        var total = 0
        for _ in 0..<steps {
            state.storeOldTime()
            state.timeStep += 1
            state.time += setup.run.timeStepSize
            if bc.zoneSettings.contains(where: { s in [s.velocityMagnitude, s.gaugePressure, s.temperature].contains { $0.isSpatiallyVarying } || s.velocity.contains { $0.isSpatiallyVarying } }) {
                try? bc.update(mesh: mesh, setup: setup, exprs: exprs, time: state.time, density: state.rho, viscosity: state.mu)
                updateFlowBoundaries()
            }
            var last: [String: Double] = [:]
            for _ in 0..<setup.run.maxIterationsPerTimeStep {
                last = iterate()
                total += 1
                progress?(self, last)
                if last.values.contains(where: { !$0.isFinite }) {
                    log("Divergence detected at time step \(state.timeStep).")
                    return RunResult(iterations: total, converged: false, diverged: true, stopped: false)
                }
                if isConverged(last) || stopRequested { break }
            }
            if setup.run.dataSampling { sampleStatistics() }
            recordReports(x: state.time)
            log(String(format: "Flow time = %.6g s, time step = %d  ", state.time, state.timeStep) + formatResiduals(last))
            if stopRequested { return RunResult(iterations: total, converged: false, diverged: false, stopped: true) }
        }
        return RunResult(iterations: total, converged: true, diverged: false, stopped: false)
    }

    func sampleStatistics() {
        if state.meanU.isEmpty { state.meanU = [Vec3](repeating: .zero, count: mesh.nCells); state.meanP = [Double](repeating: 0, count: mesh.nCells) }
        state.samples += 1
        let a = 1 / Double(state.samples)
        for c in 0..<mesh.nCells {
            state.meanU[c] += a * (state.u[c] - state.meanU[c])
            state.meanP[c] += a * (state.p[c] - state.meanP[c])
        }
    }

    public func formatResiduals(_ r: [String: Double]) -> String {
        var s = String(format: "%6d ", state.iteration)
        for name in residuals.names { if let v = r[name] { s += String(format: " %@ %.4e", name, v) } }
        return s
    }

    func recordReports(x: Double) {
        guard !setup.reports.isEmpty else { return }
        var vals: [String: Double] = [:]
        for rep in setup.reports { vals[rep.name] = Reports.evaluate(rep, solver: self) }
        reportHistory.record(x: x, vals)
    }

    // MARK: Laminar walls

    func updateLaminarWalls() {
        for (i, w) in walls.enumerated() {
            muWall[i] = state.mu[w.cell]
        }
        updateWallShear()
    }

    /// Wall shear stress (force per area exerted by the fluid on the wall) and y+.
    func updateWallShear() {
        let nI = geo.nInternal
        for (i, w) in walls.enumerated() where !w.isInterface {
            let f = w.face, bf = f - nI
            let P = w.cell
            let n = normalized(mesh.faceAreas[f])
            let du = state.u[P] - state.bU[bf]
            let dut = du - dot(du, n) * n
            let dn = geo.normalDistance(f)
            state.bWallShear[bf] = muWall[i] * dut / dn
            let tau = norm(state.bWallShear[bf])
            let utau = sqrt(tau / max(state.rho[P], 1e-300))
            state.bYPlus[bf] = state.rho[P] * utau * dn / max(state.mu[P], 1e-300)
            yPlusWall[i] = state.bYPlus[bf]
        }
    }
}
