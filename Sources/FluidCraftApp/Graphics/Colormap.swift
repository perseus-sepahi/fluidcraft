import Foundation
import SwiftUI

/// Colour maps for contours. Each is a list of RGB stops sampled into a 256-entry table.
enum Colormap: String, CaseIterable, Identifiable, Codable {
    case rainbow = "Rainbow"
    case viridis = "Viridis"
    case coolWarm = "Cool-Warm"
    case magma = "Magma"
    case grayscale = "Grayscale"
    var id: String { rawValue }

    var stops: [SIMD3<Float>] {
        switch self {
        case .rainbow:
            // blue -> cyan -> green -> yellow -> red (classic CFD field map)
            return [SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0)]
        case .viridis:
            return [SIMD3(0.267, 0.005, 0.329), SIMD3(0.283, 0.141, 0.458), SIMD3(0.254, 0.265, 0.530), SIMD3(0.207, 0.372, 0.553),
                    SIMD3(0.164, 0.471, 0.558), SIMD3(0.128, 0.567, 0.551), SIMD3(0.135, 0.659, 0.518), SIMD3(0.267, 0.749, 0.441),
                    SIMD3(0.478, 0.821, 0.318), SIMD3(0.741, 0.873, 0.150), SIMD3(0.993, 0.906, 0.144)]
        case .coolWarm:
            return [SIMD3(0.230, 0.299, 0.754), SIMD3(0.552, 0.690, 0.996), SIMD3(0.865, 0.865, 0.865), SIMD3(0.958, 0.604, 0.482), SIMD3(0.706, 0.016, 0.150)]
        case .magma:
            return [SIMD3(0.001, 0.000, 0.014), SIMD3(0.232, 0.059, 0.437), SIMD3(0.550, 0.161, 0.506), SIMD3(0.868, 0.288, 0.409),
                    SIMD3(0.994, 0.624, 0.427), SIMD3(0.987, 0.991, 0.750)]
        case .grayscale:
            return [SIMD3(0.05, 0.05, 0.05), SIMD3(0.95, 0.95, 0.95)]
        }
    }

    /// 256 RGBA8 entries.
    var table: [UInt8] {
        let s = stops
        var out = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let t = Float(i) / 255 * Float(s.count - 1)
            let k = min(Int(t), s.count - 2)
            let f = t - Float(k)
            let c = s[k] * (1 - f) + s[k + 1] * f
            out[4 * i] = UInt8(max(0, min(255, c.x * 255)))
            out[4 * i + 1] = UInt8(max(0, min(255, c.y * 255)))
            out[4 * i + 2] = UInt8(max(0, min(255, c.z * 255)))
        }
        return out
    }

    func color(at t: Double) -> Color {
        let s = stops
        let tt = Float(max(0, min(1, t))) * Float(s.count - 1)
        let k = min(Int(tt), s.count - 2)
        let f = tt - Float(k)
        let c = s[k] * (1 - f) + s[k + 1] * f
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var gradient: SwiftUI.Gradient { SwiftUI.Gradient(colors: (0...16).map { color(at: Double($0) / 16) }) }
}
