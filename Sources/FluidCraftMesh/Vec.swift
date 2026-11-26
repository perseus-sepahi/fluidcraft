import Foundation
import simd

public typealias Vec3 = SIMD3<Double>

@inline(__always) public func dot(_ a: Vec3, _ b: Vec3) -> Double { simd_dot(a, b) }
@inline(__always) public func cross(_ a: Vec3, _ b: Vec3) -> Vec3 { simd_cross(a, b) }
@inline(__always) public func norm(_ a: Vec3) -> Double { simd_length(a) }
@inline(__always) public func lengthSquared(_ a: Vec3) -> Double { simd_length_squared(a) }
@inline(__always) public func normalized(_ a: Vec3) -> Vec3 {
    let l = simd_length(a)
    return l > 0 ? a / l : .zero
}

/// Symmetric 3x3 tensor stored as (xx, yy, zz, xy, xz, yz).
public struct SymTensor: Equatable, Sendable {
    public var xx, yy, zz, xy, xz, yz: Double
    public init(xx: Double = 0, yy: Double = 0, zz: Double = 0, xy: Double = 0, xz: Double = 0, yz: Double = 0) {
        self.xx = xx; self.yy = yy; self.zz = zz; self.xy = xy; self.xz = xz; self.yz = yz
    }
    @inline(__always) public mutating func addOuter(_ d: Vec3, weight w: Double) {
        xx += w * d.x * d.x; yy += w * d.y * d.y; zz += w * d.z * d.z
        xy += w * d.x * d.y; xz += w * d.x * d.z; yz += w * d.y * d.z
    }
    public var determinant: Double {
        xx * (yy * zz - yz * yz) - xy * (xy * zz - yz * xz) + xz * (xy * yz - yy * xz)
    }
    /// Inverse of a symmetric matrix; returns nil if (near) singular relative to its scale.
    public func inverse() -> SymTensor? {
        let det = determinant
        let scale = max(abs(xx), abs(yy), abs(zz), 1e-300)
        guard abs(det) > 1e-12 * scale * scale * scale else { return nil }
        let inv = 1 / det
        return SymTensor(
            xx: (yy * zz - yz * yz) * inv,
            yy: (xx * zz - xz * xz) * inv,
            zz: (xx * yy - xy * xy) * inv,
            xy: (xz * yz - xy * zz) * inv,
            xz: (xy * yz - xz * yy) * inv,
            yz: (xy * xz - xx * yz) * inv)
    }
    @inline(__always) public func times(_ v: Vec3) -> Vec3 {
        Vec3(xx * v.x + xy * v.y + xz * v.z,
             xy * v.x + yy * v.y + yz * v.z,
             xz * v.x + yz * v.y + zz * v.z)
    }
}

/// Axis-aligned bounding box.
public struct BoundingBox: Equatable, Sendable, Codable {
    public var min: Vec3
    public var max: Vec3
    public init(min: Vec3, max: Vec3) { self.min = min; self.max = max }
    public static let empty = BoundingBox(min: Vec3(repeating: .infinity), max: Vec3(repeating: -.infinity))
    public var isEmpty: Bool { min.x > max.x }
    public mutating func include(_ p: Vec3) { min = simd_min(min, p); max = simd_max(max, p) }
    public var size: Vec3 { isEmpty ? .zero : max - min }
    public var centre: Vec3 { (min + max) * 0.5 }
    public var diagonal: Double { norm(size) }
    public init<S: Sequence>(points: S) where S.Element == Vec3 {
        var b = BoundingBox.empty
        for p in points { b.include(p) }
        self = b
    }
}
