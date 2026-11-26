import Foundation
import FluidCraftMesh

/// FluidCraft's standard initialization: uniform values (or expressions of x, y, z, or the values
/// of a boundary zone) plus patched regions. The result is written as OpenFOAM's `0/` fields.
/// Hybrid initialization is OpenFOAM's `potentialFoam`, run as the first stage of the solve.
public enum InitialFields {
    /// The setup's initial fields need computing in FluidCraft: standard initialization, patches,
    /// or hybrid initialization where potentialFoam cannot run (compressible, thermal or
    /// multi-region cases, or no inflow) — then the fields start from the inlet conditions.
    public static func computedByFluidCraft(_ setup: CaseSetup, potentialFoamRuns: Bool) -> Bool {
        setup.initialization.method == .standard || !setup.initialization.patches.isEmpty || !potentialFoamRuns
    }

    static func fill(_ s: Solution) {
        let setup = s.setup, m = s.mesh, st = s.state, bc = s.bc
        let nC = m.nCells, nI = m.nInternalFaces
        let ini = setup.initialization
        func q(_ v: Quantity, _ c: Vec3) -> Double {
            switch v {
            case .constant(let d): return d
            case .expression(let e): return (try? Expr(e, named: s.exprs).value(x: c.x, y: c.y, z: c.z, t: 0)) ?? 0
            }
        }
        // inlet averages (hybrid defaults); temperature falls back to fixed-temperature walls
        var inletArea = 0.0, avgT = 0.0, avgK = 0.0, avgOm = 0.0, avgEps = 0.0, avgNut = 0.0, avgU = Vec3.zero
        var outletArea = 0.0, avgP = 0.0, tArea = 0.0, tSum = 0.0
        // compressible far fields are given by Mach number and direction (as OpenFOAM is told)
        let compressible = s.zoneMaterial.contains { $0.kind == .fluid && $0.densityMethod == .idealGas }
        func inflowVelocity(_ bf: Int) -> Vec3 {
            guard bc.kind[bf] == .farField, compressible else { return bc.uSpec[bf] }
            let b = bc.zoneSettings[Int(bc.zone[bf])]
            let d = b.flowDirection.count == 3 ? normalized(Vec3(b.flowDirection[0], b.flowDirection[1], b.flowDirection[2])) : Vec3(1, 0, 0)
            return d * b.machNumber * sqrt(s.gasGamma * s.gasR * max(bc.thermal.value[bf], 1))
        }
        for f in nI..<m.nFaces {
            let bf = f - nI, a = m.faceAreaMag[f]
            switch bc.kind[bf] {
            case .velocityInlet, .pressureInlet, .farField:
                inletArea += a
                avgU += a * inflowVelocity(bf)
                avgT += a * bc.thermal.value[bf]
                avgK += a * bc.k.value[bf]; avgOm += a * bc.omega.value[bf]
                avgEps += a * bc.epsilon.value[bf]; avgNut += a * bc.nuTilda.value[bf]
            case .pressureOutlet:
                outletArea += a; avgP += a * bc.pSpec[bf]
            default: break
            }
            if bc.thermal.kind[bf] == .fixedValue { tArea += a; tSum += a * bc.thermal.value[bf] }
        }
        var u0: Vec3? = nil, p0: Double? = nil, T0: Double? = nil
        var k0 = ini.k, om0 = ini.omega, eps0 = ini.epsilon, nut0 = ini.modifiedTurbulentViscosity
        if ini.method == .hybrid {
            // uniform free stream from the inlets (potentialFoam refines U where it can run)
            if inletArea > 0 {
                u0 = avgU / inletArea
                T0 = avgT / inletArea; k0 = avgK / inletArea; om0 = avgOm / inletArea
                eps0 = avgEps / inletArea; nut0 = avgNut / inletArea
            } else if tArea > 0 {
                T0 = tSum / tArea
            }
            if outletArea > 0 { p0 = avgP / outletArea }
        }
        if !ini.computeFrom.isEmpty, let z = m.boundaryZones.first(where: { $0.name == ini.computeFrom }), let f = z.faceRange.first {
            let bf = f - nI
            u0 = bc.uSpec[bf]; p0 = bc.pSpec[bf]; T0 = bc.thermal.value[bf]
            k0 = bc.k.value[bf]; om0 = bc.omega.value[bf]; eps0 = bc.epsilon.value[bf]; nut0 = bc.nuTilda.value[bf]
        }
        for c in 0..<nC {
            let cc = m.cellCentres[c]
            st.u[c] = u0 ?? Vec3(q(ini.velocity[0], cc), q(ini.velocity[1], cc), q(ini.velocity[2], cc))
            st.p[c] = p0 ?? q(ini.gaugePressure, cc)
            st.T[c] = T0 ?? q(ini.temperature, cc)
            st.k[c] = k0; st.omega[c] = om0; st.epsilon[c] = eps0; st.nuTilda[c] = nut0
            st.muT[c] = 0
        }
        for c in 0..<nC where s.isSolidCell[c] { st.u[c] = .zero }
        if let ax = m.twoDimensionalAxis { for c in 0..<nC { st.u[c][ax] = 0 } }
        for si in 0..<st.scalars.count { for c in 0..<nC { st.scalars[si][c] = 0 } }
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
    }

    public static func inside(_ p: PatchSettings, _ c: Vec3) -> Bool {
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
}
