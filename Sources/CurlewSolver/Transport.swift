import Foundation
import CurlewMesh
import CurlewLinear

/// Higher-order face value correction (phi_HO - phi_upwind) for deferred correction.
@inline(__always)
func convectionCorrection(_ scheme: ConvectionScheme, bounded: Bool, F: Double,
                          phiP: Double, phiN: Double, gradP: Vec3, gradN: Vec3,
                          w: Double, rP: Vec3, rN: Vec3, d: Vec3) -> Double {
    if scheme == .firstOrderUpwind { return 0 }
    let up = F >= 0
    let phiU = up ? phiP : phiN, phiD = up ? phiN : phiP
    let central = w * phiP + (1 - w) * phiN
    var ho: Double
    switch scheme {
    case .firstOrderUpwind: return 0
    case .secondOrderUpwind: ho = up ? phiP + dot(gradP, rP) : phiN + dot(gradN, rN)
    case .central: ho = central
    case .quick:
        let sou = up ? phiP + dot(gradP, rP) : phiN + dot(gradN, rN)
        ho = 0.5 * central + 0.5 * sou
    case .muscl:
        let sou = up ? phiP + dot(gradP, rP) : phiN + dot(gradN, rN)
        ho = central / 3 + 2 * sou / 3
    case .boundedCentral:
        // NVD: phi~_C = 1 - (phi_D - phi_C) / (2 grad_C . d_CD); central inside (0,1), upwind outside.
        let g = up ? dot(gradP, d) : dot(gradN, -d)
        let denom = 2 * g
        if abs(denom) < 1e-300 { ho = phiU; break }
        let nv = 1 - (phiD - phiU) / denom
        ho = (nv > 0 && nv < 1) ? central : phiU
    }
    if bounded {
        let lo = min(phiP, phiN), hi = max(phiP, phiN)
        ho = min(max(ho, lo), hi)
    }
    return ho - phiU
}

/// Inputs for one scalar transport equation.
struct TransportEquation {
    var phi: [Double]
    var bPhi: [Double]
    var grad: [Vec3]
    /// Diffusion coefficient on every face.
    var gamma: [Double]
    /// Multiplier on the mass flux (e.g. cp for energy); nil = 1.
    var convScale: [Double]? = nil
    var scheme: ConvectionScheme
    var bounded: Bool
    var bc: ScalarBC
    /// Explicit source (already multiplied by volume) and implicit diagonal coefficient (>= 0).
    var Su: [Double]
    var Sp: [Double]
    var relax: Double
    /// Rows with mask true are fixed to `fixedValue`.
    var fixedMask: [Bool]? = nil
    var fixedValue: [Double]? = nil
    /// Disable convection (pure diffusion/conduction).
    var convection = true
}

struct TransportAssembler {
    let geo: FVGeometry

    /// Assemble A phi = b. Returns the scaled residual (Fluent definition) of the unrelaxed system.
    func assemble(_ e: inout TransportEquation, flux: [Double], A: SparseMatrix, b: inout [Double]) -> (res: Double, norm: Double) {
        let m = geo.mesh
        let nI = geo.nInternal, nC = geo.nCells
        A.zero()
        if b.count != nC { b = [Double](repeating: 0, count: nC) } else { for i in 0..<nC { b[i] = 0 } }
        let diag = geo.pattern.diag
        let nonOrth = geo.hasNonOrthogonality
        A.values.withUnsafeMutableBufferPointer { V in
            for f in 0..<nI {
                let P = Int(m.owner[f]), N = Int(m.neighbour[f])
                let F = e.convection ? flux[f] * (e.convScale?[f] ?? 1) : 0
                let dif = e.gamma[f] * geo.orthCoeff[f]
                let aPN = -(dif + max(-F, 0))
                let aNP = -(dif + max(F, 0))
                V[Int(geo.upper[f])] += aPN; V[Int(diag[P])] -= aPN
                V[Int(geo.lower[f])] += aNP; V[Int(diag[N])] -= aNP
                // deferred higher-order convection
                if F != 0 && e.scheme != .firstOrderUpwind {
                    let cf = m.faceCentres[f]
                    let corr = F * convectionCorrection(e.scheme, bounded: e.bounded, F: F, phiP: e.phi[P], phiN: e.phi[N],
                                                        gradP: e.grad[P], gradN: e.grad[N], w: geo.weight[f],
                                                        rP: cf - m.cellCentres[P], rN: cf - m.cellCentres[N], d: geo.delta[f])
                    b[P] -= corr; b[N] += corr
                }
                if nonOrth {
                    let w = geo.weight[f]
                    let gf = w * e.grad[P] + (1 - w) * e.grad[N]
                    let c = e.gamma[f] * dot(gf, geo.nonOrth[f])
                    b[P] += c; b[N] -= c
                }
            }
            for f in nI..<geo.nFaces {
                let bf = f - nI
                let P = Int(m.owner[f])
                let F = e.convection ? flux[f] * (e.convScale?[f] ?? 1) : 0
                switch e.bc.kind[bf] {
                case .none: continue
                case .fixedValue:
                    let dif = e.gamma[f] * geo.orthCoeff[f]
                    let a = dif + max(-F, 0)
                    V[Int(diag[P])] += a
                    b[P] += a * e.bc.value[bf]
                    if nonOrth { b[P] += e.gamma[f] * dot(e.grad[P], geo.nonOrth[f]) }
                case .zeroGradient:
                    // inflow through a zero-gradient face (backflow) carries the backflow value
                    if F < 0 {
                        V[Int(diag[P])] += -F
                        b[P] += -F * e.bc.value[bf]
                    }
                case .fixedFlux:
                    b[P] += e.bc.coeff[bf] * m.faceAreaMag[f]
                case .robin:
                    // q = (phi_inf - phi_P) / (1/h + d/Gamma)
                    let h = e.bc.coeff[bf]
                    let dn = geo.normalDistance(f)
                    let g = max(e.gamma[f], 1e-300)
                    let U = m.faceAreaMag[f] / (1 / max(h, 1e-300) + dn / g)
                    V[Int(diag[P])] += U
                    b[P] += U * e.bc.value[bf]
                }
            }
            for c in 0..<nC {
                V[Int(diag[c])] += e.Sp[c]
                b[c] += e.Su[c]
            }
            if let mask = e.fixedMask, let val = e.fixedValue {
                let R = geo.pattern.rowPtr
                for c in 0..<nC where mask[c] {
                    for k in Int(R[c])..<Int(R[c + 1]) { V[k] = 0 }
                    V[Int(diag[c])] = 1
                    b[c] = val[c]
                }
            }
        }
        // Scaled residual of the unrelaxed system
        var r = [Double](repeating: 0, count: nC)
        let res = A.residual(x: e.phi, b: b, into: &r)
        let nrm = A.diagonalNorm(x: e.phi)
        // Under-relaxation
        if e.relax < 1 {
            let a = e.relax
            A.values.withUnsafeMutableBufferPointer { V in
                for c in 0..<nC {
                    let k = Int(diag[c])
                    let d = V[k]
                    V[k] = d / a
                    b[c] += (1 - a) / a * d * e.phi[c]
                }
            }
        }
        return (res, nrm)
    }

    /// Update boundary face values after a solve.
    func updateBoundary(_ e: inout TransportEquation, flux: [Double]) {
        let m = geo.mesh
        let nI = geo.nInternal
        for f in nI..<geo.nFaces {
            let bf = f - nI
            let P = Int(m.owner[f])
            switch e.bc.kind[bf] {
            case .none: e.bPhi[bf] = e.phi[P]
            case .fixedValue: e.bPhi[bf] = e.bc.value[bf]
            case .zeroGradient: e.bPhi[bf] = flux[f] < 0 ? e.bc.value[bf] : e.phi[P]
            case .fixedFlux:
                let dn = geo.normalDistance(f)
                e.bPhi[bf] = e.phi[P] + e.bc.coeff[bf] * dn / max(e.gamma[f], 1e-300)
            case .robin:
                let h = e.bc.coeff[bf], g = max(e.gamma[f], 1e-300) / geo.normalDistance(f)
                e.bPhi[bf] = (h * e.bc.value[bf] + g * e.phi[P]) / max(h + g, 1e-300)
            }
        }
    }
}
