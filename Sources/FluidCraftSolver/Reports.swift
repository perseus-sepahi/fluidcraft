import Foundation
import FluidCraftMesh

/// Surface, volume and force report evaluation (Fluent report definitions).
public enum Reports {
    public static func zoneFaces(_ zones: [String], _ s: Solution) -> [Int] {
        let m = s.mesh
        let selected = zones.isEmpty ? m.boundaryZones.filter { $0.kind != .empty } : m.boundaryZones.filter { zones.contains($0.name) }
        return selected.flatMap { Array($0.faceRange) }
    }

    public static func evaluate(_ r: ReportDefinition, solver s: Solution) -> Double {
        let m = s.mesh
        let nI = m.nInternalFaces
        let st = s.state
        switch r.kind {
        case .areaWeightedAverage, .integral, .massWeightedAverage:
            guard let v = FieldCatalog.boundaryValues(r.field, s) else { return .nan }
            var num = 0.0, den = 0.0
            for f in zoneFaces(r.zones, s) {
                let w = r.kind == .massWeightedAverage ? abs(st.massFlux[f]) : m.faceAreaMag[f]
                num += w * v[f - nI]; den += w
            }
            return r.kind == .integral ? num : (den > 0 ? num / den : 0)
        case .massFlowRate:
            return zoneFaces(r.zones, s).reduce(0) { $0 + st.massFlux[$1] }
        case .volumeAverage, .volumeMaximum, .volumeMinimum:
            guard let v = FieldCatalog.cellValues(r.field, s) else { return .nan }
            let zoneIdx = Set(m.cellZones.enumerated().filter { r.zones.isEmpty || r.zones.contains($0.element.name) }.map { Int32($0.offset) })
            var num = 0.0, den = 0.0, mx = -Double.infinity, mn = Double.infinity
            for c in 0..<m.nCells where zoneIdx.contains(m.cellZone[c]) {
                num += v[c] * m.cellVolumes[c]; den += m.cellVolumes[c]
                mx = max(mx, v[c]); mn = min(mn, v[c])
            }
            switch r.kind {
            case .volumeMaximum: return mx
            case .volumeMinimum: return mn
            default: return den > 0 ? num / den : 0
            }
        case .force, .dragCoefficient, .liftCoefficient, .momentCoefficient:
            let (F, M) = forces(r.zones, s, centre: Vec3(r.momentCentre[0], r.momentCentre[1], r.momentCentre[2]))
            let dir = normalized(Vec3(r.direction[0], r.direction[1], r.direction[2]))
            let ref = s.setup.reference
            let q = 0.5 * ref.density * ref.velocity * ref.velocity
            switch r.kind {
            case .force: return dot(F.pressure + F.viscous, dir)
            case .momentCoefficient: return dot(M, dir) / max(q * ref.area * ref.length, 1e-300)
            default: return dot(F.pressure + F.viscous, dir) / max(q * ref.area, 1e-300)
            }
        case .heatTransferRate:
            var total = 0.0
            for f in zoneFaces(r.zones, s) {
                let bf = f - nI
                let P = Int(m.owner[f])
                switch s.bc.kind[bf] {
                case .wall, .slipWall: total += st.bHeatFlux[bf] * m.faceAreaMag[f]
                case .empty, .symmetry: break
                default: total -= st.massFlux[f] * st.cp[P] * (st.bT[bf] - 298.15)
                }
            }
            return total
        case .expression:
            guard let e = try? Expr(r.expression, named: s.exprs) else { return .nan }
            return e.value(t: st.time)
        }
    }

    public struct ForceSplit: Sendable { public var pressure: Vec3; public var viscous: Vec3 }

    /// Pressure and viscous force exerted by the fluid on wall zones, and the total moment about `centre`.
    public static func forces(_ zones: [String], _ s: Solution, centre: Vec3 = .zero) -> (ForceSplit, Vec3) {
        let m = s.mesh
        let nI = m.nInternalFaces
        let pref = s.setup.reference.pressure
        var fp = Vec3.zero, fv = Vec3.zero, mom = Vec3.zero
        for f in zoneFaces(zones, s) {
            let bf = f - nI
            guard s.bc.kind[bf] == .wall || s.bc.kind[bf] == .slipWall || !zones.isEmpty else { continue }
            let pF = (s.state.bP[bf] - pref) * m.faceAreas[f]
            let vF = s.state.bWallShear[bf] * m.faceAreaMag[f]
            fp += pF; fv += vF
            mom += cross(m.faceCentres[f] - centre, pF + vF)
        }
        return (ForceSplit(pressure: fp, viscous: fv), mom)
    }
}
