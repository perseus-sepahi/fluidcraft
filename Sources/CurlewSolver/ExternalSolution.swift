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
    /// Density written by a compressible solver (otherwise from the materials).
    public var rho: [Double]? = nil
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
    /// Heat flux from the wall into the fluid [W/m²].
    public var bHeatFlux: [Double]? = nil
    /// Mass flux through every face, owner → neighbour [kg/s].
    public var massFlux: [Double]? = nil

    public var time = 0.0
    public var iteration = 0
    public var timeStep = 0

    public init(u: [Vec3], p: [Double]) { self.u = u; self.p = p }
}
