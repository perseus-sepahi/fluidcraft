import Foundation

/// Prism-layer (inflation) settings for 3D meshes; the layers are added by OpenFOAM's
/// snappyHexMesh (layer addition only) on the Gmsh volume mesh.
public struct InflationSettings: Codable, Sendable, Equatable {
    /// Height of the first cell at the wall.
    public var firstHeight: Double
    /// Ratio between consecutive layer heights.
    public var growth: Double
    public var layers: Int
    /// Boundary zones to inflate; empty = every zone that is a wall.
    public var zones: [String]

    public init(firstHeight: Double, growth: Double = 1.2, layers: Int = 10, zones: [String] = []) {
        self.firstHeight = firstHeight; self.growth = growth; self.layers = layers; self.zones = zones
    }

    /// Number of layers that reach `thickness` from `firstHeight` at `growth`.
    public static func layers(firstHeight h: Double, growth g: Double, thickness T: Double) -> Int {
        guard h > 0, T > h else { return 1 }
        if abs(g - 1) < 1e-9 { return max(1, Int((T / h).rounded(.up))) }
        return max(1, Int((log(1 + T * (g - 1) / h) / log(g)).rounded()))
    }

    /// Total thickness of the layer stack.
    public var targetThickness: Double {
        abs(growth - 1) < 1e-9 ? firstHeight * Double(layers) : firstHeight * (pow(growth, Double(layers)) - 1) / (growth - 1)
    }

    /// Fraction of the stack thickness below the top of layer k (k = 0 ... layers).
    public func fraction(_ k: Int) -> Double { Self.fraction(k, growth: growth, layers: layers) }

    static func fraction(_ k: Int, growth g: Double, layers n: Int) -> Double {
        abs(g - 1) < 1e-9 ? Double(k) / Double(n) : (pow(g, Double(k)) - 1) / (pow(g, Double(n)) - 1)
    }
}

/// First-cell height for a target y+, from the flat-plate correlation Cf = 0.026 Re^(-1/7).
public enum WallSpacing {
    public struct Estimate: Sendable {
        public var reynolds: Double
        public var frictionVelocity: Double
        /// Height of the first cell (its centre sits at y+ = target).
        public var firstHeight: Double
        /// Turbulent boundary-layer thickness at the reference length, 0.37 L Re^(-1/5).
        public var boundaryLayerThickness: Double
    }
    public static func estimate(yPlus: Double, velocity U: Double, length L: Double, density rho: Double, viscosity mu: Double) -> Estimate {
        let re = rho * U * L / mu
        let cf = 0.026 * pow(max(re, 1), -1.0 / 7.0)
        let tau = 0.5 * cf * rho * U * U
        let ut = sqrt(tau / rho)
        let yc = yPlus * mu / (rho * max(ut, 1e-300))
        return Estimate(reynolds: re, frictionVelocity: ut, firstHeight: 2 * yc, boundaryLayerThickness: 0.37 * L * pow(max(re, 1), -0.2))
    }
}
