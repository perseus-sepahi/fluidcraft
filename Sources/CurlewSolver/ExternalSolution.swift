import Foundation
import CurlewMesh

/// Fields computed by another code (OpenFOAM) on exactly this mesh: same cell order, same
/// face order. Everything is in Curlew's conventions already (gauge pressure in Pa, dynamic
/// viscosities, mass fluxes in kg/s, wall shear as the force per area the fluid exerts on the
/// wall); the reader converts units before filling this in.
public struct ExternalSolution: Sendable {
    public var u: [Vec3]
    public var p: [Double]
    public var T: [Double]? = nil
    public var k: [Double]? = nil
    public var omega: [Double]? = nil
    public var epsilon: [Double]? = nil
    public var nuTilda: [Double]? = nil
    /// Turbulent (eddy) dynamic viscosity rho*nut.
    public var muT: [Double]? = nil
    /// Passive scalars by name.
    public var scalars: [String: [Double]] = [:]

    /// Boundary-face values (index = face - nInternalFaces); nil entries fall back to Curlew's
    /// own boundary treatment of the loaded cell values.
    public var bU: [Vec3]? = nil
    public var bP: [Double]? = nil
    public var bT: [Double]? = nil
    public var bK: [Double]? = nil
    public var bOmega: [Double]? = nil
    public var bEpsilon: [Double]? = nil
    public var bNuTilda: [Double]? = nil
    public var bScalars: [String: [Double]] = [:]
    public var bWallShear: [Vec3]? = nil
    public var bYPlus: [Double]? = nil
    /// Mass flux through every face, owner → neighbour [kg/s].
    public var massFlux: [Double]? = nil

    public var time = 0.0
    public var iteration = 0
    public var timeStep = 0

    public init(u: [Vec3], p: [Double]) { self.u = u; self.p = p }
}

extension PressureBasedSolver {
    /// Replace the solution with fields computed elsewhere on this mesh, then rebuild
    /// everything Curlew derives from them (properties, gradients, wall quantities), so
    /// contours, vectors, pathlines, reports and XY plots work as for a Curlew run.
    public func load(external e: ExternalSolution) throws {
        let n = mesh.nCells, nB = mesh.nBoundaryFaces, nF = mesh.nFaces
        func check(_ a: Int, _ want: Int, _ what: String) throws {
            guard a == want else { throw SolverError("\(what): \(a) values for \(want) \(what.hasPrefix("b") ? "boundary faces" : "cells")") }
        }
        try check(e.u.count, n, "U"); try check(e.p.count, n, "p")
        let st = state
        st.u = e.u
        st.p = e.p
        if let v = e.T { try check(v.count, n, "T"); st.T = v }
        if let v = e.k { try check(v.count, n, "k"); st.k = v }
        if let v = e.omega { try check(v.count, n, "omega"); st.omega = v }
        if let v = e.epsilon { try check(v.count, n, "epsilon"); st.epsilon = v }
        if let v = e.nuTilda { try check(v.count, n, "nuTilda"); st.nuTilda = v }
        if let v = e.muT { try check(v.count, n, "nut"); st.muT = v }
        for (i, sc) in setup.models.passiveScalars.enumerated() where i < st.scalars.count {
            if let v = e.scalars[sc.name], v.count == n { st.scalars[i] = v }
        }
        updateProperties()
        // Boundary values: Curlew's treatment of the loaded cells first, then whatever the
        // other code wrote explicitly on top of it.
        updateFlowBoundaries()
        let nI = mesh.nInternalFaces
        for f in nI..<nF {
            let P = Int(mesh.owner[f]), bf = f - nI
            st.bT[bf] = st.T[P]; st.bK[bf] = st.k[P]; st.bOmega[bf] = st.omega[P]
            st.bEpsilon[bf] = st.epsilon[P]; st.bNuTilda[bf] = st.nuTilda[P]
            for i in 0..<st.bScalars.count { st.bScalars[i][bf] = st.scalars[i][P] }
        }
        if let v = e.bU, v.count == nB { st.bU = v }
        if let v = e.bP, v.count == nB { st.bP = v }
        if let v = e.bT, v.count == nB { st.bT = v }
        if let v = e.bK, v.count == nB { st.bK = v }
        if let v = e.bOmega, v.count == nB { st.bOmega = v }
        if let v = e.bEpsilon, v.count == nB { st.bEpsilon = v }
        if let v = e.bNuTilda, v.count == nB { st.bNuTilda = v }
        for (i, sc) in setup.models.passiveScalars.enumerated() where i < st.bScalars.count {
            if let v = e.bScalars[sc.name], v.count == nB { st.bScalars[i] = v }
        }
        if let mf = e.massFlux, mf.count == nF {
            st.massFlux = mf
        } else {
            // Linear interpolation of rho*u to internal faces; boundary faces from the face values.
            for f in 0..<nI {
                let P = Int(mesh.owner[f]), N = Int(mesh.neighbour[f])
                let w = geo.weight[f]
                let rho = w * st.rho[P] + (1 - w) * st.rho[N]
                st.massFlux[f] = rho * dot(w * st.u[P] + (1 - w) * st.u[N], mesh.faceAreas[f])
            }
            for f in nI..<nF {
                st.massFlux[f] = st.rho[Int(mesh.owner[f])] * dot(st.bU[f - nI], mesh.faceAreas[f])
            }
        }
        computeGradients()
        if setup.models.viscous.isTurbulent { updateWallFunctions() } else { updateLaminarWalls() }
        if let v = e.bWallShear, v.count == nB {
            for w in walls where !w.isInterface { st.bWallShear[w.face - nI] = v[w.face - nI] }
        }
        if let v = e.bYPlus, v.count == nB {
            for w in walls where !w.isInterface { st.bYPlus[w.face - nI] = v[w.face - nI] }
        }
        // Wall heat flux into the fluid from the loaded temperatures, with the same wall
        // conductivity (thermal wall function for turbulent flow) the Curlew energy solver uses.
        if e.T != nil {
            for f in nI..<nF {
                let bf = f - nI, P = Int(mesh.owner[f])
                guard bc.kind[bf] == .wall || bc.kind[bf] == .slipWall else { continue }
                var ke = st.conductivity[P]
                if setup.models.viscous.isTurbulent, wallIndexOfBoundary[bf] >= 0 { ke = wallConductivity(Int(wallIndexOfBoundary[bf]), cell: P) }
                st.bHeatFlux[bf] = ke * (st.bT[bf] - st.T[P]) / geo.normalDistance(f)
            }
        }
        st.time = e.time
        st.iteration = e.iteration
        st.timeStep = e.timeStep
    }
}
