import Foundation
import CurlewMesh

/// Built-in material database (SI units, properties near 300 K / 1 atm unless noted).
public enum MaterialLibrary {
    static func fluid(_ name: String, rho: Double, mu: Double, cp: Double, k: Double, beta: Double = 0, mw: Double = 28.966,
                      method: DensityMethod = .constant) -> Material {
        var m = Material(name: name)
        m.kind = .fluid; m.density = rho; m.viscosity = mu; m.specificHeat = cp; m.thermalConductivity = k
        m.thermalExpansion = beta; m.molecularWeight = mw; m.densityMethod = method
        return m
    }
    static func solid(_ name: String, rho: Double, cp: Double, k: Double) -> Material {
        var m = Material(name: name)
        m.kind = .solid; m.density = rho; m.specificHeat = cp; m.thermalConductivity = k
        m.viscosity = 0; m.thermalExpansion = 0
        return m
    }

    /// Materials present in a new case (Fluent starts with air and aluminum).
    public static var defaults: [Material] {
        [all.first { $0.name == "air" }!, all.first { $0.name == "aluminum" }!]
    }

    public static let all: [Material] = [
        fluid("air", rho: 1.225, mu: 1.7894e-5, cp: 1006.43, k: 0.0242, beta: 3.4e-3, mw: 28.966),
        fluid("water-liquid", rho: 998.2, mu: 1.003e-3, cp: 4182, k: 0.6, beta: 2.07e-4, mw: 18.0152),
        fluid("water-vapor", rho: 0.5542, mu: 1.34e-5, cp: 2014, k: 0.0261, mw: 18.01534),
        fluid("nitrogen", rho: 1.138, mu: 1.663e-5, cp: 1040.67, k: 0.0242, beta: 3.3e-3, mw: 28.0134),
        fluid("oxygen", rho: 1.2999, mu: 1.919e-5, cp: 919.31, k: 0.0246, beta: 3.3e-3, mw: 31.9988),
        fluid("carbon-dioxide", rho: 1.7878, mu: 1.37e-5, cp: 840.37, k: 0.0145, beta: 3.4e-3, mw: 44.00995),
        fluid("helium", rho: 0.1625, mu: 1.99e-5, cp: 5193, k: 0.152, beta: 3.3e-3, mw: 4.0026),
        fluid("hydrogen", rho: 0.08189, mu: 8.411e-6, cp: 14283, k: 0.1672, beta: 3.3e-3, mw: 2.01594),
        fluid("methane", rho: 0.6679, mu: 1.087e-5, cp: 2222, k: 0.0332, beta: 3.4e-3, mw: 16.04303),
        fluid("argon", rho: 1.6228, mu: 2.125e-5, cp: 520.64, k: 0.0158, beta: 3.3e-3, mw: 39.948),
        fluid("engine-oil", rho: 884.1, mu: 0.486, cp: 1909, k: 0.145, beta: 7e-4, mw: 300),
        fluid("glycerin", rho: 1259.9, mu: 0.799, cp: 2427, k: 0.286, beta: 4.8e-4, mw: 92.09),
        fluid("ethylene-glycol", rho: 1111.4, mu: 0.0157, cp: 2415, k: 0.252, beta: 6.5e-4, mw: 62.068),
        fluid("mercury", rho: 13529, mu: 1.523e-3, cp: 139.3, k: 8.54, beta: 1.81e-4, mw: 200.59),
        fluid("kerosene", rho: 780, mu: 2.4e-3, cp: 2090, k: 0.149, beta: 9.9e-4, mw: 167.31),
        fluid("blood", rho: 1060, mu: 3.5e-3, cp: 3617, k: 0.52, mw: 18),
        solid("aluminum", rho: 2719, cp: 871, k: 202.4),
        solid("copper", rho: 8978, cp: 381, k: 387.6),
        solid("steel", rho: 8030, cp: 502.48, k: 16.27),
        solid("iron", rho: 7870, cp: 447, k: 80.2),
        solid("silicon", rho: 2330, cp: 712, k: 148),
        solid("glass", rho: 2500, cp: 840, k: 1.4),
        solid("concrete", rho: 2300, cp: 880, k: 1.4),
        solid("wood", rho: 700, cp: 2310, k: 0.173),
        solid("fr4", rho: 1850, cp: 1100, k: 0.3),
        solid("titanium", rho: 4850, cp: 544.25, k: 7.44),
    ]

    public static func lookup(_ name: String) -> Material? { all.first { $0.name == name } }
}
