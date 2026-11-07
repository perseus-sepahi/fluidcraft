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
    /// Actuator disks: zone index, the cell sampled for the free-stream speed (-1: use the
    /// reference speed), ½ρA·Ct / V, and the thrust direction.
    struct DiskSource { var zone: Int; var monitorCell: Int; var coefficient: Double; var direction: Vec3; var referenceVelocity: Double }
    let disks: [DiskSource]
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
    var gradPScratch: [Vec3] = []
    var bx: [Double], by: [Double], bz: [Double]
    var scratch: [Double] = [], scratchB: [Double] = []
    var uPrev: [Vec3] = []
    var massFluxPrev: [Double] = []
    /// Wall shear viscosity per wall face (laminar or wall-function value).
    public internal(set) var muWall: [Double]
    /// Explicit transpose-stress source from the previous iteration (under-relaxed).
    var transposeSource: [Vec3] = []
    public internal(set) var yPlusWall: [Double]

    public internal(set) var residuals = ResidualHistory()
    public internal(set) var reportHistory = ReportHistory()
    public var log: (String) -> Void = { print($0) }
    public var stopRequested = false
    var _locator: CellLocator? = nil
    /// Conservative variables when the density-based solver is selected.
    var densityState: DensityBasedState? = nil
    var _resistiveCells: [Int]? = nil
    public var isDensityBased: Bool { setup.general.solver == .densityBased }

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
        var disks: [DiskSource] = []
        for z in mesh.cellZones {
            var cs = s.cellZones[z.name] ?? CellZoneSettings()
            if let disk = cs.actuatorDisk {
                // actuator disk: thrust ½ ρ A Ct U∞² spread over the zone volume, against the disk
                // direction. U∞ is sampled at the upstream monitor point every iteration (as
                // OpenFOAM's actuationDiskSource), so a turbine in a wake feels the wake speed.
                var vol = 0.0
                for c in 0..<mesh.nCells where mesh.cellZones[Int(mesh.cellZone[c])].name == z.name { vol += mesh.cellVolumes[c] }
                let rho = s.material(named: cs.material)?.density ?? 1.225
                let d = normalized(Vec3(disk.direction[0], disk.direction[1], disk.direction[2]))
                let up = Vec3(disk.upstreamPoint.count > 0 ? disk.upstreamPoint[0] : 0, disk.upstreamPoint.count > 1 ? disk.upstreamPoint[1] : 0,
                              disk.upstreamPoint.count > 2 ? disk.upstreamPoint[2] : 0)
                let (lo, hi) = (mesh.bounds.min, mesh.bounds.max)
                let inside = up.x >= lo.x && up.x <= hi.x && up.y >= lo.y && up.y <= hi.y && up.z >= lo.z && up.z <= hi.z
                var monitor = -1
                if inside {
                    var best = Double.infinity
                    for c in 0..<mesh.nCells { let dd = norm(mesh.cellCentres[c] - up); if dd < best { best = dd; monitor = c } }
                }
                disks.append(DiskSource(zone: zs.count, monitorCell: monitor,
                                        coefficient: 0.5 * rho * disk.diskArea * disk.thrustCoefficient / max(vol, 1e-300),
                                        direction: d, referenceVelocity: disk.referenceVelocity))
            }
            zs.append(cs)
            guard let mat = s.material(named: cs.material) else { throw SolverError("cell zone '\(z.name)' uses unknown material '\(cs.material)'") }
            mats.append(mat)
        }
        zoneMaterial = mats
        zoneSettings = zs
        self.disks = disks
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
        let oldScalarNames = setup.models.passiveScalars.map(\.name)
        if s2.general.solver != setup.general.solver { densityState = nil }
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
        // Keep scalar fields by name when scalars are added, removed or reordered.
        let oldNames = oldScalarNames
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
            state.scalarsOld = []; state.scalarsOldOld = []
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
        let second = setup.methods.pressure == .secondOrder
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
        guard second else { return state.p[P] }
        // Second-order extrapolation, limited to the range of the interior neighbours. On thin
        // wall cells (tetrahedra) the least-squares wall-normal gradient is dominated by the
        // boundary value itself; without the limit the extrapolation feeds back on itself.
        let pP = state.p[P]
        var lo = 0.0, hi = 0.0
        for k in mesh.cellFaceRange(P) {
            let f = Int(mesh.cellFaces[k])
            guard f < geo.nInternal else { continue }
            let n = Int(mesh.owner[f]) == P ? Int(mesh.neighbour[f]) : Int(mesh.owner[f])
            let dp = state.p[n] - pP
            lo = min(lo, dp); hi = max(hi, dp)
        }
        return pP + min(max(dot(gradP[P], d), lo), hi)
    }

    // MARK: Initialization

    public func initialize() throws {
        try Initialization.run(self)
        densityState = nil
        if isDensityBased {
            dbInitialize()
            log("Density-based solver: initialized conservative variables (γ = \(String(format: "%.4f", gasGamma))).")
        }
    }

    // MARK: Gradients

    func computeGradients() {
        let scheme = setup.methods.gradient
        // fluid cells see the solid as a wall, not as a neighbour with a (meaningless) pressure
        let mask = hasSolids ? isInterfaceFace : nil
        Gradient.compute(geo, state.p, boundary: state.bP, scheme: scheme, into: &gradP, interface: mask)
        if scheme == .leastSquares && setup.methods.conservativePressureGradient {
            Gradient.conservative(geo, state.p, boundary: state.bP, reconstruction: gradP, into: &gradPScratch, interface: mask)
            swap(&gradP, &gradPScratch)
        }
        if setup.methods.pressure == .standard && aP.count == mesh.nCells && !resistiveCells.isEmpty {
            momentumWeightedPressureGradient(cells: resistiveCells)
        }
        Gradient.compute(geo, state.u, boundary: state.bU, scheme: scheme, into: &gradU, scratch: &scratch, scratchB: &scratchB)
    }

    /// Face value of the pressure-correction coefficient D = V/a_P. Linear interpolation, except
    /// where D jumps by more than 4x (porous interfaces, strong implicit sources): there the
    /// distance-weighted harmonic mean lets the stiff side govern, as series resistances do.
    @inline(__always) func faceD(_ dP: Double, _ dN: Double, _ w: Double) -> Double {
        let lin = w * dP + (1 - w) * dN
        let lo = min(dP, dN), hi = max(dP, dN)
        guard lo > 0, hi > 4 * lo else { return lin }
        return 1 / (w / dP + (1 - w) / dN)
    }

    /// Fluent's "Standard" pressure interpolation: Green-Gauss gradient with face pressures
    /// weighted by the momentum coefficients, p_f = (p_P/a_P + p_N/a_N) / (1/a_P + 1/a_N).
    /// It puts pressure kinks (porous media, strong body forces) exactly at the faces where
    /// the resistance changes, which removes spurious velocity spikes there.
    /// Porous cells and their face neighbours: where the momentum-weighted gradient is applied.
    var resistiveCells: [Int] {
        if let r = _resistiveCells { return r }
        var mark = [Bool](repeating: false, count: mesh.nCells)
        for c in 0..<mesh.nCells where zoneSettings[Int(mesh.cellZone[c])].porous != nil {
            mark[c] = true
            for k in mesh.cellFaceRange(c) {
                let f = Int(mesh.cellFaces[k])
                if f < mesh.nInternalFaces { mark[Int(mesh.owner[f])] = true; mark[Int(mesh.neighbour[f])] = true }
            }
        }
        let r = mark.indices.filter { mark[$0] }
        _resistiveCells = r
        return r
    }

    func momentumWeightedPressureGradient(cells: [Int]) {
        let m = mesh, g = geo
        let nI = g.nInternal
        let p = state.p, bP = state.bP, a = aP
        let solid = isSolidCell
        if gradP.count != m.nCells { gradP = [Vec3](repeating: .zero, count: m.nCells) }
        gradP.withUnsafeMutableBufferPointer { gp in
            let G = SharedPtr(gp.baseAddress!)
            Parallel.forEach(cells.count) { range in
                for ci in range {
                    let c = cells[ci]
                    var s = Vec3.zero
                    for k in m.cellFaceRange(c) {
                        let f = Int(m.cellFaces[k])
                        let own = Int(m.owner[f]) == c
                        let pf: Double
                        if f < nI {
                            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                            if solid[P] || solid[N] { pf = p[c] }
                            else {
                                let wP = 1 / max(a[P], 1e-300), wN = 1 / max(a[N], 1e-300)
                                pf = (p[P] * wP + p[N] * wN) / (wP + wN)
                            }
                        } else {
                            pf = g.isEmptyFace[f] ? p[c] : bP[f - nI]
                        }
                        s += own ? pf * m.faceAreas[f] : -(pf * m.faceAreas[f])
                    }
                    G[c] = s / m.cellVolumes[c]
                }
            }
        }
    }

    // MARK: Momentum

    /// Compile a cell-zone source (constant or expression) once per call.
    func sourceFunction(_ q: Quantity) -> ((Vec3) -> Double)? {
        switch q {
        case .constant(let d): return d == 0 ? nil : { _ in d }
        case .expression(let src):
            guard let e = try? Expr(src, named: exprs) else { return nil }
            let t = state.time
            return { c in e.value(x: c.x, y: c.y, z: c.z, t: t) }
        }
    }

    /// Assemble and solve momentum; returns scaled residuals for x, y, z.
    ///
    /// Assembly is data-parallel in two phases: (A) every interior face computes its
    /// coefficients and explicit fluxes independently; (B) every cell gathers its faces
    /// through the cell->face connectivity and adds boundary and volume terms.
    /// Thrust per unit volume [N/m³] of each zone that is an actuator disk (nil otherwise), from
    /// the current wind speed at its monitor point.
    public func actuatorDiskForceDensity() -> [Vec3?] {
        var out = [Vec3?](repeating: nil, count: zoneSettings.count)
        for d in disks {
            let U = d.monitorCell >= 0 ? max(0, dot(state.u[d.monitorCell], d.direction)) : d.referenceVelocity
            out[d.zone] = -(d.coefficient * U * U) * d.direction
        }
        return out
    }

    func solveMomentum(urf: Double) -> [Double] {
        let m = mesh, g = geo
        let nI = g.nInternal, nC = g.nCells
        let muEff = effectiveViscosity()
        let scheme = setup.methods.momentum
        let limitMom = setup.methods.limitMomentum
        // Transpose viscous stress: always for variable molecular viscosity, optional for turbulence.
        let turbulent = zoneMaterial.contains { $0.viscosityMethod != .constant } ||
            (setup.models.viscous.isTurbulent && setup.methods.transposeStress)
        let nonOrth = g.hasNonOrthogonality
        let psi = setup.methods.nonOrthogonalLimit ?? g.automaticNonOrthogonalLimit
        let grav = gravity
        let rhoOp = grav != .zero ? operatingDensity() : 0
        let flux = state.massFlux
        let u = state.u
        let gU0 = gradU[0], gU1 = gradU[1], gU2 = gradU[2]
        let solid = isSolidCell, iface = isInterfaceFace
        let hoActive = scheme != .firstOrderUpwind

        // Phase A: interior faces
        var fUp = [Double](repeating: 0, count: nI)
        var fLo = [Double](repeating: 0, count: nI)
        var fEx = [Vec3](repeating: .zero, count: nI)
        var fTr = [Vec3](repeating: .zero, count: turbulent ? nI : 0)
        fUp.withUnsafeMutableBufferPointer { up in fLo.withUnsafeMutableBufferPointer { lo in
        fEx.withUnsafeMutableBufferPointer { ex in fTr.withUnsafeMutableBufferPointer { tr in
            let UP = SharedPtr(up.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            let LO = SharedPtr(lo.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            let EX = SharedPtr(ex.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            let TR = SharedPtr(tr.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            Parallel.forEach(nI) { range in
                for f in range {
                    let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                    if iface[f] || solid[P] || solid[N] { continue }
                    let F = flux[f]
                    let w = g.weight[f]
                    let mu = w * muEff[P] + (1 - w) * muEff[N]
                    let dif = mu * g.orthCoeff[f]
                    UP[f] = -(dif + max(-F, 0))
                    LO[f] = -(dif + max(F, 0))
                    var expl = Vec3.zero
                    if F != 0 && hoActive {
                        let cf = m.faceCentres[f]
                        let rP = cf - m.cellCentres[P], rN = cf - m.cellCentres[N]
                        let dd = g.delta[f]
                        let uP = u[P], uN = u[N]
                        expl.x = -F * convectionCorrection(scheme, bounded: limitMom, F: F, phiP: uP.x, phiN: uN.x, gradP: gU0[P], gradN: gU0[N], w: w, rP: rP, rN: rN, d: dd)
                        expl.y = -F * convectionCorrection(scheme, bounded: limitMom, F: F, phiP: uP.y, phiN: uN.y, gradP: gU1[P], gradN: gU1[N], w: w, rP: rP, rN: rN, d: dd)
                        expl.z = -F * convectionCorrection(scheme, bounded: limitMom, F: F, phiP: uP.z, phiN: uN.z, gradP: gU2[P], gradN: gU2[N], w: w, rP: rP, rN: rN, d: dd)
                    }
                    let g0 = w * gU0[P] + (1 - w) * gU0[N]
                    let g1 = w * gU1[P] + (1 - w) * gU1[N]
                    let g2 = w * gU2[P] + (1 - w) * gU2[N]
                    if nonOrth && psi > 0 {
                        let T = g.nonOrth[f]
                        let uP = u[P], uN = u[N]
                        expl += Vec3(FVGeometry.limitCorrection(mu * dot(g0, T), orthogonal: dif * (uN.x - uP.x), psi: psi),
                                     FVGeometry.limitCorrection(mu * dot(g1, T), orthogonal: dif * (uN.y - uP.y), psi: psi),
                                     FVGeometry.limitCorrection(mu * dot(g2, T), orthogonal: dif * (uN.z - uP.z), psi: psi))
                    }
                    EX[f] = expl
                    if turbulent {
                        // div(mu ((grad u)^T - (div u) I)): deviatoric transpose (see momentum notes)
                        let S = m.faceAreas[f]
                        let t = g0 * S.x + g1 * S.y + g2 * S.z
                        let divu = g0.x + g1.y + g2.z
                        TR[f] = mu * (t - divu * S)
                    }
                }
            }
        }}}}

        // Zone source closures (compiled once)
        let zoneMom: [[((Vec3) -> Double)?]] = zoneSettings.map { zs in zs.momentumSource.map { sourceFunction($0) } }
        let diskForce = actuatorDiskForceDensity()
        let transient = isTransient
        let dt = setup.run.timeStepSize
        let second = setup.methods.transient == .secondOrderImplicit && state.timeStep > 1
        let uOld = state.uOld, uOldOld = state.uOldOld
        let rho = state.rho, muL = state.mu
        let gP = gradP
        let kinds = bc.kind, uSpec = bc.uSpec, bU = state.bU
        let wib = wallIndexOfBoundary, wif = wallIndexOfFace, muW = muWall
        if turbulent && transposeSource.count != nC { transposeSource = [Vec3](repeating: .zero, count: nC) }
        var diagV = [Double](repeating: 0, count: nC)
        if bx.count != nC { bx = diagV; by = diagV; bz = diagV }

        // Phase B: cells gather faces + boundary + volume terms
        diagV.withUnsafeMutableBufferPointer { dv in bx.withUnsafeMutableBufferPointer { bxp in
        by.withUnsafeMutableBufferPointer { byp in bz.withUnsafeMutableBufferPointer { bzp in
        transposeSource.withUnsafeMutableBufferPointer { tsp in
            let DV = SharedPtr(dv.baseAddress!), BX = SharedPtr(bxp.baseAddress!), BY = SharedPtr(byp.baseAddress!), BZ = SharedPtr(bzp.baseAddress!)
            let TS = SharedPtr(tsp.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            Parallel.forEach(nC) { range in
                for c in range {
                    if solid[c] { DV[c] = 1; BX[c] = 0; BY[c] = 0; BZ[c] = 0; continue }
                    var d = 0.0
                    var b = Vec3.zero
                    var tsum = Vec3.zero
                    let uc = u[c]
                    for k in m.cellFaceRange(c) {
                        let f = Int(m.cellFaces[k])
                        let own = Int(m.owner[f]) == c
                        if f < nI {
                            if iface[f] {
                                let wi = Int(wif[f])
                                let dn = abs(dot(m.faceAreas[f], m.faceCentres[f] - m.cellCentres[c])) / max(m.faceAreaMag[f], 1e-300)
                                d += muW[wi] * m.faceAreaMag[f] / max(dn, 1e-300)
                                continue
                            }
                            let other = own ? Int(m.neighbour[f]) : Int(m.owner[f])
                            if solid[other] { continue }
                            if own { d -= fUp[f]; b += fEx[f]; if turbulent { tsum += fTr[f] } }
                            else { d -= fLo[f]; b -= fEx[f]; if turbulent { tsum -= fTr[f] } }
                            continue
                        }
                        let bf = f - nI
                        let F = flux[f]
                        switch kinds[bf] {
                        case .empty: continue
                        case .wall:
                            let wi = Int(wib[bf])
                            let dif = (wi >= 0 ? muW[wi] : muEff[c]) * g.orthCoeff[f]
                            d += dif
                            b += dif * uSpec[bf]
                        case .slipWall, .symmetry:
                            // normal stress -2 mu |S|/dn (u.n) n: implicit isotropic part + explicit tangential remainder
                            let n = normalized(m.faceAreas[f])
                            let cs = 2 * muEff[c] * m.faceAreaMag[f] / g.normalDistance(f)
                            d += cs
                            b += cs * (uc - dot(uc, n) * n)
                        case .velocityInlet, .farField:
                            let a = muEff[c] * g.orthCoeff[f] + max(-F, 0)
                            d += a
                            b += a * bU[bf]
                        case .pressureInlet:
                            if F < 0 { d += -F; b += -F * bU[bf] }
                        case .pressureOutlet, .outflow:
                            if F < 0 {
                                let n = normalized(m.faceAreas[f])
                                d += -F; b += -F * (dot(uc, n) * n)
                            }
                        }
                        if turbulent {
                            let S = m.faceAreas[f]
                            let t = gU0[c] * S.x + gU1[c] * S.y + gU2[c] * S.z
                            let divu = gU0[c].x + gU1[c].y + gU2[c].z
                            let wi = Int(wib[bf])
                            tsum += (wi >= 0 ? muW[wi] : muEff[c]) * (t - divu * S)
                        }
                    }
                    if turbulent {
                        // under-relaxed explicit transpose source
                        let v = 0.5 * tsum + 0.5 * TS[c]
                        TS[c] = v
                        b += v
                    }
                    // volume terms
                    let vol = m.cellVolumes[c]
                    b -= gP[c] * vol
                    if grav != .zero { b += buoyancyDensity(c, rhoOp: rhoOp) * grav * vol }
                    let zi = Int(m.cellZone[c])
                    let zs = zoneSettings[zi]
                    if let por = zs.porous {
                        let speed = norm(uc)
                        let ci = Vec3(muL[c] * por.viscousResistance[0] + 0.5 * rho[c] * por.inertialResistance[0] * speed,
                                      muL[c] * por.viscousResistance[1] + 0.5 * rho[c] * por.inertialResistance[1] * speed,
                                      muL[c] * por.viscousResistance[2] + 0.5 * rho[c] * por.inertialResistance[2] * speed) * vol
                        let cav = (ci.x + ci.y + ci.z) / 3
                        d += cav
                        b -= (ci - Vec3(repeating: cav)) * uc
                    }
                    if zs.frameMotion {
                        let a = normalized(Vec3(zs.rotationAxisDirection[0], zs.rotationAxisDirection[1], zs.rotationAxisDirection[2]))
                        b -= rho[c] * cross(zs.rotationSpeed * a, uc) * vol   // absolute-velocity formulation: -rho (Omega x u)
                    }
                    if let fd = diskForce[zi] { b += fd * vol }
                    let srcs = zoneMom[zi]
                    if srcs.contains(where: { $0 != nil }) {
                        let cc = m.cellCentres[c]
                        for k in 0..<3 { if let fn = srcs[k] { b[k] += fn(cc) * vol } }
                    }
                    if transient {
                        let rv = rho[c] * vol / dt
                        if second { d += 1.5 * rv; b += rv * (2 * uOld[c] - 0.5 * uOldOld[c]) }
                        else { d += rv; b += rv * uOld[c] }
                    }
                    DV[c] = d; BX[c] = b.x; BY[c] = b.y; BZ[c] = b.z
                }
            }
        }}}}}

        // Phase C: write the matrix
        A.zero()
        let diag = g.pattern.diag
        A.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI {
                V[Int(g.upper[f])] += fUp[f]
                V[Int(g.lower[f])] += fLo[f]
            }
            for c in 0..<nC { V[Int(diag[c])] = diagV[c] }
        }

        // Residuals (unrelaxed), Fluent scaling
        var r = [Double](repeating: 0, count: nC)
        var res = [Double](repeating: 0, count: 3)
        var xs: [[Double]] = [u.map { $0.x }, u.map { $0.y }, u.map { $0.z }]
        let bs = [bx, by, bz]
        for k in 0..<3 where k != mesh.twoDimensionalAxis {
            let raw = A.residual(x: xs[k], b: bs[k], into: &r)
            let nrm = A.diagonalNorm(x: xs[k])
            res[k] = nrm > 1e-300 ? raw / nrm : raw
        }

        // Under-relaxation (shared matrix)
        var bsR = bs
        for c in 0..<nC {
            let kd = Int(diag[c])
            if solid[c] { aP[c] = 1; continue }
            let dd = A.values[kd]
            A.values[kd] = dd / urf
            let extra = (1 - urf) / urf * dd
            bsR[0][c] += extra * u[c].x; bsR[1][c] += extra * u[c].y; bsR[2][c] += extra * u[c].z
            aP[c] = A.values[kd]
        }
        // Solve components (same matrix: AMG coarse operators refreshed once)
        var first = true
        for k in 0..<3 {
            if let ax = mesh.twoDimensionalAxis, ax == k { for c in 0..<nC { xs[k][c] = 0 }; continue }
            momSolver.solve(A, x: &xs[k], b: bsR[k], sameMatrix: !first)
            first = false
        }
        for c in 0..<nC { state.u[c] = Vec3(xs[0][c], xs[1][c], xs[2][c]) }

        // Pressure-correction coefficient D = V / a_P (SIMPLE) or V / (a_P - sum|a_nb|) (SIMPLEC)
        let simplec = setup.methods.coupling == .simplec
        let apL = aP
        Dcell.withUnsafeMutableBufferPointer { dp in
            A.values.withUnsafeBufferPointer { V in
                let DP = SharedPtr(dp.baseAddress!), VV = ConstPtr(V.baseAddress!)
                let R = g.pattern.rowPtr
                Parallel.forEach(nC) { range in
                    for c in range {
                        if solid[c] { DP[c] = 0; continue }
                        var a = apL[c]
                        if simplec {
                            var off = 0.0
                            for k in Int(R[c])..<Int(R[c + 1]) where k != Int(diag[c]) { off += VV[k] }
                            a = max(a + off, 0.05 * a)
                        }
                        DP[c] = m.cellVolumes[c] / a
                    }
                }
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
        do {
            let rho = state.rho, u = state.u, p = state.p, D = Dcell, gP = gradP
            let solid = isSolidCell, iface = isInterfaceFace
            let uPv = uPrev, mPrev = massFluxPrev
            let uO = state.uOld, uOO = state.uOldOld, mO = state.massFluxOld, mOO = state.massFluxOldOld
            let haveT = transient && !mO.isEmpty
            flux.withUnsafeMutableBufferPointer { fp in
                let FL = SharedPtr(fp.baseAddress!)
                Parallel.forEach(nI) { range in
                    for f in range {
                        let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                        if iface[f] || solid[P] || solid[N] { FL[f] = 0; continue }
                        let w = g.weight[f]
                        let S = m.faceAreas[f]
                        let rhof = w * rho[P] + (1 - w) * rho[N]
                        let ubar = w * u[P] + (1 - w) * u[N]
                        let Df = faceD(D[P], D[N], w)
                        let gpbar = w * gP[P] + (1 - w) * gP[N]
                        var mf = rhof * (dot(ubar, S) - Df * g.orthCoeff[f] * ((p[N] - p[P]) - dot(gpbar, g.delta[f])))
                        if haveOld && urf < 1 {
                            let ubarOld = w * uPv[P] + (1 - w) * uPv[N]
                            mf += (1 - urf) * (mPrev[f] - rhof * dot(ubarOld, S))
                        }
                        if haveT {
                            let c = rhof * Df / dt
                            let uo = w * uO[P] + (1 - w) * uO[N]
                            if second {
                                let uoo = w * uOO[P] + (1 - w) * uOO[N]
                                mf += c * (2 * (mO[f] / rhof - dot(uo, S)) - 0.5 * (mOO[f] / rhof - dot(uoo, S)))
                            } else {
                                mf += c * (mO[f] / rhof - dot(uo, S))
                            }
                        }
                        FL[f] = mf
                    }
                }
            }
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
        let solid = isSolidCell, iface = isInterfaceFace
        let flux = state.massFlux, rho = state.rho, D = Dcell
        let kinds = bc.kind, uSpec = bc.uSpec

        // Face coefficients rho_f D_f |S|^2/(S.d) (pressure faces: Dirichlet p' = 0)
        var faceCoeff = [Double](repeating: 0, count: g.nFaces)
        faceCoeff.withUnsafeMutableBufferPointer { fc in
            let FC = SharedPtr(fc.baseAddress!)
            Parallel.forEach(g.nFaces) { range in
                for f in range {
                    let P = Int(m.owner[f])
                    if f < nI {
                        let N = Int(m.neighbour[f])
                        if iface[f] || solid[P] || solid[N] { continue }
                        let w = g.weight[f]
                        FC[f] = (w * rho[P] + (1 - w) * rho[N]) * faceD(D[P], D[N], w) * g.orthCoeff[f]
                    } else {
                        if solid[P] { continue }
                        let k = kinds[f - nI]
                        if k == .pressureOutlet || k == .pressureInlet || (k == .farField && dot(uSpec[f - nI], m.faceAreas[f]) >= 0) {
                            FC[f] = rho[P] * D[P] * g.orthCoeff[f]
                        }
                    }
                }
            }
        }
        var anyDirichlet = false
        for f in nI..<g.nFaces where faceCoeff[f] != 0 { anyDirichlet = true; break }

        // Net outflow (rhs) and diagonal per cell, gathered over each cell's faces
        var rhs = [Double](repeating: 0, count: nC)
        var dgl = [Double](repeating: 0, count: nC)
        let transientRho = isTransient && !state.rhoOld.isEmpty
        let rhoOld = state.rhoOld, dt = setup.run.timeStepSize
        rhs.withUnsafeMutableBufferPointer { rp in dgl.withUnsafeMutableBufferPointer { dp in
            let RH = SharedPtr(rp.baseAddress!), DG = SharedPtr(dp.baseAddress!)
            Parallel.forEach(nC) { range in
                for c in range {
                    if solid[c] { RH[c] = 0; DG[c] = 1; continue }
                    var r = 0.0, d = 0.0
                    for k in m.cellFaceRange(c) {
                        let f = Int(m.cellFaces[k])
                        let F = flux[f]
                        r += Int(m.owner[f]) == c ? -F : F
                        d += faceCoeff[f]
                    }
                    if transientRho { r -= (rho[c] - rhoOld[c]) * m.cellVolumes[c] / dt }
                    RH[c] = r; DG[c] = d
                }
            }
        }}
        let imbalance = Parallel.sum(nC) { range in var s = 0.0; for c in range where !solid[c] { s += abs(rhs[c]) }; return s }

        Ap.zero()
        Ap.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI where faceCoeff[f] != 0 {
                V[Int(g.upper[f])] -= faceCoeff[f]; V[Int(g.lower[f])] -= faceCoeff[f]
            }
            for c in 0..<nC { V[Int(diag[c])] = dgl[c] }
            if !anyDirichlet {
                // Soft pin of the reference cell removes the constant null space.
                let k = Int(diag[refCell])
                V[k] += V[k]
            }
        }
        for c in 0..<nC { pCorr[c] = 0 }
        pSolver.solve(Ap, x: &pCorr, b: rhs)

        // Correct face fluxes; boundary p' values for the gradient
        let pc = pCorr
        var pcb = [Double](repeating: 0, count: m.nBoundaryFaces)
        state.massFlux.withUnsafeMutableBufferPointer { mp in pcb.withUnsafeMutableBufferPointer { bp in
            let MF = SharedPtr(mp.baseAddress!), PB = SharedPtr(bp.baseAddress ?? UnsafeMutablePointer(bitPattern: 8)!)
            Parallel.forEach(g.nFaces) { range in
                for f in range {
                    let c = faceCoeff[f]
                    if f < nI {
                        if c != 0 { MF[f] -= c * (pc[Int(m.neighbour[f])] - pc[Int(m.owner[f])]) }
                    } else {
                        let P = Int(m.owner[f])
                        if c != 0 { MF[f] += c * pc[P]; PB[f - nI] = 0 } else { PB[f - nI] = pc[P] }
                    }
                }
            }
        }}
        // Cell velocity and pressure correction
        if correctVelocity {
            // as for p itself, a fluid cell must not see the solid neighbour's p' (held at 0):
            // without the mask every cell beside a solid gets a spurious correction into the wall
            let mask = hasSolids ? isInterfaceFace : nil
            Gradient.compute(g, pCorr, boundary: pcb, scheme: setup.methods.gradient, into: &gradPc, interface: mask)
            if setup.methods.gradient == .leastSquares && setup.methods.conservativePressureGradient {
                Gradient.conservative(g, pCorr, boundary: pcb, reconstruction: gradPc, into: &gradPScratch, interface: mask)
                swap(&gradPc, &gradPScratch)
            }
        }
        let gpc = gradPc
        let ax2 = m.twoDimensionalAxis
        let shift = anyDirichlet ? 0.0 : state.p[refCell] + urfP * pc[refCell]
        state.u.withUnsafeMutableBufferPointer { up in state.p.withUnsafeMutableBufferPointer { pp in
            let U = SharedPtr(up.baseAddress!), PP = SharedPtr(pp.baseAddress!)
            Parallel.forEach(nC) { range in
                for c in range {
                    if !solid[c] {
                        if correctVelocity {
                            var v = U[c] - D[c] * gpc[c]
                            if let ax = ax2 { v[ax] = 0 }
                            U[c] = v
                        }
                        PP[c] += urfP * pc[c]
                    }
                    PP[c] -= shift
                }
            }
        }}
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
        // orthotropic materials: conductivity along the face normal, k_n = Σ k_i n_i²
        let aniso = zoneMaterial.contains { $0.anisotropicConductivity != nil }
        @inline(__always) func kAlong(_ c: Int, _ f: Int) -> Double {
            guard aniso else { return kEff[c] }
            let mat = zoneMaterial[Int(m.cellZone[c])]
            guard mat.anisotropicConductivity != nil else { return kEff[c] }
            return kEff[c] - state.conductivity[c] + mat.conductivity(along: normalized(m.faceAreas[f]))
        }
        for f in 0..<nI {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            let w = g.weight[f]
            // harmonic mean (exact for conjugate interfaces)
            gamma[f] = 1 / ((1 - w) / max(kAlong(P, f), 1e-300) + w / max(kAlong(N, f), 1e-300))
            cpF[f] = w * state.cp[P] + (1 - w) * state.cp[N]
        }
        for f in nI..<g.nFaces {
            let P = Int(m.owner[f])
            let bf = f - nI
            var ke = kAlong(P, f)
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
        let asm = TransportAssembler(geo: g, nonOrthLimit: setup.methods.nonOrthogonalLimit ?? g.automaticNonOrthogonalLimit)
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
            let asm = TransportAssembler(geo: g, nonOrthLimit: setup.methods.nonOrthogonalLimit ?? g.automaticNonOrthogonalLimit)
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
    /// Wall-clock seconds per phase (CURLEW_PROFILE=1 prints a summary from the CLI).
    public static var profile: [String: Double] = [:]
    static let profiling = ProcessInfo.processInfo.environment["CURLEW_PROFILE"] != nil
    @inline(__always) func timed<T>(_ name: String, _ body: () -> T) -> T {
        guard PressureBasedSolver.profiling else { return body() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = body()
        PressureBasedSolver.profile[name, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - t0) * 1e-9
        return r
    }

    @discardableResult
    public func iterate() -> [String: Double] {
        let urfU = setup.controls.urf.momentum
        let urfP = setup.methods.coupling == .simple ? setup.controls.urf.pressure : max(setup.controls.urf.pressure, 1.0)
        timed("gradients") { computeGradients() }
        timed("properties") { updateProperties() }
        timed("walls") { if setup.models.viscous.isTurbulent { updateWallFunctions() } else { updateLaminarWalls() } }
        uPrev = state.u
        massFluxPrev = state.massFlux
        let resU = timed("momentum") { solveMomentum(urf: urfU) }
        timed("fluxes") { computeMassFluxes(urf: urfU) }
        let piso = setup.methods.coupling == .piso
        var uBefore = state.u
        let imbalance = timed("pressure") { correctPressure(urfP: piso ? 1.0 : urfP) }
        if piso {
            for _ in 0..<max(setup.methods.pisoCorrectors, 1) {
                var du = state.u
                for c in 0..<du.count { du[c] -= uBefore[c] }
                pisoNeighbourCorrection(du)
                uBefore = state.u
                _ = correctPressure(urfP: 1)
            }
        }
        timed("boundaries") { updateFlowBoundaries() }

        var r: [String: Double] = [:]
        r["continuity"] = residuals.scaleContinuity(imbalance)
        let vnames = ["x-velocity", "y-velocity", "z-velocity"]
        for k in 0..<3 where k != mesh.twoDimensionalAxis { r[vnames[k]] = resU[k] }
        if setup.models.energy { r["energy"] = timed("energy") { solveEnergy() } }
        if setup.models.viscous.isTurbulent {
            timed("gradients") { computeGradients() }
            for (k, v) in timed("turbulence") { solveTurbulence() } { r[k] = v }
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
            let r = isDensityBased ? iterateDensityBased() : iterate()
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
            if isDensityBased {
                last = densityBasedTimeStep()
                total += 1
                progress?(self, last)
                if last.values.contains(where: { !$0.isFinite }) {
                    log("Divergence detected at time step \(state.timeStep).")
                    return RunResult(iterations: total, converged: false, diverged: true, stopped: false)
                }
            }
            for _ in 0..<(isDensityBased ? 0 : setup.run.maxIterationsPerTimeStep) {
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
