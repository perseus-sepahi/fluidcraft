import Foundation
import CurlewMesh

/// Primitive state (rho, u, p) of an ideal gas.
struct Prim {
    var rho: Double
    var u: Vec3
    var p: Double
}

/// Conservative-variable storage for the density-based (coupled, explicit) solver.
final class DensityBasedState {
    var rho: [Double]
    var mom: [Vec3]
    var energy: [Double]
    var gamma: Double
    var R: Double
    var residualScale: [Double] = [0, 0, 0, 0, 0]
    var scaleSamples = 0
    init(n: Int, gamma: Double, R: Double) {
        rho = [Double](repeating: 1, count: n)
        mom = [Vec3](repeating: .zero, count: n)
        energy = [Double](repeating: 1, count: n)
        self.gamma = gamma; self.R = R
    }
}

extension PressureBasedSolver {
    // MARK: Gas properties

    var gasGamma: Double {
        let mat = zoneMaterial.first { $0.kind == .fluid } ?? Material(name: "air")
        let R = mat.gasConstant
        return mat.specificHeat / max(mat.specificHeat - R, 1e-12)
    }
    var gasR: Double { (zoneMaterial.first { $0.kind == .fluid } ?? Material(name: "air")).gasConstant }

    /// Flux of the Euler equations through unit normal n for primitive state w: (mass, momentum, energy).
    @inline(__always) static func eulerFlux(_ w: Prim, _ n: Vec3, gamma: Double) -> (Double, Vec3, Double) {
        let vn = dot(w.u, n)
        let H = gamma / (gamma - 1) * w.p / w.rho + 0.5 * lengthSquared(w.u)
        let mf = w.rho * vn
        return (mf, mf * w.u + w.p * n, mf * H)
    }

    /// Roe flux-difference splitting with Harten's entropy fix (per unit area).
    static func roeFlux(_ L: Prim, _ Rr: Prim, _ n: Vec3, gamma g: Double) -> (Double, Vec3, Double) {
        let (fl0, fl1, fl2) = eulerFlux(L, n, gamma: g)
        let (fr0, fr1, fr2) = eulerFlux(Rr, n, gamma: g)
        let HL = g / (g - 1) * L.p / L.rho + 0.5 * lengthSquared(L.u)
        let HR = g / (g - 1) * Rr.p / Rr.rho + 0.5 * lengthSquared(Rr.u)
        let sR = sqrt(Rr.rho / L.rho)
        let inv = 1 / (1 + sR)
        let u = (L.u + sR * Rr.u) * inv
        let H = (HL + sR * HR) * inv
        let q2 = lengthSquared(u)
        let c2 = max((g - 1) * (H - 0.5 * q2), 1e-12)
        let c = sqrt(c2)
        let rho = sqrt(L.rho * Rr.rho)
        let vn = dot(u, n)
        let dRho = Rr.rho - L.rho, dP = Rr.p - L.p, dU = Rr.u - L.u
        let dVn = dot(dU, n)
        var l1 = abs(vn - c), l2 = abs(vn), l3 = abs(vn + c)
        let delta = 0.1 * c
        if l1 < delta { l1 = (l1 * l1 + delta * delta) / (2 * delta) }
        if l3 < delta { l3 = (l3 * l3 + delta * delta) / (2 * delta) }
        if l2 < delta { l2 = (l2 * l2 + delta * delta) / (2 * delta) }
        let a1 = (dP - rho * c * dVn) / (2 * c2)
        let a2 = dRho - dP / c2
        let a3 = (dP + rho * c * dVn) / (2 * c2)
        let shear = rho * (dU - dVn * n)
        // dissipation
        var d0 = l1 * a1 + l2 * a2 + l3 * a3
        var d1 = l1 * a1 * (u - c * n) + l2 * a2 * u + l3 * a3 * (u + c * n) + l2 * shear
        var d2 = l1 * a1 * (H - c * vn) + l2 * a2 * 0.5 * q2 + l3 * a3 * (H + c * vn) + l2 * (dot(u, shear))
        d0 *= 0.5; d1 *= 0.5; d2 *= 0.5
        return (0.5 * (fl0 + fr0) - d0, 0.5 * (fl1 + fr1) - d1, 0.5 * (fl2 + fr2) - d2)
    }

    /// AUSM+ (Liou 1996) flux per unit area.
    static func ausmFlux(_ L: Prim, _ Rr: Prim, _ n: Vec3, gamma g: Double) -> (Double, Vec3, Double) {
        let HL = g / (g - 1) * L.p / L.rho + 0.5 * lengthSquared(L.u)
        let HR = g / (g - 1) * Rr.p / Rr.rho + 0.5 * lengthSquared(Rr.u)
        let cL = sqrt(g * L.p / L.rho), cR = sqrt(g * Rr.p / Rr.rho)
        let c = 0.5 * (cL + cR)
        let ML = dot(L.u, n) / c, MR = dot(Rr.u, n) / c
        func mPlus(_ M: Double) -> Double { abs(M) >= 1 ? 0.5 * (M + abs(M)) : 0.25 * (M + 1) * (M + 1) + 0.125 * (M * M - 1) * (M * M - 1) }
        func mMinus(_ M: Double) -> Double { abs(M) >= 1 ? 0.5 * (M - abs(M)) : -0.25 * (M - 1) * (M - 1) - 0.125 * (M * M - 1) * (M * M - 1) }
        func pPlus(_ M: Double) -> Double { abs(M) >= 1 ? (M > 0 ? 1 : 0) : 0.25 * (M + 1) * (M + 1) * (2 - M) + 0.1875 * M * (M * M - 1) * (M * M - 1) }
        func pMinus(_ M: Double) -> Double { abs(M) >= 1 ? (M < 0 ? 1 : 0) : 0.25 * (M - 1) * (M - 1) * (2 + M) - 0.1875 * M * (M * M - 1) * (M * M - 1) }
        let m = mPlus(ML) + mMinus(MR)
        let p = pPlus(ML) * L.p + pMinus(MR) * Rr.p
        let mdot = c * (m > 0 ? m * L.rho : m * Rr.rho)
        let up = m > 0 ? L.u : Rr.u
        let H = m > 0 ? HL : HR
        return (mdot, mdot * up + p * n, mdot * H)
    }

    // MARK: Conversions

    func dbPrim(_ db: DensityBasedState, _ c: Int) -> Prim {
        let r = max(db.rho[c], 1e-12)
        let u = db.mom[c] / r
        let p = max((db.gamma - 1) * (db.energy[c] - 0.5 * r * lengthSquared(u)), 1e-6)
        return Prim(rho: r, u: u, p: p)
    }

    func dbSetFromPrim(_ db: DensityBasedState, _ c: Int, _ w: Prim) {
        db.rho[c] = w.rho
        db.mom[c] = w.rho * w.u
        db.energy[c] = w.p / (db.gamma - 1) + 0.5 * w.rho * lengthSquared(w.u)
    }

    /// Initialise conservative variables from the FlowState (after Initialization.run).
    func dbInitialize() {
        let db = DensityBasedState(n: mesh.nCells, gamma: gasGamma, R: gasR)
        let pop = setup.general.operatingPressure
        // Hybrid initialization is a pressure-based concept: start from the far-field / inlet free stream instead.
        var w0: Prim? = nil
        if setup.initialization.method == .hybrid {
            let nI = geo.nInternal
            for (zi, z) in mesh.boundaryZones.enumerated() where z.kind == .pressureFarField || z.kind == .pressureInlet || z.kind == .velocityInlet {
                if let f = z.faceRange.first {
                    w0 = freestreamPrim(zone: zi, face: f - nI)
                    break
                }
            }
        }
        for c in 0..<mesh.nCells {
            if let w = w0 { dbSetFromPrim(db, c, w); continue }
            let p = pop + state.p[c]
            let T = max(state.T[c], 1)
            dbSetFromPrim(db, c, Prim(rho: p / (db.R * T), u: state.u[c], p: p))
        }
        // patches still apply on top of a hybrid (free-stream) start
        if setup.initialization.method == .hybrid && !setup.initialization.patches.isEmpty {
            for patch in setup.initialization.patches {
                for c in 0..<mesh.nCells where Initialization.inside(patch, mesh.cellCentres[c]) {
                    var w = dbPrim(db, c)
                    let v = patch.value.constantValue ?? 0
                    let T = w.p / (w.rho * db.R)
                    switch patch.field {
                    case "pressure": w.p = pop + v; w.rho = w.p / (db.R * T)
                    case "temperature": w.rho = w.p / (db.R * v)
                    case "x-velocity": w.u.x = v
                    case "y-velocity": w.u.y = v
                    case "z-velocity": w.u.z = v
                    default: break
                    }
                    dbSetFromPrim(db, c, w)
                }
            }
        }
        densityState = db
        dbSyncFlowState()
    }

    /// Free-stream primitive state for far-field and pressure-inlet zones.
    func freestreamPrim(zone zi: Int, face bf: Int) -> Prim {
        let s = bc.zoneSettings[zi]
        let g = gasGamma, R = gasR
        let pop = setup.general.operatingPressure
        let T = s.temperature.constantValue ?? 300
        switch s.type {
        case .pressureFarField:
            let p = pop + (s.gaugePressure.constantValue ?? 0)
            let c = sqrt(g * R * T)
            let dir = normalized(Vec3(s.flowDirection[0], s.flowDirection[1], s.flowDirection[2]))
            return Prim(rho: p / (R * T), u: s.machNumber * c * dir, p: p)
        case .pressureInlet:
            let p0 = pop + (s.gaugePressure.constantValue ?? 0)
            let M = max(s.machNumber, 0.05)
            let fac = 1 + 0.5 * (g - 1) * M * M
            let Ts = T / fac
            let ps = p0 / pow(fac, g / (g - 1))
            let n = normalized(mesh.faceAreas[bf + geo.nInternal])
            return Prim(rho: ps / (R * Ts), u: -M * sqrt(g * R * Ts) * n, p: ps)
        default:
            let p = pop + (s.gaugePressure.constantValue ?? 0)
            return Prim(rho: p / (R * T), u: bc.uSpec[bf], p: p)
        }
    }

    // MARK: Boundary ghost states

    /// Ghost (right) state for boundary face `f` given the interior state at the face.
    func dbGhost(_ f: Int, interior wi: Prim) -> Prim? {
        let nI = geo.nInternal
        let bf = f - nI
        let n = normalized(mesh.faceAreas[f])
        let g = gasGamma, R = gasR
        let pop = setup.general.operatingPressure
        let zi = Int(bc.zone[bf])
        let s = bc.zoneSettings[zi]
        let viscous = setup.models.viscous != .inviscid
        switch bc.kind[bf] {
        case .empty:
            return nil
        case .symmetry, .slipWall:
            var w = wi; w.u = wi.u - 2 * dot(wi.u, n) * n; return w
        case .wall:
            var w = wi
            if viscous { w.u = 2 * bc.uSpec[bf] - wi.u } else { w.u = wi.u - 2 * dot(wi.u, n) * n }
            return w
        case .velocityInlet:
            let T = bc.thermal.value[bf]
            return Prim(rho: wi.p / (R * T), u: bc.uSpec[bf], p: wi.p)
        case .pressureOutlet, .outflow:
            let ci = sqrt(g * wi.p / wi.rho)
            if dot(wi.u, n) >= ci { return wi }          // supersonic outflow: everything extrapolated
            let p = pop + bc.pSpec[bf]
            var w = wi
            if dot(wi.u, n) < 0 { w.rho = p / (R * bc.thermal.value[bf]) }  // backflow temperature
            w.p = p
            return w
        case .pressureInlet:
            let p0 = pop + bc.pSpec[bf]
            let T0 = bc.thermal.value[bf]
            if s.machNumber > 1 {
                return freestreamPrim(zone: zi, face: bf)
            }
            // subsonic: Mach from the interior state, statics from total conditions, flow normal to the boundary
            let ci = sqrt(g * wi.p / wi.rho)
            let M = min(max(-dot(wi.u, n) / ci, 0), 0.99)
            let fac = 1 + 0.5 * (g - 1) * M * M
            let Ts = T0 / fac
            let ps = p0 / pow(fac, g / (g - 1))
            return Prim(rho: ps / (R * Ts), u: -M * sqrt(g * R * Ts) * n, p: ps)
        case .farField:
            let fs = freestreamPrim(zone: zi, face: bf)
            let cInf = sqrt(g * fs.p / fs.rho), cInt = sqrt(g * wi.p / wi.rho)
            let vnInf = dot(fs.u, n), vnInt = dot(wi.u, n)
            if vnInf <= -cInf { return fs }                  // supersonic inflow
            if vnInt >= cInt { return wi }                   // supersonic outflow
            let rPlus = vnInt + 2 * cInt / (g - 1)
            let rMinus = vnInf - 2 * cInf / (g - 1)
            let vn = 0.5 * (rPlus + rMinus)
            let cb = 0.25 * (g - 1) * (rPlus - rMinus)
            let ref = vn < 0 ? fs : wi
            let sEnt = ref.p / pow(ref.rho, g)
            let rho = pow(cb * cb / (g * sEnt), 1 / (g - 1))
            let ut = ref.u - dot(ref.u, n) * n
            return Prim(rho: rho, u: ut + vn * n, p: rho * cb * cb / g)
        }
    }

    // MARK: Residual evaluation

    /// Spatial residual R(U) (outflow positive) for every cell: mass, momentum, energy.
    func dbResidual(_ db: DensityBasedState, mass: inout [Double], mom: inout [Vec3], ene: inout [Double], localDt: inout [Double], cfl: Double) {
        let m = mesh, g = geo
        let nC = m.nCells, nI = g.nInternal
        let gam = db.gamma, R = db.R
        let viscous = setup.models.viscous != .inviscid
        // primitives
        var W = [Prim](repeating: Prim(rho: 1, u: .zero, p: 1), count: nC)
        for c in 0..<nC { W[c] = dbPrim(db, c) }
        // boundary primitive values (ghost/face) for gradients
        var bRho = [Double](repeating: 0, count: m.nBoundaryFaces), bP = bRho
        var bU = [Vec3](repeating: .zero, count: m.nBoundaryFaces)
        var ghosts = [Prim?](repeating: nil, count: m.nBoundaryFaces)
        for f in nI..<g.nFaces {
            let bf = f - nI
            let P = Int(m.owner[f])
            let gst = dbGhost(f, interior: W[P])
            ghosts[bf] = gst
            let wb = gst.map { Prim(rho: 0.5 * ($0.rho + W[P].rho), u: 0.5 * ($0.u + W[P].u), p: 0.5 * ($0.p + W[P].p)) } ?? W[P]
            bRho[bf] = wb.rho; bU[bf] = wb.u; bP[bf] = wb.p
        }
        // gradients (least squares) of rho, u, p
        let rhoC = W.map(\.rho), pC = W.map(\.p), uC = W.map(\.u)
        var gRho: [Vec3] = [], gP: [Vec3] = [], gU: [[Vec3]] = [[], [], []]
        var scratch: [Double] = [], scratchB: [Double] = []
        let secondOrder = setup.methods.momentum != .firstOrderUpwind
        if secondOrder || viscous {
            Gradient.compute(g, rhoC, boundary: bRho, scheme: .leastSquares, into: &gRho)
            Gradient.compute(g, pC, boundary: bP, scheme: .leastSquares, into: &gP)
            Gradient.compute(g, uC, boundary: bU, scheme: .leastSquares, into: &gU, scratch: &scratch, scratchB: &scratchB)
        }
        // Venkatakrishnan limiters per cell (rho, u, v, w, p)
        var lim = [SIMD8<Double>](repeating: SIMD8<Double>(repeating: 1), count: secondOrder ? nC : 0)
        if secondOrder {
            var lo = [SIMD8<Double>](repeating: .zero, count: nC), hi = lo
            func pack(_ w: Prim) -> SIMD8<Double> { SIMD8(w.rho, w.u.x, w.u.y, w.u.z, w.p, 0, 0, 0) }
            for c in 0..<nC { lo[c] = pack(W[c]); hi[c] = lo[c] }
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                let a = pack(W[P]), b = pack(W[N])
                lo[P] = pointwiseMin(lo[P], b); hi[P] = pointwiseMax(hi[P], b)
                lo[N] = pointwiseMin(lo[N], a); hi[N] = pointwiseMax(hi[N], a)
            }
            // global ranges for the epsilon term
            var gmin = SIMD8<Double>(repeating: .infinity), gmax = SIMD8<Double>(repeating: -.infinity)
            for c in 0..<nC { gmin = pointwiseMin(gmin, lo[c]); gmax = pointwiseMax(gmax, hi[c]) }
            let range = gmax - gmin
            let eps2 = (0.05 * range) * (0.05 * range) + SIMD8<Double>(repeating: 1e-30)
            func vk(_ d1: Double, _ d2: Double, _ e2: Double) -> Double {
                let num = (d1 * d1 + e2) * d2 + 2 * d2 * d2 * d1
                let den = d2 * (d1 * d1 + 2 * d2 * d2 + d1 * d2 + e2)
                return abs(den) > 1e-300 ? min(num / den, 1) : 1
            }
            for f in 0..<g.nFaces where !g.isEmptyFace[f] {
                let cells = f < nI ? [Int(m.owner[f]), Int(m.neighbour[f])] : [Int(m.owner[f])]
                for c in cells {
                    let r = m.faceCentres[f] - m.cellCentres[c]
                    let d2 = SIMD8<Double>(dot(gRho[c], r), dot(gU[0][c], r), dot(gU[1][c], r), dot(gU[2][c], r), dot(gP[c], r), 0, 0, 0)
                    let w0 = pack(W[c])
                    for k in 0..<5 {
                        let dd = d2[k]
                        if dd > 1e-300 { lim[c][k] = min(lim[c][k], vk(hi[c][k] - w0[k], dd, eps2[k])) }
                        else if dd < -1e-300 { lim[c][k] = min(lim[c][k], vk(lo[c][k] - w0[k], dd, eps2[k])) }
                    }
                }
            }
        }
        @inline(__always) func reconstruct(_ c: Int, _ f: Int) -> Prim {
            var w = W[c]
            guard secondOrder else { return w }
            let r = m.faceCentres[f] - m.cellCentres[c]
            let l = lim[c]
            w.rho += l[0] * dot(gRho[c], r)
            w.u += Vec3(l[1] * dot(gU[0][c], r), l[2] * dot(gU[1][c], r), l[3] * dot(gU[2][c], r))
            w.p += l[4] * dot(gP[c], r)
            if w.rho <= 0 || w.p <= 0 { return W[c] }
            return w
        }
        let roe = setup.methods.flux == .roe
        for c in 0..<nC { mass[c] = 0; mom[c] = .zero; ene[c] = 0; localDt[c] = 0 }
        var spectral = [Double](repeating: 0, count: nC)
        let mu = state.mu, kc = state.conductivity
        func viscousFlux(_ f: Int, _ P: Int, _ N: Int?, _ wb: Prim?) -> (Vec3, Double) {
            // laminar stress and heat flux through face f (owner -> neighbour / outward)
            let S = m.faceAreas[f]
            let d = g.delta[f]
            let dn = max(dot(d, normalized(S)), 1e-300)
            var gu = [Vec3](repeating: .zero, count: 3)
            var uf: Vec3, Tf: Double, gT: Vec3
            let TP = W[P].p / (W[P].rho * R)
            if let N {
                let w = g.weight[f]
                let eHat = normalized(d), dl = norm(d)
                for k in 0..<3 {
                    let avg = w * gU[k][P] + (1 - w) * gU[k][N]
                    gu[k] = avg + ((W[N].u[k] - W[P].u[k]) / dl - dot(avg, eHat)) * eHat
                }
                uf = w * W[P].u + (1 - w) * W[N].u
                let TN = W[N].p / (W[N].rho * R)
                Tf = w * TP + (1 - w) * TN
                gT = (TN - TP) / dl * eHat
            } else {
                guard let wb else { return (.zero, 0) }
                let nH = normalized(S)
                let uw = 0.5 * (wb.u + W[P].u)
                for k in 0..<3 { gu[k] = gU[k][P] + ((uw[k] - W[P].u[k]) / dn - dot(gU[k][P], nH)) * nH }
                uf = uw
                let bf = f - nI
                if bc.kind[bf] == .wall && bc.thermal.kind[bf] == .fixedValue {
                    Tf = bc.thermal.value[bf]; gT = (Tf - TP) / dn * nH
                } else if bc.kind[bf] == .wall {
                    Tf = TP; gT = .zero      // adiabatic
                } else {
                    let Tb = wb.p / (wb.rho * R)
                    Tf = 0.5 * (Tb + TP); gT = (Tf - TP) / dn * nH
                }
            }
            let muF = N.map { g.weight[f] * mu[P] + (1 - g.weight[f]) * mu[$0] } ?? mu[P]
            let kF = N.map { g.weight[f] * kc[P] + (1 - g.weight[f]) * kc[$0] } ?? kc[P]
            let divu = gu[0].x + gu[1].y + gu[2].z
            // tau . S
            var t = Vec3.zero
            for i in 0..<3 {
                var s = 0.0
                for j in 0..<3 {
                    let dij = gu[j][i] + gu[i][j]     // du_j/dx_i + du_i/dx_j
                    s += (dij - (i == j ? 2.0 / 3.0 * divu : 0)) * S[j]
                }
                t[i] = muF * s
            }
            _ = Tf
            return (t, dot(t, uf) + kF * dot(gT, S))
        }
        // interior faces
        for f in 0..<nI {
            let P = Int(m.owner[f]), N = Int(m.neighbour[f])
            let Sm = m.faceAreaMag[f]
            let n = m.faceAreas[f] / Sm
            let L = reconstruct(P, f), Rr = reconstruct(N, f)
            let (f0, f1, f2) = roe ? PressureBasedSolver.roeFlux(L, Rr, n, gamma: gam) : PressureBasedSolver.ausmFlux(L, Rr, n, gamma: gam)
            var fm = f1 * Sm, fe = f2 * Sm
            if viscous {
                let (tv, qv) = viscousFlux(f, P, N, nil)
                fm -= tv; fe -= qv
            }
            mass[P] += f0 * Sm; mom[P] += fm; ene[P] += fe
            mass[N] -= f0 * Sm; mom[N] -= fm; ene[N] -= fe
            state.massFlux[f] = f0 * Sm
            let lam = (abs(dot(0.5 * (W[P].u + W[N].u), n)) + 0.5 * (sqrt(gam * W[P].p / W[P].rho) + sqrt(gam * W[N].p / W[N].rho))) * Sm
            spectral[P] += lam; spectral[N] += lam
            if viscous {
                let vis = 2 * max(mu[P] / W[P].rho, mu[N] / W[N].rho) * Sm * Sm / max(min(m.cellVolumes[P], m.cellVolumes[N]), 1e-300) * gam
                spectral[P] += vis; spectral[N] += vis
            }
        }
        // boundary faces
        for f in nI..<g.nFaces {
            let bf = f - nI
            guard let gst = ghosts[bf] else { state.massFlux[f] = 0; continue }
            let P = Int(m.owner[f])
            let Sm = m.faceAreaMag[f]
            let n = m.faceAreas[f] / Sm
            let L = reconstruct(P, f)
            let kind = bc.kind[bf]
            var f0: Double, f1: Vec3, f2: Double
            if kind == .wall || kind == .symmetry || kind == .slipWall {
                // exact wall flux: pressure only
                let pw = L.p
                (f0, f1, f2) = (0, pw * n, 0)
            } else {
                (f0, f1, f2) = roe ? PressureBasedSolver.roeFlux(L, gst, n, gamma: gam) : PressureBasedSolver.ausmFlux(L, gst, n, gamma: gam)
            }
            var fm = f1 * Sm, fe = f2 * Sm
            if viscous && kind != .symmetry && kind != .slipWall {
                let (tv, qv) = viscousFlux(f, P, nil, gst)
                fm -= tv; fe -= qv
                if kind == .wall {
                    state.bWallShear[bf] = -(tv - dot(tv, n) * n) / Sm
                    state.bHeatFlux[bf] = -qv / Sm
                }
            }
            mass[P] += f0 * Sm; mom[P] += fm; ene[P] += fe
            state.massFlux[f] = f0 * Sm
            spectral[P] += (abs(dot(W[P].u, n)) + sqrt(gam * W[P].p / W[P].rho)) * Sm
            state.bU[bf] = kind == .wall && viscous ? bc.uSpec[bf] : 0.5 * (gst.u + W[P].u)
            state.bP[bf] = 0.5 * (gst.p + L.p) - setup.general.operatingPressure
            if kind == .wall || kind == .symmetry || kind == .slipWall { state.bP[bf] = L.p - setup.general.operatingPressure }
            state.bT[bf] = 0.5 * (gst.p / (gst.rho * R) + W[P].p / (W[P].rho * R))
        }
        for c in 0..<nC { localDt[c] = cfl * m.cellVolumes[c] / max(spectral[c], 1e-300) }
    }

    /// Copy primitives into the FlowState used by post-processing and reports.
    func dbSyncFlowState() {
        guard let db = densityState else { return }
        let pop = setup.general.operatingPressure
        for c in 0..<mesh.nCells {
            let w = dbPrim(db, c)
            state.rho[c] = w.rho
            state.u[c] = w.u
            state.p[c] = w.p - pop
            state.T[c] = w.p / (w.rho * db.R)
        }
        if let ax = mesh.twoDimensionalAxis { for c in 0..<mesh.nCells { state.u[c][ax] = 0 } }
    }

    // MARK: Iteration

    /// One density-based iteration (steady: Jameson 4-stage with local time steps) or one
    /// explicit time step (transient: SSP-RK3 with a global CFL-limited step).
    @discardableResult
    func iterateDensityBased(globalDt: Double? = nil) -> [String: Double] {
        if densityState == nil { dbInitialize() }
        guard let db = densityState else { return [:] }
        updateProperties()
        let nC = mesh.nCells
        let cfl = setup.methods.courantNumber
        var mass = [Double](repeating: 0, count: nC), mom = [Vec3](repeating: .zero, count: nC), ene = mass, dt = mass
        let r0 = db.rho, m0 = db.mom, e0 = db.energy
        let vol = mesh.cellVolumes
        let twoD = mesh.twoDimensionalAxis
        var firstRes: (Double, Vec3, Double) = (0, .zero, 0)
        if let gdt = globalDt {
            // SSP-RK3 (Shu-Osher)
            let coeffs: [(Double, Double)] = [(0, 1), (0.75, 0.25), (1.0 / 3.0, 2.0 / 3.0)]
            for (s, (a, b)) in coeffs.enumerated() {
                dbResidual(db, mass: &mass, mom: &mom, ene: &ene, localDt: &dt, cfl: cfl)
                if s == 0 { firstRes = dbNorms(mass, mom, ene) }
                for c in 0..<nC {
                    let k = gdt / vol[c]
                    var mo = db.mom[c] - k * mom[c]
                    if let ax = twoD { mo[ax] = 0 }
                    db.rho[c] = a * r0[c] + b * (db.rho[c] - k * mass[c])
                    db.mom[c] = a * m0[c] + b * mo
                    db.energy[c] = a * e0[c] + b * (db.energy[c] - k * ene[c])
                }
            }
        } else {
            let alphas = [0.25, 1.0 / 3.0, 0.5, 1.0]
            for (s, a) in alphas.enumerated() {
                dbResidual(db, mass: &mass, mom: &mom, ene: &ene, localDt: &dt, cfl: cfl)
                if s == 0 { firstRes = dbNorms(mass, mom, ene) }
                for c in 0..<nC {
                    let k = a * dt[c] / vol[c]
                    var mo = m0[c] - k * mom[c]
                    if let ax = twoD { mo[ax] = 0 }
                    db.rho[c] = r0[c] - k * mass[c]
                    db.mom[c] = mo
                    db.energy[c] = e0[c] - k * ene[c]
                }
            }
        }
        // positivity safeguard
        for c in 0..<nC where db.rho[c] <= 0 || !db.rho[c].isFinite { db.rho[c] = r0[c]; db.mom[c] = m0[c]; db.energy[c] = e0[c] }
        dbSyncFlowState()
        // Fluent-style scaling: divide by the largest of the first five iterations
        let raw = [firstRes.0, firstRes.1.x, firstRes.1.y, firstRes.1.z, firstRes.2]
        if db.scaleSamples < 5 {
            for k in 0..<5 { db.residualScale[k] = max(db.residualScale[k], raw[k]) }
            db.scaleSamples += 1
        }
        var r: [String: Double] = [:]
        let names = ["continuity", "x-velocity", "y-velocity", "z-velocity", "energy"]
        for k in 0..<5 where !(twoD != nil && k == twoD! + 1) {
            r[names[k]] = db.residualScale[k] > 0 ? raw[k] / db.residualScale[k] : raw[k]
        }
        state.iteration += 1
        residuals.record(iteration: state.iteration, r)
        return r
    }

    func dbNorms(_ mass: [Double], _ mom: [Vec3], _ ene: [Double]) -> (Double, Vec3, Double) {
        var a = 0.0, b = Vec3.zero, c = 0.0
        for i in 0..<mass.count { a += mass[i] * mass[i]; b += mom[i] * mom[i]; c += ene[i] * ene[i] }
        let n = Double(max(mass.count, 1))
        return (sqrt(a / n), Vec3(sqrt(b.x / n), sqrt(b.y / n), sqrt(b.z / n)), sqrt(c / n))
    }

    /// Global stable time step for explicit transient runs.
    func dbGlobalTimeStep() -> Double {
        guard let db = densityState else { return setup.run.timeStepSize }
        var mass = [Double](repeating: 0, count: mesh.nCells), mom = [Vec3](repeating: .zero, count: mesh.nCells), ene = mass, dt = mass
        dbResidual(db, mass: &mass, mom: &mom, ene: &ene, localDt: &dt, cfl: setup.methods.courantNumber)
        return dt.min() ?? setup.run.timeStepSize
    }

    /// Transient density-based step of size `setup.run.timeStepSize`, sub-cycled to respect the CFL limit.
    func densityBasedTimeStep() -> [String: Double] {
        if densityState == nil { dbInitialize() }
        let target = setup.run.timeStepSize
        var t = 0.0
        var last: [String: Double] = [:]
        var guardCount = 0
        while t < target * (1 - 1e-12) && guardCount < 100_000 {
            let dt = min(dbGlobalTimeStep(), target - t)
            last = iterateDensityBased(globalDt: dt)
            t += dt
            guardCount += 1
        }
        return last
    }
}
