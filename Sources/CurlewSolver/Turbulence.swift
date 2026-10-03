import Foundation
import CurlewMesh

/// Turbulence model constants.
enum SST {
    static let betaStar = 0.09, a1 = 0.31, kappa = 0.41
    static let sigmaK1 = 0.85, sigmaW1 = 0.5, beta1 = 0.075, gamma1 = 5.0 / 9.0
    static let sigmaK2 = 1.0, sigmaW2 = 0.856, beta2 = 0.0828, gamma2 = 0.44
}
enum KE {
    static let cmu = 0.09, c1 = 1.44, c2 = 1.92, sigmaK = 1.0, sigmaE = 1.3
    static let rC2 = 1.9, rSigmaE = 1.2, A0 = 4.04
}
enum SA {
    static let cb1 = 0.1355, cb2 = 0.622, sigma = 2.0 / 3.0, kappa = 0.41, cv1 = 7.1, cw2 = 0.3, cw3 = 2.0
    static var cw1: Double { cb1 / (kappa * kappa) + (1 + cb2) / sigma }
    static func fv1(_ chi: Double) -> Double { let c3 = chi * chi * chi; return c3 / (c3 + cv1 * cv1 * cv1) }
    /// nu~ such that nu~ fv1(nu~/nu) = nuT.
    static func nuTildeFor(nuT: Double, nu: Double) -> Double {
        var chi = max(nuT / nu, 1e-6)
        for _ in 0..<50 {
            let f = chi * fv1(chi) - nuT / nu
            let h = 1e-6 * max(chi, 1)
            let df = ((chi + h) * fv1(chi + h) - chi * fv1(chi)) / h
            chi = max(chi - f / max(df, 1e-12), 1e-12)
            if abs(f) < 1e-12 * max(nuT / nu, 1) { break }
        }
        return chi * nu
    }
}

/// Reichardt's law of the wall, valid through the viscous sublayer, buffer and log layer.
@inline(__always) func reichardtUPlus(_ yp: Double) -> Double {
    let k = SST.kappa
    return log(1 + k * yp) / k + 7.8 * (1 - exp(-yp / 11) - yp / 11 * exp(-yp / 3))
}

extension PressureBasedSolver {
    var cmu25: Double { pow(0.09, 0.25) }

    func initTurbulentViscosity() {
        let n = mesh.nCells
        let model = setup.models.viscous
        for c in 0..<n {
            if isSolidCell[c] { state.muT[c] = 0; continue }
            let rho = state.rho[c]
            switch model {
            case .kOmegaSST: state.muT[c] = rho * max(state.k[c], 0) / max(state.omega[c], 1e-20)
            case .kEpsilonStandard, .kEpsilonRealizable:
                state.muT[c] = rho * KE.cmu * state.k[c] * state.k[c] / max(state.epsilon[c], 1e-20)
            case .spalartAllmaras:
                let nu = state.mu[c] / rho
                state.muT[c] = rho * state.nuTilda[c] * SA.fv1(state.nuTilda[c] / nu)
            default: state.muT[c] = 0
            }
            state.muT[c] = min(state.muT[c], setup.controls.limits.maximumViscosityRatio * state.mu[c])
        }
        for (i, w) in walls.enumerated() { muWall[i] = state.mu[w.cell] }
    }

    @inline(__always) func wallNormalDistance(_ w: WallFace) -> Double {
        let f = w.face
        return max(abs(dot(mesh.faceAreas[f], mesh.faceCentres[f] - mesh.cellCentres[w.cell])) / max(mesh.faceAreaMag[f], 1e-300), 1e-300)
    }

    /// Effective wall viscosity (momentum) for every wall face.
    func updateWallFunctions() {
        let model = setup.models.viscous
        let nI = geo.nInternal
        for (i, w) in walls.enumerated() {
            let P = w.cell
            let mu = state.mu[P], rho = state.rho[P]
            let nu = mu / rho
            let y = wallNormalDistance(w)
            let uw: Vec3 = w.isInterface ? .zero : bc.uSpec[w.face - nI]
            let n = normalized(mesh.faceAreas[w.face])
            var du = state.u[P] - uw
            du -= dot(du, n) * n
            let Up = norm(du)
            switch model {
            case .kOmegaSST, .kEpsilonRealizable, .kEpsilonStandard:
                let ustar = cmu25 * sqrt(max(state.k[P], 0))
                let ys = ustar * y / nu
                if model == .kOmegaSST || setup.models.wallTreatment == .automatic {
                    muWall[i] = ys > 1e-3 ? mu * ys / reichardtUPlus(ys) : mu
                } else {
                    let E = 9.793
                    muWall[i] = ys > 11.225 ? mu * ys * SST.kappa / Foundation.log(E * ys) : mu
                }
            case .spalartAllmaras:
                // velocity-based friction velocity from Reichardt's law (Newton on u_tau)
                var ut = max(sqrt(nu * Up / y), 1e-12)
                for _ in 0..<12 {
                    let yp = ut * y / nu
                    let f = ut * reichardtUPlus(yp) - Up
                    let h = 1e-6 * ut
                    let ypH = (ut + h) * y / nu
                    let df = ((ut + h) * reichardtUPlus(ypH) - ut * reichardtUPlus(yp)) / h
                    let nxt = ut - f / max(df, 1e-12)
                    ut = max(nxt, 1e-12)
                    if abs(f) < 1e-10 * max(Up, 1e-12) { break }
                }
                muWall[i] = Up > 1e-14 ? max(rho * ut * ut * y / Up, mu) : mu
            default:
                muWall[i] = mu
            }
        }
        updateWallShear()
    }

    /// Effective thermal conductivity at a turbulent wall face (Kader blending of T+).
    func wallConductivity(_ wi: Int, cell P: Int) -> Double {
        let w = walls[wi]
        let rho = state.rho[P], mu = state.mu[P], cp = state.cp[P], kl = state.conductivity[P]
        let y = wallNormalDistance(w)
        let ustar = setup.models.viscous == .spalartAllmaras
            ? sqrt(norm(state.bWallShear[w.face - geo.nInternal]) / max(rho, 1e-300))
            : cmu25 * sqrt(max(state.k[P], 0))
        let ys = rho * ustar * y / mu
        if ys < 1e-3 { return kl }
        let pr = mu * cp / kl, prt = setup.models.turbulentPrandtl
        let P9 = 9.24 * (pow(pr / prt, 0.75) - 1) * (1 + 0.28 * exp(-0.007 * pr / prt))
        let gam = 0.01 * pow(pr * ys, 4) / (1 + 5 * pr * pr * pr * ys)
        let uLog = Foundation.log(9.793 * ys) / SST.kappa
        let tPlus = pr * ys * exp(-gam) + prt * (uLog + P9) * exp(-1 / max(gam, 1e-300))
        return max(rho * cp * ustar * y / max(tPlus, 1e-300), kl)
    }

    // MARK: Solve

    func solveTurbulence() -> [String: Double] {
        switch setup.models.viscous {
        case .kOmegaSST: return solveSST()
        case .kEpsilonStandard, .kEpsilonRealizable: return solveKEpsilon(realizable: setup.models.viscous == .kEpsilonRealizable)
        case .spalartAllmaras: return solveSA()
        default: return [:]
        }
    }

    /// Strain-rate magnitude squared S^2 = 2 S_ij S_ij and vorticity magnitude per cell.
    func strainAndVorticity() -> (S2: [Double], W: [Double]) {
        let n = mesh.nCells
        var S2 = [Double](repeating: 0, count: n), W = S2
        for c in 0..<n {
            let s = strainRateMagnitude(c)
            S2[c] = s * s
            let gx = gradU[0][c], gy = gradU[1][c], gz = gradU[2][c]
            let wx = gz.y - gy.z, wy = gx.z - gz.x, wz = gy.x - gx.y
            W[c] = sqrt(wx * wx + wy * wy + wz * wz)
        }
        return (S2, W)
    }

    /// Fixed-value rows for wall-adjacent cells (omega / epsilon) averaged over the cell's wall faces.
    func wallCellValues(_ value: (WallFace) -> Double) -> ([Bool], [Double]) {
        let n = mesh.nCells
        var mask = [Bool](repeating: false, count: n)
        var sum = [Double](repeating: 0, count: n), cnt = [Double](repeating: 0, count: n)
        for w in walls {
            mask[w.cell] = true
            sum[w.cell] += value(w); cnt[w.cell] += 1
        }
        for c in 0..<n where cnt[c] > 0 { sum[c] /= cnt[c] }
        for c in 0..<n where isSolidCell[c] { mask[c] = true; sum[c] = 0 }
        return (mask, sum)
    }

    func transientTerms(_ old: [Double], _ oldOld: [Double], Su: inout [Double], Sp: inout [Double]) {
        guard isTransient, !old.isEmpty else { return }
        let dt = setup.run.timeStepSize
        let second = setup.methods.transient == .secondOrderImplicit && state.timeStep > 1 && !oldOld.isEmpty
        for c in 0..<mesh.nCells {
            let rv = state.rho[c] * mesh.cellVolumes[c] / dt
            if second { Sp[c] += 1.5 * rv; Su[c] += rv * (2 * old[c] - 0.5 * oldOld[c]) }
            else { Sp[c] += rv; Su[c] += rv * old[c] }
        }
    }

    func faceGamma(_ cellGamma: [Double]) -> [Double] {
        var g = [Double](repeating: 0, count: geo.nFaces)
        for f in 0..<geo.nInternal {
            let w = geo.weight[f]
            g[f] = w * cellGamma[Int(mesh.owner[f])] + (1 - w) * cellGamma[Int(mesh.neighbour[f])]
        }
        for f in geo.nInternal..<geo.nFaces { g[f] = cellGamma[Int(mesh.owner[f])] }
        return g
    }

    func solveScalarEquation(_ eq: inout TransportEquation, floor: Double) -> (values: [Double], boundary: [Double], residual: Double) {
        eq.positive = true
        eq.floor = max(floor, 1e-30)
        let asm = TransportAssembler(geo: geo, nonOrthLimit: setup.methods.nonOrthogonalLimit ?? geo.automaticNonOrthogonalLimit)
        var b = [Double](repeating: 0, count: mesh.nCells)
        let (raw, nrm) = asm.assemble(&eq, flux: state.massFlux, A: A, b: &b)
        var x = eq.phi
        turbSolver.solve(A, x: &x, b: b)
        for c in 0..<x.count { x[c] = max(x[c], floor) }
        eq.phi = x
        asm.updateBoundary(&eq, flux: state.massFlux)
        return (x, eq.bPhi, nrm > 1e-300 ? raw / nrm : raw)
    }

    // MARK: k-omega SST (Menter 2003)

    func solveSST() -> [String: Double] {
        let m = mesh, n = m.nCells
        let lim = setup.controls.limits
        let y = geo.wallDistance
        let (S2, _) = strainAndVorticity()
        var gk: [Vec3] = [], gw: [Vec3] = []
        Gradient.compute(geo, state.k, boundary: state.bK, scheme: setup.methods.gradient, into: &gk)
        Gradient.compute(geo, state.omega, boundary: state.bOmega, scheme: setup.methods.gradient, into: &gw)
        var F1 = [Double](repeating: 0, count: n), F2 = F1
        var Pk = F1, CD = F1
        for c in 0..<n where !isSolidCell[c] {
            let k = max(state.k[c], lim.minimumK), w = max(state.omega[c], 1e-20)
            let rho = state.rho[c], nu = state.mu[c] / rho
            let yc = max(y[c], 1e-30)
            let cdkw = 2 * rho * SST.sigmaW2 / w * dot(gk[c], gw[c])
            CD[c] = cdkw
            let cdPos = max(cdkw, 1e-10)
            let arg1 = min(max(sqrt(k) / (SST.betaStar * w * yc), 500 * nu / (yc * yc * w)), 4 * rho * SST.sigmaW2 * k / (cdPos * yc * yc))
            F1[c] = tanh(pow(arg1, 4))
            let arg2 = max(2 * sqrt(k) / (SST.betaStar * w * yc), 500 * nu / (yc * yc * w))
            F2[c] = tanh(arg2 * arg2)
            Pk[c] = min(state.muT[c] * S2[c], 10 * SST.betaStar * rho * k * w)
        }
        // Wall-function production in log-layer wall cells
        let nI = geo.nInternal
        var wallProd = [Double](repeating: 0, count: n), wallCnt = wallProd
        for (i, w) in walls.enumerated() {
            let P = w.cell
            let yw = wallNormalDistance(w)
            let ustar = cmu25 * sqrt(max(state.k[P], 0))
            let ys = state.rho[P] * ustar * yw / state.mu[P]
            if ys > 11.225 {
                let tau = w.isInterface ? muWall[i] * norm(state.u[P]) / yw : norm(state.bWallShear[w.face - nI])
                wallProd[P] += tau * ustar / (SST.kappa * yw); wallCnt[P] += 1
            }
        }
        for c in 0..<n where wallCnt[c] > 0 { Pk[c] = wallProd[c] / wallCnt[c] }

        // k equation
        var gammaK = [Double](repeating: 0, count: n), gammaW = gammaK
        for c in 0..<n {
            let sk = F1[c] * SST.sigmaK1 + (1 - F1[c]) * SST.sigmaK2
            let sw = F1[c] * SST.sigmaW1 + (1 - F1[c]) * SST.sigmaW2
            gammaK[c] = state.mu[c] + sk * state.muT[c]
            gammaW[c] = state.mu[c] + sw * state.muT[c]
        }
        var Su = [Double](repeating: 0, count: n), Sp = Su
        for c in 0..<n where !isSolidCell[c] {
            let V = m.cellVolumes[c]
            Su[c] = Pk[c] * V
            Sp[c] = SST.betaStar * state.rho[c] * max(state.omega[c], 1e-20) * V
        }
        transientTerms(state.kOld, state.kOldOld, Su: &Su, Sp: &Sp)
        var mask: [Bool]? = nil
        if hasSolids { mask = isSolidCell }
        var eqK = TransportEquation(phi: state.k, bPhi: state.bK, grad: gk, gamma: faceGamma(gammaK),
                                    scheme: setup.methods.turbulence, bounded: true, bc: bc.k, Su: Su, Sp: Sp,
                                    relax: setup.controls.urf.turbulentKineticEnergy,
                                    fixedMask: mask, fixedValue: mask == nil ? nil : [Double](repeating: lim.minimumK, count: n))
        let rk = solveScalarEquation(&eqK, floor: lim.minimumK)

        // omega equation
        for c in 0..<n { Su[c] = 0; Sp[c] = 0 }
        for c in 0..<n where !isSolidCell[c] {
            let V = m.cellVolumes[c], rho = state.rho[c], w = max(state.omega[c], 1e-20)
            let gam = F1[c] * SST.gamma1 + (1 - F1[c]) * SST.gamma2
            let beta = F1[c] * SST.beta1 + (1 - F1[c]) * SST.beta2
            // production gamma rho / muT * min(muT S^2, 10 beta* rho k omega)
            let k = max(state.k[c], lim.minimumK)
            let cap = state.muT[c] > 1e-300 ? 10 * SST.betaStar * rho * k * w / state.muT[c] : Double.infinity
            Su[c] = gam * rho * min(S2[c], cap) * V
            Sp[c] = beta * rho * w * V
            let cross = (1 - F1[c]) * CD[c]
            if cross > 0 { Su[c] += cross * V } else { Sp[c] += -cross / w * V }
        }
        transientTerms(state.omegaOld, state.omegaOldOld, Su: &Su, Sp: &Sp)
        let (wMask, wVal) = wallCellValues { w in
            let P = w.cell
            let yw = self.wallNormalDistance(w)
            let nu = self.state.mu[P] / self.state.rho[P]
            let wVis = 6 * nu / (SST.beta1 * yw * yw)
            let wLog = self.cmu25 * sqrt(max(self.state.k[P], 0)) / (sqrt(SST.betaStar) * SST.kappa * yw)
            return sqrt(wVis * wVis + wLog * wLog)
        }
        var eqW = TransportEquation(phi: state.omega, bPhi: state.bOmega, grad: gw, gamma: faceGamma(gammaW),
                                    scheme: setup.methods.turbulence, bounded: true, bc: bc.omega, Su: Su, Sp: Sp,
                                    relax: setup.controls.urf.specificDissipationRate, fixedMask: wMask, fixedValue: wVal)
        let rw = solveScalarEquation(&eqW, floor: lim.minimumOmega)
        state.k = rk.values; state.bK = rk.boundary
        state.omega = rw.values; state.bOmega = rw.boundary

        // turbulent viscosity: rho a1 k / max(a1 omega, S F2)
        let urf = setup.controls.urf.turbulentViscosity
        for c in 0..<n {
            if isSolidCell[c] { state.muT[c] = 0; continue }
            let S = sqrt(S2[c])
            let mt = state.rho[c] * SST.a1 * state.k[c] / max(SST.a1 * state.omega[c], S * F2[c], 1e-300)
            let capped = min(mt, lim.maximumViscosityRatio * state.mu[c])
            state.muT[c] = urf * capped + (1 - urf) * state.muT[c]
        }
        return ["k": rk.residual, "omega": rw.residual]
    }

    // MARK: k-epsilon (standard / realizable) with wall functions

    func solveKEpsilon(realizable: Bool) -> [String: Double] {
        let m = mesh, n = m.nCells
        let lim = setup.controls.limits
        let (S2, W) = strainAndVorticity()
        var gk: [Vec3] = [], ge: [Vec3] = []
        Gradient.compute(geo, state.k, boundary: state.bK, scheme: setup.methods.gradient, into: &gk)
        Gradient.compute(geo, state.epsilon, boundary: state.bEpsilon, scheme: setup.methods.gradient, into: &ge)
        var Pk = [Double](repeating: 0, count: n)
        for c in 0..<n where !isSolidCell[c] { Pk[c] = state.muT[c] * S2[c] }
        let nI = geo.nInternal
        var wallProd = [Double](repeating: 0, count: n), wallCnt = wallProd
        for (i, w) in walls.enumerated() {
            let P = w.cell
            let yw = wallNormalDistance(w)
            let ustar = cmu25 * sqrt(max(state.k[P], 0))
            let ys = state.rho[P] * ustar * yw / state.mu[P]
            if ys > 11.225 {
                let tau = w.isInterface ? muWall[i] * norm(state.u[P]) / yw : norm(state.bWallShear[w.face - nI])
                wallProd[P] += tau * ustar / (SST.kappa * yw); wallCnt[P] += 1
            }
        }
        for c in 0..<n where wallCnt[c] > 0 { Pk[c] = wallProd[c] / wallCnt[c] }

        let sigE = realizable ? KE.rSigmaE : KE.sigmaE
        var gammaK = [Double](repeating: 0, count: n), gammaE = gammaK
        for c in 0..<n {
            gammaK[c] = state.mu[c] + state.muT[c] / KE.sigmaK
            gammaE[c] = state.mu[c] + state.muT[c] / sigE
        }
        var Su = [Double](repeating: 0, count: n), Sp = Su
        for c in 0..<n where !isSolidCell[c] {
            let V = m.cellVolumes[c], k = max(state.k[c], lim.minimumK)
            Su[c] = Pk[c] * V
            Sp[c] = state.rho[c] * max(state.epsilon[c], 1e-20) / k * V
        }
        transientTerms(state.kOld, state.kOldOld, Su: &Su, Sp: &Sp)
        var mask: [Bool]? = nil
        if hasSolids { mask = isSolidCell }
        var eqK = TransportEquation(phi: state.k, bPhi: state.bK, grad: gk, gamma: faceGamma(gammaK),
                                    scheme: setup.methods.turbulence, bounded: true, bc: bc.k, Su: Su, Sp: Sp,
                                    relax: setup.controls.urf.turbulentKineticEnergy,
                                    fixedMask: mask, fixedValue: mask == nil ? nil : [Double](repeating: lim.minimumK, count: n))
        let rk = solveScalarEquation(&eqK, floor: lim.minimumK)

        for c in 0..<n { Su[c] = 0; Sp[c] = 0 }
        for c in 0..<n where !isSolidCell[c] {
            let V = m.cellVolumes[c], rho = state.rho[c]
            let k = max(state.k[c], lim.minimumK), e = max(state.epsilon[c], 1e-20)
            if realizable {
                let S = sqrt(S2[c])
                let eta = S * k / e
                let C1 = max(0.43, eta / (eta + 5))
                Su[c] = rho * C1 * S * e * V
                let nu = state.mu[c] / rho
                Sp[c] = rho * KE.rC2 * e / (k + sqrt(nu * e)) * V
            } else {
                Su[c] = KE.c1 * e / k * Pk[c] * V
                Sp[c] = KE.c2 * rho * e / k * V
            }
        }
        transientTerms(state.epsOld, state.epsOldOld, Su: &Su, Sp: &Sp)
        let (eMask, eVal) = wallCellValues { w in
            let P = w.cell
            let yw = self.wallNormalDistance(w)
            let k = max(self.state.k[P], 0)
            let nu = self.state.mu[P] / self.state.rho[P]
            let eLog = pow(KE.cmu, 0.75) * pow(k, 1.5) / (SST.kappa * yw)
            let eVis = 2 * nu * k / (yw * yw)
            let ys = self.cmu25 * sqrt(k) * yw / nu
            return ys > 11.225 ? eLog : max(eVis, eLog)
        }
        var eqE = TransportEquation(phi: state.epsilon, bPhi: state.bEpsilon, grad: ge, gamma: faceGamma(gammaE),
                                    scheme: setup.methods.turbulence, bounded: true, bc: bc.epsilon, Su: Su, Sp: Sp,
                                    relax: setup.controls.urf.dissipationRate, fixedMask: eMask, fixedValue: eVal)
        let re = solveScalarEquation(&eqE, floor: lim.minimumEpsilon)
        state.k = rk.values; state.bK = rk.boundary
        state.epsilon = re.values; state.bEpsilon = re.boundary

        let urf = setup.controls.urf.turbulentViscosity
        for c in 0..<n {
            if isSolidCell[c] { state.muT[c] = 0; continue }
            let k = state.k[c], e = max(state.epsilon[c], 1e-20)
            var cmu = KE.cmu
            if realizable {
                // Shih et al. variable C_mu
                let gx = gradU[0][c], gy = gradU[1][c], gz = gradU[2][c]
                let Sij = [[gx.x, 0.5 * (gx.y + gy.x), 0.5 * (gx.z + gz.x)],
                           [0.5 * (gx.y + gy.x), gy.y, 0.5 * (gy.z + gz.y)],
                           [0.5 * (gx.z + gz.x), 0.5 * (gy.z + gz.y), gz.z]]
                var ss = 0.0, sss = 0.0
                for i in 0..<3 { for j in 0..<3 { ss += Sij[i][j] * Sij[i][j]; for kk in 0..<3 { sss += Sij[i][j] * Sij[j][kk] * Sij[kk][i] } } }
                let St = sqrt(ss)
                let Wv = St > 1e-300 ? sss / (St * St * St) : 0
                let phi = acos(max(-1, min(1, sqrt(6) * Wv))) / 3
                let As = sqrt(6) * cos(phi)
                let Ustar = sqrt(ss + 0.5 * W[c] * W[c])
                cmu = 1 / (KE.A0 + As * Ustar * k / e)
            }
            let mt = state.rho[c] * cmu * k * k / e
            let capped = min(mt, lim.maximumViscosityRatio * state.mu[c])
            state.muT[c] = urf * capped + (1 - urf) * state.muT[c]
        }
        return ["k": rk.residual, "epsilon": re.residual]
    }

    // MARK: Spalart-Allmaras

    func solveSA() -> [String: Double] {
        let m = mesh, n = m.nCells
        let lim = setup.controls.limits
        let y = geo.wallDistance
        let (_, W) = strainAndVorticity()
        var gn: [Vec3] = []
        Gradient.compute(geo, state.nuTilda, boundary: state.bNuTilda, scheme: setup.methods.gradient, into: &gn)
        var gamma = [Double](repeating: 0, count: n)
        var Su = gamma, Sp = gamma
        for c in 0..<n where !isSolidCell[c] {
            let rho = state.rho[c], nu = state.mu[c] / rho
            let nt = max(state.nuTilda[c], 0)
            gamma[c] = rho * (nu + nt) / SA.sigma
            let chi = nt / nu
            let fv1 = SA.fv1(chi)
            let fv2 = 1 - chi / (1 + chi * fv1)
            let d = max(y[c], 1e-30)
            let kd2 = SA.kappa * SA.kappa * d * d
            var St = W[c] + nt / kd2 * fv2
            St = max(St, 0.3 * W[c])
            let r = min(St > 1e-300 ? nt / (St * kd2) : 10, 10)
            let g = r + SA.cw2 * (pow(r, 6) - r)
            let cw36 = pow(SA.cw3, 6)
            let fw = g * pow((1 + cw36) / (pow(g, 6) + cw36), 1.0 / 6.0)
            let V = m.cellVolumes[c]
            Su[c] = rho * SA.cb1 * St * nt * V + rho * SA.cb2 / SA.sigma * lengthSquared(gn[c]) * V
            Sp[c] = rho * SA.cw1 * fw * nt / (d * d) * V
        }
        transientTerms(state.nutOld, state.nutOldOld, Su: &Su, Sp: &Sp)
        // Coarse wall cells (y+ > 11): log-law value nu~ = kappa u_tau y instead of resolving to nu~ = 0.
        var mask = isSolidCell
        var fixedVal = [Double](repeating: 0, count: n)
        var anyFixed = hasSolids
        let nI = geo.nInternal
        var cnt = [Double](repeating: 0, count: n)
        for w in walls where !w.isInterface {
            let P = w.cell
            let yw = wallNormalDistance(w)
            let ut = sqrt(norm(state.bWallShear[w.face - nI]) / state.rho[P])
            let yp = ut * yw * state.rho[P] / state.mu[P]
            if yp > 11 {
                mask[P] = true; anyFixed = true
                fixedVal[P] += SA.kappa * ut * yw; cnt[P] += 1
            }
        }
        for c in 0..<n where cnt[c] > 0 { fixedVal[c] /= cnt[c] }
        var eq = TransportEquation(phi: state.nuTilda, bPhi: state.bNuTilda, grad: gn, gamma: faceGamma(gamma),
                                   scheme: setup.methods.turbulence, bounded: true, bc: bc.nuTilda, Su: Su, Sp: Sp,
                                   relax: setup.controls.urf.modifiedTurbulentViscosity,
                                   fixedMask: anyFixed ? mask : nil, fixedValue: anyFixed ? fixedVal : nil)
        let r = solveScalarEquation(&eq, floor: 0)
        state.nuTilda = r.values; state.bNuTilda = r.boundary
        let urf = setup.controls.urf.turbulentViscosity
        for c in 0..<n {
            if isSolidCell[c] { state.muT[c] = 0; continue }
            let rho = state.rho[c], nu = state.mu[c] / rho
            let mt = rho * state.nuTilda[c] * SA.fv1(state.nuTilda[c] / nu)
            state.muT[c] = urf * min(mt, lim.maximumViscosityRatio * state.mu[c]) + (1 - urf) * state.muT[c]
        }
        return ["nut": r.residual]
    }
}
