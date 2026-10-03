import Foundation
import CurlewMesh
import CurlewLinear

/// Solution initialization: hybrid (potential-flow Laplace solves) and standard.
enum Initialization {
    static func run(_ s: PressureBasedSolver) throws {
        let setup = s.setup
        let m = s.mesh, g = s.geo
        let st = s.state
        let nC = m.nCells, nI = g.nInternal
        let exprs = s.exprs
        st.iteration = 0; st.time = 0; st.timeStep = 0
        st.uOld = []; st.uOldOld = []; st.massFluxOld = []; st.massFluxOldOld = []
        st.TOld = []; st.rhoOld = []
        st.meanU = []; st.meanP = []; st.samples = 0
        s.residuals = ResidualHistory()
        s.reportHistory = ReportHistory()

        // Averages over inlet faces for turbulence/temperature defaults
        var inletArea = 0.0, avgT = 0.0, avgK = 0.0, avgOm = 0.0, avgEps = 0.0, avgNut = 0.0
        var tArea = 0.0, tSum = 0.0
        for f in nI..<g.nFaces {
            let bf = f - nI
            let a = m.faceAreaMag[f]
            switch s.bc.kind[bf] {
            case .velocityInlet, .pressureInlet, .farField:
                inletArea += a
                avgT += a * s.bc.thermal.value[bf]
                avgK += a * s.bc.k.value[bf]; avgOm += a * s.bc.omega.value[bf]
                avgEps += a * s.bc.epsilon.value[bf]; avgNut += a * s.bc.nuTilda.value[bf]
            default: break
            }
            if s.bc.thermal.kind[bf] == .fixedValue { tArea += a; tSum += a * s.bc.thermal.value[bf] }
        }
        let ini = setup.initialization
        func q(_ v: Quantity, _ c: Vec3) -> Double {
            switch v { case .constant(let d): return d
            case .expression(let e): return (try? Expr(e, named: exprs).value(x: c.x, y: c.y, z: c.z, t: 0)) ?? 0 }
        }

        if ini.method == .standard {
            var u0: Vec3? = nil, p0: Double? = nil, T0: Double? = nil
            var k0 = ini.k, om0 = ini.omega, eps0 = ini.epsilon, nut0 = ini.modifiedTurbulentViscosity
            if !ini.computeFrom.isEmpty, let zi = m.boundaryZones.firstIndex(where: { $0.name == ini.computeFrom }) {
                let z = m.boundaryZones[zi]
                if let f = z.faceRange.first {
                    let bf = f - nI
                    u0 = s.bc.uSpec[bf]; p0 = s.bc.pSpec[bf]; T0 = s.bc.thermal.value[bf]
                    k0 = s.bc.k.value[bf]; om0 = s.bc.omega.value[bf]; eps0 = s.bc.epsilon.value[bf]; nut0 = s.bc.nuTilda.value[bf]
                }
            }
            for c in 0..<nC {
                let cc = m.cellCentres[c]
                st.u[c] = u0 ?? Vec3(q(ini.velocity[0], cc), q(ini.velocity[1], cc), q(ini.velocity[2], cc))
                st.p[c] = p0 ?? q(ini.gaugePressure, cc)
                st.T[c] = T0 ?? q(ini.temperature, cc)
                st.k[c] = k0; st.omega[c] = om0; st.epsilon[c] = eps0; st.nuTilda[c] = nut0
            }
        } else {
            try hybrid(s)
            let Tavg = inletArea > 0 ? avgT / inletArea : (tArea > 0 ? tSum / tArea : q(ini.temperature, .zero))
            for c in 0..<nC {
                st.T[c] = Tavg
                st.k[c] = inletArea > 0 ? avgK / inletArea : ini.k
                st.omega[c] = inletArea > 0 ? avgOm / inletArea : ini.omega
                st.epsilon[c] = inletArea > 0 ? avgEps / inletArea : ini.epsilon
                st.nuTilda[c] = inletArea > 0 ? avgNut / inletArea : ini.modifiedTurbulentViscosity
            }
        }
        for c in 0..<nC where s.isSolidCell[c] { st.u[c] = .zero }
        if let ax = m.twoDimensionalAxis { for c in 0..<nC { st.u[c][ax] = 0 } }
        // scalars
        for si in 0..<st.scalars.count { for c in 0..<nC { st.scalars[si][c] = 0 } }

        // Patches
        for patch in ini.patches {
            for c in 0..<nC where inside(patch, m.cellCentres[c]) {
                let v = q(patch.value, m.cellCentres[c])
                switch patch.field {
                case "pressure": st.p[c] = v
                case "x-velocity": st.u[c].x = v
                case "y-velocity": st.u[c].y = v
                case "z-velocity": st.u[c].z = v
                case "temperature": st.T[c] = v
                case "k", "turbulent-kinetic-energy": st.k[c] = v
                case "omega", "specific-dissipation-rate": st.omega[c] = v
                case "epsilon", "turbulent-dissipation-rate": st.epsilon[c] = v
                default:
                    if let si = setup.models.passiveScalars.firstIndex(where: { $0.name == patch.field }) { st.scalars[si][c] = v }
                }
            }
        }

        // Turbulent viscosity and boundary values
        s.updateProperties()
        for bf in 0..<st.nBoundary {
            let P = Int(m.owner[bf + nI])
            st.bT[bf] = s.bc.thermal.kind[bf] == .fixedValue ? s.bc.thermal.value[bf] : st.T[P]
            st.bK[bf] = s.bc.k.kind[bf] == .fixedValue ? s.bc.k.value[bf] : st.k[P]
            st.bOmega[bf] = s.bc.omega.kind[bf] == .fixedValue ? s.bc.omega.value[bf] : st.omega[P]
            st.bEpsilon[bf] = s.bc.epsilon.kind[bf] == .fixedValue ? s.bc.epsilon.value[bf] : st.epsilon[P]
            st.bNuTilda[bf] = s.bc.nuTilda.kind[bf] == .fixedValue ? s.bc.nuTilda.value[bf] : st.nuTilda[P]
            for si in 0..<st.scalars.count {
                st.bScalars[si][bf] = s.bc.scalars[si].kind[bf] == .fixedValue ? s.bc.scalars[si].value[bf] : st.scalars[si][P]
            }
        }
        if setup.models.viscous.isTurbulent { s.initTurbulentViscosity() } else { for c in 0..<nC { st.muT[c] = 0 } }
        s.updateFlowBoundaries()
        s.computeGradients()
        // Face fluxes from the initial velocity
        for f in 0..<g.nFaces {
            let P = Int(m.owner[f])
            if f < nI {
                let N = Int(m.neighbour[f])
                if s.isInterfaceFace[f] || s.isSolidCell[P] || s.isSolidCell[N] { st.massFlux[f] = 0; continue }
                let w = g.weight[f]
                st.massFlux[f] = (w * st.rho[P] + (1 - w) * st.rho[N]) * dot(w * st.u[P] + (1 - w) * st.u[N], m.faceAreas[f])
            } else {
                let bf = f - nI
                switch s.bc.kind[bf] {
                case .empty, .wall, .slipWall, .symmetry: st.massFlux[f] = 0
                default: st.massFlux[f] = s.isSolidCell[P] ? 0 : st.rho[P] * dot(st.bU[bf], m.faceAreas[f])
                }
            }
        }
        s.muWall = s.walls.map { st.mu[$0.cell] }
        s.log("Initialization complete (\(ini.method.rawValue)).")
    }

    static func inside(_ p: PatchSettings, _ c: Vec3) -> Bool {
        let a = p.parameters
        switch p.region {
        case .box:
            guard a.count >= 6 else { return false }
            return c.x >= a[0] && c.y >= a[1] && c.z >= a[2] && c.x <= a[3] && c.y <= a[4] && c.z <= a[5]
        case .sphere:
            guard a.count >= 4 else { return false }
            return norm(c - Vec3(a[0], a[1], a[2])) <= a[3]
        case .cylinder:
            guard a.count >= 7 else { return false }
            let p0 = Vec3(a[0], a[1], a[2]), p1 = Vec3(a[3], a[4], a[5])
            let ax = p1 - p0, L2 = dot(ax, ax)
            guard L2 > 0 else { return false }
            let t = dot(c - p0, ax) / L2
            guard t >= 0 && t <= 1 else { return false }
            return norm(c - (p0 + t * ax)) <= a[6]
        }
    }

    /// Potential-flow velocity and Laplace pressure (Fluent's hybrid initialization).
    static func hybrid(_ s: PressureBasedSolver) throws {
        let m = s.mesh, g = s.geo, st = s.state
        let nC = m.nCells, nI = g.nInternal
        let diag = g.pattern.diag
        let A = SparseMatrix(pattern: g.pattern)
        var b = [Double](repeating: 0, count: nC)
        var dirichlet = false
        var phiB = [Double](repeating: 0, count: m.nBoundaryFaces)
        A.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                if s.isInterfaceFace[f] || s.isSolidCell[P] || s.isSolidCell[N] { continue }
                let c = g.orthCoeff[f]
                V[Int(diag[P])] += c; V[Int(diag[N])] += c
                V[Int(g.upper[f])] -= c; V[Int(g.lower[f])] -= c
            }
            for f in nI..<g.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                if s.isSolidCell[P] { continue }
                switch s.bc.kind[bf] {
                case .velocityInlet:
                    b[P] += dot(s.bc.uSpec[bf], m.faceAreas[f])
                case .pressureOutlet, .pressureInlet, .outflow:
                    let c = g.orthCoeff[f]
                    V[Int(diag[P])] += c
                    phiB[bf] = 0
                    dirichlet = true
                case .farField:
                    let c = g.orthCoeff[f]
                    V[Int(diag[P])] += c
                    phiB[bf] = dot(s.bc.uSpec[bf], m.faceCentres[f])
                    b[P] += c * phiB[bf]
                    dirichlet = true
                default: break
                }
            }
            for c in 0..<nC where s.isSolidCell[c] { V[Int(diag[c])] = 1; b[c] = 0 }
            if !dirichlet { let k = Int(diag[s.refCell]); V[k] += V[k] }
        }
        var phi = [Double](repeating: 0, count: nC)
        let solver = LinearSolver(LinearSolverSettings(method: .amgCG, cycle: .k, relTol: 1e-6, maxIterations: 200))
        let hasInflow = s.bc.kind.contains(.velocityInlet) || s.bc.kind.contains(.farField)
        if hasInflow { solver.solve(A, x: &phi, b: b) }
        // u = grad(phi); boundary phi: Dirichlet faces fixed, others extrapolated
        var grad: [Vec3] = []
        for pass in 0..<2 {
            for f in nI..<g.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                switch s.bc.kind[bf] {
                case .pressureOutlet, .pressureInlet, .outflow, .farField: break
                case .velocityInlet: phiB[bf] = phi[P] + dot(s.bc.uSpec[bf], g.delta[f])
                default: phiB[bf] = pass == 0 ? phi[P] : phi[P] + dot(grad[P], g.delta[f] - dot(g.delta[f], normalized(m.faceAreas[f])) * normalized(m.faceAreas[f]))
                }
            }
            Gradient.compute(g, phi, boundary: phiB, scheme: .leastSquares, into: &grad)
        }
        for c in 0..<nC { st.u[c] = s.isSolidCell[c] ? .zero : grad[c] }

        // Pressure: Laplace with Dirichlet values on pressure boundaries
        A.zero()
        for i in 0..<nC { b[i] = 0 }
        var anyP = false
        A.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                if s.isInterfaceFace[f] || s.isSolidCell[P] || s.isSolidCell[N] { continue }
                let c = g.orthCoeff[f]
                V[Int(diag[P])] += c; V[Int(diag[N])] += c
                V[Int(g.upper[f])] -= c; V[Int(g.lower[f])] -= c
            }
            for f in nI..<g.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                if s.isSolidCell[P] { continue }
                if [.pressureOutlet, .pressureInlet, .farField].contains(s.bc.kind[bf]) {
                    let c = g.orthCoeff[f]
                    V[Int(diag[P])] += c
                    b[P] += c * s.bc.pSpec[bf]
                    anyP = true
                }
            }
            for c in 0..<nC where s.isSolidCell[c] { V[Int(diag[c])] = 1 }
            if !anyP { let k = Int(diag[s.refCell]); V[k] += V[k] }
        }
        var p = [Double](repeating: 0, count: nC)
        if anyP { solver.solve(A, x: &p, b: b) }
        st.p = p
    }
}
