import Foundation
import FluidCraftMesh

/// Solution fields of a pressure-based run. Cell arrays have `nCells` entries,
/// boundary arrays `nBoundaryFaces` entries (index = face - nInternalFaces),
/// face arrays `nFaces`.
public final class FlowState: @unchecked Sendable {
    public let nCells: Int
    public let nBoundary: Int
    public let nFaces: Int

    public var u: [Vec3]
    public var p: [Double]
    public var T: [Double]
    public var k: [Double]
    public var omega: [Double]
    public var epsilon: [Double]
    public var nuTilda: [Double]
    public var muT: [Double]
    public var scalars: [[Double]] = []

    public var rho: [Double]
    public var mu: [Double]
    public var cp: [Double]
    public var conductivity: [Double]

    public var bU: [Vec3]
    public var bP: [Double]
    public var bT: [Double]
    public var bK: [Double]
    public var bOmega: [Double]
    public var bEpsilon: [Double]
    public var bNuTilda: [Double]
    public var bScalars: [[Double]] = []
    /// Effective wall viscosity used for momentum at wall faces (wall functions).
    public var bMuWall: [Double]
    /// Wall shear stress vector (on wall faces) and heat flux into the fluid [W/m2].
    public var bWallShear: [Vec3]
    public var bHeatFlux: [Double]
    public var bYPlus: [Double]

    /// Mass flux through each face, owner -> neighbour (kg/s).
    public var massFlux: [Double]

    // Previous time levels (transient)
    public var uOld: [Vec3] = [], uOldOld: [Vec3] = []
    public var TOld: [Double] = [], TOldOld: [Double] = []
    public var kOld: [Double] = [], kOldOld: [Double] = []
    public var omegaOld: [Double] = [], omegaOldOld: [Double] = []
    public var epsOld: [Double] = [], epsOldOld: [Double] = []
    public var nutOld: [Double] = [], nutOldOld: [Double] = []
    public var scalarsOld: [[Double]] = [], scalarsOldOld: [[Double]] = []
    public var massFluxOld: [Double] = [], massFluxOldOld: [Double] = []
    public var rhoOld: [Double] = [], rhoOldOld: [Double] = []

    // Time statistics
    public var meanU: [Vec3] = []
    public var meanP: [Double] = []
    public var samples = 0

    public var time = 0.0
    public var timeStep = 0
    public var iteration = 0
    /// These are initial fields (FluidCraft's initialization), not a solution: OpenFOAM may still
    /// run potentialFoam on them.
    public var isInitialization = false

    public init(nCells: Int, nBoundary: Int, nFaces: Int) {
        self.nCells = nCells; self.nBoundary = nBoundary; self.nFaces = nFaces
        let zc = [Double](repeating: 0, count: nCells)
        let zb = [Double](repeating: 0, count: nBoundary)
        u = [Vec3](repeating: .zero, count: nCells)
        p = zc; T = [Double](repeating: 300, count: nCells)
        k = zc; omega = zc; epsilon = zc; nuTilda = zc; muT = zc
        rho = [Double](repeating: 1, count: nCells); mu = zc; cp = zc; conductivity = zc
        bU = [Vec3](repeating: .zero, count: nBoundary)
        bP = zb; bT = [Double](repeating: 300, count: nBoundary)
        bK = zb; bOmega = zb; bEpsilon = zb; bNuTilda = zb; bMuWall = zb
        bWallShear = [Vec3](repeating: .zero, count: nBoundary)
        bHeatFlux = zb; bYPlus = zb
        massFlux = [Double](repeating: 0, count: nFaces)
    }

    /// Shift current fields into the old time levels.
    public func storeOldTime() {
        uOldOld = uOld.isEmpty ? u : uOld; uOld = u
        TOldOld = TOld.isEmpty ? T : TOld; TOld = T
        kOldOld = kOld.isEmpty ? k : kOld; kOld = k
        omegaOldOld = omegaOld.isEmpty ? omega : omegaOld; omegaOld = omega
        epsOldOld = epsOld.isEmpty ? epsilon : epsOld; epsOld = epsilon
        nutOldOld = nutOld.isEmpty ? nuTilda : nutOld; nutOld = nuTilda
        scalarsOldOld = scalarsOld.isEmpty ? scalars : scalarsOld; scalarsOld = scalars
        massFluxOldOld = massFluxOld.isEmpty ? massFlux : massFluxOld; massFluxOld = massFlux
        rhoOldOld = rhoOld.isEmpty ? rho : rhoOld; rhoOld = rho
    }
}
