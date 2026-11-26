import Foundation
import FluidCraftMesh

/// Named solution quantities (Fluent field-function names) on cells and boundary faces.
public enum FieldCatalog {
    public static func available(for s: Solution) -> [String] {
        var out = ["pressure", "total-pressure", "pressure-coefficient", "velocity-magnitude", "x-velocity", "y-velocity", "z-velocity",
                   "vorticity-magnitude", "strain-rate", "q-criterion", "density", "viscosity", "cell-volume", "orthogonal-quality"]
        if s.setup.models.energy || s.zoneMaterial.contains(where: { $0.densityMethod != .constant }) {
            out += ["temperature", "wall-heat-flux"]
        }
        if s.setup.models.viscous.isTurbulent {
            out += ["turbulent-viscosity", "turbulent-viscosity-ratio", "turbulent-kinetic-energy", "turbulence-intensity"]
            if s.setup.models.viscous.usesOmega { out.append("specific-dissipation-rate") }
            if s.setup.models.viscous.usesEpsilon { out.append("turbulent-dissipation-rate") }
            if s.setup.models.viscous == .spalartAllmaras { out.append("modified-turbulent-viscosity") }
        }
        out += ["wall-shear-stress", "skin-friction-coefficient", "y-plus"]
        if s.isDensityBased || s.zoneMaterial.contains(where: { $0.densityMethod == .idealGas }) {
            out += ["mach-number"]
            if !out.contains("temperature") { out.append("temperature") }
        }
        if s.isTransient && s.setup.run.dataSampling { out += ["mean-velocity-magnitude", "mean-pressure"] }
        out += s.setup.models.passiveScalars.map(\.name)
        return out
    }

    /// Cell values of a named field, or nil if unknown.
    public static func cellValues(_ name: String, _ s: Solution) -> [Double]? {
        let st = s.state
        let n = s.mesh.nCells
        let ref = s.setup.reference
        switch name {
        case "pressure", "static-pressure": return st.p
        case "total-pressure": return (0..<n).map { st.p[$0] + 0.5 * st.rho[$0] * lengthSquared(st.u[$0]) }
        case "pressure-coefficient":
            let q = 0.5 * ref.density * ref.velocity * ref.velocity
            return st.p.map { ($0 - ref.pressure) / max(q, 1e-300) }
        case "velocity-magnitude": return st.u.map { norm($0) }
        case "x-velocity": return st.u.map { $0.x }
        case "y-velocity": return st.u.map { $0.y }
        case "z-velocity": return st.u.map { $0.z }
        case "temperature", "static-temperature": return st.T
        case "density": return st.rho
        case "viscosity", "molecular-viscosity": return st.mu
        case "turbulent-viscosity": return st.muT
        case "turbulent-viscosity-ratio": return (0..<n).map { st.muT[$0] / max(st.mu[$0], 1e-300) }
        case "turbulent-kinetic-energy", "k": return st.k
        case "specific-dissipation-rate", "omega": return st.omega
        case "turbulent-dissipation-rate", "epsilon": return st.epsilon
        case "modified-turbulent-viscosity": return st.nuTilda
        case "turbulence-intensity":
            let U = max(ref.velocity, 1e-300)
            return st.k.map { sqrt(2.0 / 3.0 * max($0, 0)) / U }
        case "cell-volume": return s.mesh.cellVolumes
        case "mach-number":
            let g = s.gasGamma, R = s.gasR
            return (0..<n).map { norm(st.u[$0]) / sqrt(g * R * max(st.T[$0], 1e-6)) }
        case "orthogonal-quality": return MeshQuality.orthogonalQuality(s.mesh)
        case "vorticity-magnitude", "strain-rate", "q-criterion":
            guard s.gradU[0].count == n else { return [Double](repeating: 0, count: n) }
            return (0..<n).map { c in
                let gx = s.gradU[0][c], gy = s.gradU[1][c], gz = s.gradU[2][c]
                let wx = gz.y - gy.z, wy = gx.z - gz.x, wz = gy.x - gx.y
                let vort = sqrt(wx * wx + wy * wy + wz * wz)
                if name == "vorticity-magnitude" { return vort }
                let sr = s.strainRateMagnitude(c)
                if name == "strain-rate" { return sr }
                // Q = 0.5 (|Omega|^2 - |S|^2) with |Omega|^2 = vort^2/2*2, |S|^2 = sr^2/2
                return 0.25 * (vort * vort - sr * sr)
            }
        case "mean-velocity-magnitude": return st.meanU.isEmpty ? nil : st.meanU.map { norm($0) }
        case "mean-pressure": return st.meanP.isEmpty ? nil : st.meanP
        case "wall-shear-stress", "skin-friction-coefficient", "y-plus", "wall-heat-flux":
            // cell values: zero away from walls, wall value in wall cells
            guard let fv = boundaryValues(name, s) else { return nil }
            var out = [Double](repeating: 0, count: n)
            let nI = s.mesh.nInternalFaces
            for bf in 0..<fv.count where s.bc.kind[bf] == .wall { out[Int(s.mesh.owner[bf + nI])] = fv[bf] }
            return out
        default:
            if let si = s.setup.models.passiveScalars.firstIndex(where: { $0.name == name }) { return st.scalars[si] }
            return nil
        }
    }

    /// Values on every boundary face (index face - nInternal).
    public static func boundaryValues(_ name: String, _ s: Solution) -> [Double]? {
        let st = s.state
        let ref = s.setup.reference
        let nI = s.mesh.nInternalFaces
        let nB = s.mesh.nBoundaryFaces
        func owner(_ bf: Int) -> Int { Int(s.mesh.owner[bf + nI]) }
        switch name {
        case "pressure", "static-pressure": return st.bP
        case "total-pressure": return (0..<nB).map { st.bP[$0] + 0.5 * st.rho[owner($0)] * lengthSquared(st.bU[$0]) }
        case "pressure-coefficient":
            let q = 0.5 * ref.density * ref.velocity * ref.velocity
            return st.bP.map { ($0 - ref.pressure) / max(q, 1e-300) }
        case "velocity-magnitude": return st.bU.map { norm($0) }
        case "x-velocity": return st.bU.map { $0.x }
        case "y-velocity": return st.bU.map { $0.y }
        case "z-velocity": return st.bU.map { $0.z }
        case "temperature", "static-temperature": return st.bT
        case "wall-shear-stress": return st.bWallShear.map { norm($0) }
        case "skin-friction-coefficient":
            let q = 0.5 * ref.density * ref.velocity * ref.velocity
            return st.bWallShear.map { norm($0) / max(q, 1e-300) }
        case "y-plus": return st.bYPlus
        case "wall-heat-flux": return st.bHeatFlux
        case "turbulent-kinetic-energy", "k": return st.bK
        case "specific-dissipation-rate", "omega": return st.bOmega
        case "turbulent-dissipation-rate", "epsilon": return st.bEpsilon
        default:
            if let si = s.setup.models.passiveScalars.firstIndex(where: { $0.name == name }) { return st.bScalars[si] }
            guard let cv = cellValues(name, s) else { return nil }
            return (0..<nB).map { cv[owner($0)] }
        }
    }
}

