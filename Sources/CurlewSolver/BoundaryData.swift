import Foundation
import CurlewMesh

/// Resolved boundary condition type per boundary face.
public enum BCKind: UInt8, Sendable {
    case empty, wall, slipWall, velocityInlet, pressureInlet, pressureOutlet, symmetry, outflow, farField

    var isPressureSpecified: Bool { self == .pressureInlet || self == .pressureOutlet || self == .farField }
    var isInletFixedVelocity: Bool { self == .velocityInlet }
}

public enum ScalarBCKind: UInt8, Sendable { case none, fixedValue, zeroGradient, fixedFlux, robin }

/// Per-face boundary condition for one scalar equation.
public struct ScalarBC {
    public var kind: [ScalarBCKind]
    /// fixedValue: value; robin: far-field value.
    public var value: [Double]
    /// fixedFlux: flux into the domain per unit area; robin: transfer coefficient.
    public var coeff: [Double]
    public init(n: Int) {
        kind = [ScalarBCKind](repeating: .zeroGradient, count: n)
        value = [Double](repeating: 0, count: n)
        coeff = [Double](repeating: 0, count: n)
    }
}

/// Boundary conditions resolved onto faces, plus prescribed values.
public final class BoundaryData: @unchecked Sendable {
    public let nB: Int
    public let nInternal: Int
    public var kind: [BCKind]
    public var zone: [Int32]
    /// Settings per mesh boundary zone (same order as mesh.boundaryZones).
    public var zoneSettings: [BoundarySettings]
    /// Prescribed velocity (inlets, moving walls, far field).
    public var uSpec: [Vec3]
    /// Prescribed gauge pressure (static at outlets, total at pressure inlets).
    public var pSpec: [Double]
    public var thermal: ScalarBC
    public var k: ScalarBC
    public var omega: ScalarBC
    public var epsilon: ScalarBC
    public var nuTilda: ScalarBC
    public var scalars: [ScalarBC] = []
    /// Target mass flow per zone for mass-flow inlets (NaN otherwise).
    public var zoneMassFlow: [Double]
    public var zoneArea: [Double]
    public let hasPressureBoundary: Bool

    public init(mesh: Mesh, setup: CaseSetup, exprs: [String: Expr], time: Double) throws {
        nInternal = mesh.nInternalFaces
        nB = mesh.nBoundaryFaces
        kind = [BCKind](repeating: .wall, count: nB)
        zone = [Int32](repeating: 0, count: nB)
        uSpec = [Vec3](repeating: .zero, count: nB)
        pSpec = [Double](repeating: 0, count: nB)
        thermal = ScalarBC(n: nB); k = ScalarBC(n: nB); omega = ScalarBC(n: nB)
        epsilon = ScalarBC(n: nB); nuTilda = ScalarBC(n: nB)
        zoneSettings = mesh.boundaryZones.map { setup.boundaries[$0.name] ?? BoundarySettings(type: $0.kind) }
        zoneMassFlow = [Double](repeating: .nan, count: mesh.boundaryZones.count)
        zoneArea = mesh.boundaryZones.map { z in z.faceRange.reduce(0) { $0 + mesh.faceAreaMag[$1] } }
        var anyP = false
        for (zi, z) in mesh.boundaryZones.enumerated() {
            let s = zoneSettings[zi]
            let k: BCKind
            switch s.type {
            case .empty: k = .empty
            case .wall: k = s.shearCondition == .specifiedShear ? .slipWall : .wall
            case .velocityInlet, .massFlowInlet: k = .velocityInlet
            case .pressureInlet: k = .pressureInlet
            case .pressureOutlet: k = .pressureOutlet
            case .symmetry: k = .symmetry
            case .outflow: k = .outflow
            case .pressureFarField: k = .farField
            case .interior: k = .wall
            }
            if k.isPressureSpecified { anyP = true }
            for f in z.faceRange { kind[f - nInternal] = k; zone[f - nInternal] = Int32(zi) }
        }
        hasPressureBoundary = anyP
        scalars = setup.models.passiveScalars.map { _ in ScalarBC(n: nB) }
        try update(mesh: mesh, setup: setup, exprs: exprs, time: time, density: nil, viscosity: nil)
    }

    func evaluate(_ q: Quantity, at c: Vec3, time: Double, exprs: [String: Expr]) throws -> Double {
        switch q {
        case .constant(let d): return d
        case .expression(let s):
            let e = try Expr(s, named: exprs)
            return e.value(x: c.x, y: c.y, z: c.z, t: time)
        }
    }

    /// Re-evaluate prescribed values (expressions may depend on time).
    /// `density`/`viscosity` are boundary-cell properties for mass-flow and turbulence specs.
    func update(mesh: Mesh, setup: CaseSetup, exprs: [String: Expr], time: Double,
                density: [Double]?, viscosity: [Double]?) throws {
        let model = setup.models.viscous
        for (zi, z) in mesh.boundaryZones.enumerated() {
            let s = zoneSettings[zi]
            // Compile once per zone
            func compiler(_ q: Quantity) throws -> (Vec3) -> Double {
                switch q {
                case .constant(let d): return { _ in d }
                case .expression(let src):
                    let e = try Expr(src, named: exprs)
                    return { c in e.value(x: c.x, y: c.y, z: c.z, t: time) }
                }
            }
            let fVelMag = try compiler(s.velocityMagnitude)
            let fVel = try s.velocity.map(compiler)
            let fWallVel = try s.wallVelocity.map(compiler)
            let fP = try compiler(s.gaugePressure)
            let fT = try compiler(s.temperature)
            let fQ = try compiler(s.heatFlux)
            let fH = try compiler(s.heatTransferCoefficient)
            let fTinf = try compiler(s.freeStreamTemperature)
            let massFlow = try evaluate(s.massFlowRate, at: .zero, time: time, exprs: exprs)
            if s.type == .massFlowInlet { zoneMassFlow[zi] = massFlow }

            // Turbulence inlet values from specification
            func turbulence(speed: Double, rho: Double, mu: Double) -> (k: Double, omega: Double, eps: Double, nut: Double) {
                let cmu = 0.09
                switch s.turbulenceSpecification {
                case .direct:
                    return (s.k, s.omega, s.epsilon, s.modifiedTurbulentViscosity)
                default:
                    let I = s.turbulentIntensity
                    let kk = max(1.5 * pow(max(speed, 1e-10) * I, 2), 1e-14)
                    var l = s.turbulentLengthScale
                    if s.turbulenceSpecification == .intensityAndHydraulicDiameter { l = 0.07 * s.hydraulicDiameter }
                    if s.turbulenceSpecification == .intensityAndViscosityRatio {
                        let nuT = s.turbulentViscosityRatio * mu / rho
                        let om = kk / max(nuT, 1e-300)
                        return (kk, om, cmu * kk * om, SA.nuTildeFor(nuT: nuT, nu: mu / rho))
                    }
                    let om = sqrt(kk) / (pow(cmu, 0.25) * max(l, 1e-12))
                    let nutSA = sqrt(1.5) * max(speed, 1e-10) * I * l
                    return (kk, om, cmu * kk * om, nutSA)
                }
            }

            for f in z.faceRange {
                let bf = f - nInternal
                let c = mesh.faceCentres[f]
                let nHat = normalized(mesh.faceAreas[f])
                let P = Int(mesh.owner[f])
                let rhoP = density?[P] ?? (setup.material(named: setup.cellZones[mesh.cellZones[Int(mesh.cellZone[P])].name]?.material ?? "air")?.density ?? 1.225)
                let muP = viscosity?[P] ?? 1.7894e-5
                switch kind[bf] {
                case .velocityInlet:
                    if s.type == .massFlowInlet {
                        let un = massFlow / max(rhoP * zoneArea[zi], 1e-300)
                        uSpec[bf] = -un * nHat
                    } else if let abl = s.atmosphericBoundaryLayer {
                        uSpec[bf] = abl.velocity(c)
                    } else if s.velocitySpecification == .magnitudeNormal {
                        uSpec[bf] = -fVelMag(c) * nHat
                    } else {
                        uSpec[bf] = Vec3(fVel[0](c), fVel[1](c), fVel[2](c))
                    }
                case .farField:
                    let dir = normalized(Vec3(s.flowDirection[0], s.flowDirection[1], s.flowDirection[2]))
                    uSpec[bf] = dir * fVelMag(c)
                    pSpec[bf] = fP(c)
                case .wall:
                    switch s.wallMotion {
                    case .stationary: uSpec[bf] = .zero
                    case .moving:
                        var v = Vec3(fWallVel[0](c), fWallVel[1](c), fWallVel[2](c))
                        v -= dot(v, nHat) * nHat // only tangential motion
                        uSpec[bf] = v
                    case .rotating:
                        let o = Vec3(s.rotationAxisOrigin[0], s.rotationAxisOrigin[1], s.rotationAxisOrigin[2])
                        let a = normalized(Vec3(s.rotationAxisDirection[0], s.rotationAxisDirection[1], s.rotationAxisDirection[2]))
                        var v = cross(s.rotationSpeed * a, c - o)
                        v -= dot(v, nHat) * nHat
                        uSpec[bf] = v
                    }
                case .pressureInlet, .pressureOutlet:
                    pSpec[bf] = fP(c)
                default: break
                }

                // Thermal
                switch kind[bf] {
                case .empty:
                    thermal.kind[bf] = .none
                case .wall, .slipWall:
                    switch s.thermalCondition {
                    case .temperature: thermal.kind[bf] = .fixedValue; thermal.value[bf] = fT(c)
                    case .heatFlux: thermal.kind[bf] = .fixedFlux; thermal.coeff[bf] = fQ(c)
                    case .adiabatic: thermal.kind[bf] = .fixedFlux; thermal.coeff[bf] = 0
                    case .convection: thermal.kind[bf] = .robin; thermal.coeff[bf] = fH(c); thermal.value[bf] = fTinf(c)
                    }
                case .velocityInlet, .pressureInlet, .farField:
                    thermal.kind[bf] = .fixedValue; thermal.value[bf] = fT(c)
                case .pressureOutlet, .outflow:
                    // backflow temperature, used only where flow enters
                    thermal.kind[bf] = .zeroGradient; thermal.value[bf] = fT(c)
                case .symmetry:
                    thermal.kind[bf] = .zeroGradient
                }

                // Turbulence
                let speed = max(norm(uSpec[bf]), kind[bf] == .velocityInlet ? 0 : s.velocityMagnitude.constantValue ?? 1)
                var tv = turbulence(speed: speed, rho: rhoP, mu: muP)
                if let abl = s.atmosphericBoundaryLayer, kind[bf] == .velocityInlet {
                    // Richards & Hoxey equilibrium profiles
                    let kk = abl.k(c), ee = abl.epsilon(c)
                    let nut = ABLProfile.kappa * abl.frictionVelocity * (abl.height(c) + abl.roughnessLength)
                    tv = (kk, ee / (ABLProfile.cmu * kk), ee, SA.nuTildeFor(nuT: nut, nu: muP / rhoP))
                }
                switch kind[bf] {
                case .empty:
                    k.kind[bf] = .none; omega.kind[bf] = .none; epsilon.kind[bf] = .none; nuTilda.kind[bf] = .none
                case .velocityInlet, .pressureInlet, .farField:
                    k.kind[bf] = .fixedValue; k.value[bf] = tv.k
                    omega.kind[bf] = .fixedValue; omega.value[bf] = tv.omega
                    epsilon.kind[bf] = .fixedValue; epsilon.value[bf] = tv.eps
                    nuTilda.kind[bf] = .fixedValue; nuTilda.value[bf] = tv.nut
                case .pressureOutlet, .outflow:
                    k.kind[bf] = .zeroGradient; k.value[bf] = tv.k
                    omega.kind[bf] = .zeroGradient; omega.value[bf] = tv.omega
                    epsilon.kind[bf] = .zeroGradient; epsilon.value[bf] = tv.eps
                    nuTilda.kind[bf] = .zeroGradient; nuTilda.value[bf] = tv.nut
                case .wall:
                    // k: zero flux (wall functions) / omega & epsilon fixed in the wall cell by the model
                    k.kind[bf] = .zeroGradient
                    omega.kind[bf] = .zeroGradient
                    epsilon.kind[bf] = .zeroGradient
                    nuTilda.kind[bf] = .fixedValue; nuTilda.value[bf] = 0
                case .slipWall, .symmetry:
                    k.kind[bf] = .zeroGradient; omega.kind[bf] = .zeroGradient
                    epsilon.kind[bf] = .zeroGradient; nuTilda.kind[bf] = .zeroGradient
                }
                _ = model

                // Passive scalars
                for (si, sc) in setup.models.passiveScalars.enumerated() {
                    switch kind[bf] {
                    case .empty: scalars[si].kind[bf] = .none
                    case .velocityInlet, .pressureInlet, .farField:
                        scalars[si].kind[bf] = .fixedValue; scalars[si].value[bf] = s.scalars[sc.name] ?? 0
                    default:
                        scalars[si].kind[bf] = .zeroGradient; scalars[si].value[bf] = s.scalars[sc.name] ?? 0
                    }
                }
            }
        }
    }
}

/// Spalart–Allmaras relation between ν̃ and νt, for inlet values of ν̃ from a viscosity ratio.
enum SA {
    static let cv1 = 7.1
    static func fv1(_ chi: Double) -> Double { let c3 = chi * chi * chi; return c3 / (c3 + cv1 * cv1 * cv1) }
    /// ν̃ such that ν̃ fv1(ν̃/ν) = νt.
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
