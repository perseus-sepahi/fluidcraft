import Foundation

/// Prism-layer (inflation) settings for 3D meshes.
public struct InflationSettings: Codable, Sendable, Equatable {
    /// Height of the first cell at the wall.
    public var firstHeight: Double
    /// Ratio between consecutive layer heights.
    public var growth: Double
    public var layers: Int
    /// Boundary zones to inflate; empty = every zone that is a wall.
    public var zones: [String]
    /// The layer stack may be at most this many local wall-cell heights thick; the
    /// displacement is spread over `bandDepth` cell layers, so values above 1 are fine.
    public var maxCellHeights: Double
    /// Cell layers (graph hops) over which the volume mesh absorbs the displacement.
    public var bandDepth: Int
    public var smoothingIterations: Int

    public init(firstHeight: Double, growth: Double = 1.2, layers: Int = 10, zones: [String] = [],
                maxCellHeights: Double = 2, bandDepth: Int = 8, smoothingIterations: Int = 60) {
        self.firstHeight = firstHeight; self.growth = growth; self.layers = layers; self.zones = zones
        self.maxCellHeights = maxCellHeights; self.bandDepth = bandDepth; self.smoothingIterations = smoothingIterations
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

    /// Layer fractions for a stack of thickness `T`: a thinner stack keeps the first-cell
    /// height (so y+ is unchanged) and lowers the growth ratio; below `layers × firstHeight`
    /// the layers become uniform.
    public func fractions(thickness T: Double) -> [Double] {
        let n = layers
        var g = growth
        if T < targetThickness * (1 - 1e-9) {
            if T <= Double(n) * firstHeight || growth <= 1 { g = 1 }
            else {
                var lo = 1.0, hi = growth
                for _ in 0..<60 {
                    let mid = 0.5 * (lo + hi)
                    let t = firstHeight * (pow(mid, Double(n)) - 1) / (mid - 1)
                    if t > T { hi = mid } else { lo = mid }
                }
                g = 0.5 * (lo + hi)
            }
        }
        return (0...n).map { Self.fraction($0, growth: g, layers: n) }
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

public struct InflationReport: Sendable, CustomStringConvertible {
    public var wallFaces = 0
    public var prisms = 0
    public var layers = 0
    public var targetThickness = 0.0
    public var meanThickness = 0.0
    public var minThickness = 0.0
    /// Fraction of wall nodes that received at least 95 % of the target thickness.
    public var coverage = 0.0
    public var relaxationRounds = 0
    /// Height of the last (outermost) layer where the full thickness was reached.
    public var lastLayerHeight = 0.0
    /// Mean height of the volume cells that sat on the wall before inflation.
    public var meanWallCellHeight = 0.0
    public var description: String {
        var t = String(format: "Inflation: %d layers on %d wall faces → %d prism/hex cells; thickness target %.4g, mean %.4g, min %.4g; full thickness on %.1f%% of wall nodes",
                       layers, wallFaces, prisms, targetThickness, meanThickness, minThickness, 100 * coverage)
        if relaxationRounds > 0 { t += " (\(relaxationRounds) thinning rounds)" }
        t += String(format: ". Last layer %.3g vs wall cells %.3g", lastLayerHeight, meanWallCellHeight)
        if meanWallCellHeight > 3 * lastLayerHeight { t += " — reduce the wall size for a smoother transition" }
        return t
    }
}

/// Shrink-and-inflate prism-layer insertion on an element-level volume mesh: the wall
/// surface is pushed into the fluid along smoothed normals, the displacement is relaxed
/// into the neighbouring cells, and the gap is filled with graded prism (or hex) stacks.
public enum PrismInflation {
    struct EdgeKey: Hashable { var a: Int32; var b: Int32
        init(_ x: Int32, _ y: Int32) { a = min(x, y); b = max(x, y) } }

    static func centroid(_ nodes: [Int32], _ p: [Vec3]) -> Vec3 {
        var c = Vec3.zero
        for n in nodes { c += p[Int(n)] }
        return c / Double(nodes.count)
    }
    static func areaVector(_ nodes: [Int32], _ p: [Vec3]) -> Vec3 {
        let c = centroid(nodes, p)
        var s = Vec3.zero
        for k in 0..<nodes.count {
            let a = p[Int(nodes[k])], b = p[Int(nodes[(k + 1) % nodes.count])]
            s += cross(a - c, b - c)
        }
        return 0.5 * s
    }
    @inline(__always) static func tetVolume(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) -> Double {
        dot(b - a, cross(c - a, d - a)) / 6
    }
    /// Mean-ratio shape quality, 1 for a regular tetrahedron, → 0 when flattened; signed by orientation.
    @inline(__always) static func tetQuality(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) -> Double {
        let v = tetVolume(a, b, c, d)
        let l2 = lengthSquared(b - a) + lengthSquared(c - a) + lengthSquared(d - a)
            + lengthSquared(c - b) + lengthSquared(d - b) + lengthSquared(d - c)
        let q = 12 * pow(3 * abs(v), 2.0 / 3.0) / max(l2, 1e-300)
        return v < 0 ? -q : q
    }
    /// Remove components along orthonormal plane normals.
    @inline(__always) static func constrain(_ v: Vec3, _ planes: [Vec3]) -> Vec3 {
        var r = v
        for m in planes { r -= dot(r, m) * m }
        return r
    }
    static func orthonormalize(_ vs: [Vec3]) -> [Vec3] {
        var out: [Vec3] = []
        for v in vs {
            var w = v
            for u in out { w -= dot(w, u) * u }
            if norm(w) > 0.1 { out.append(normalized(w)) }
            if out.count == 3 { break }
        }
        return out
    }

    public static func inflate(_ parsed: inout GmshReader.Parsed, settings s: InflationSettings) throws -> InflationReport {
        guard s.layers > 0, s.firstHeight > 0 else { return InflationReport() }
        var pts = parsed.points
        var els = parsed.elements
        let names = parsed.physicalNames[2] ?? [:]
        func zoneName(_ p: Int) -> String { names[p] ?? (p == 0 ? "default-wall" : "boundary-\(p)") }
        func isWall(_ p: Int) -> Bool {
            s.zones.isEmpty ? ZoneKind.guess(fromName: zoneName(p)) == .wall : s.zones.contains(zoneName(p))
        }
        let cellIdx = els.indices.filter { els[$0].dim == 3 }
        let bndIdx = els.indices.filter { els[$0].dim == 2 }
        let wallIdx = bndIdx.filter { isWall(els[$0].physical) }
        guard !cellIdx.isEmpty else { throw MeshError.unsupported("prism layers need a 3D mesh") }
        guard !wallIdx.isEmpty else { throw MeshError.topology("no wall surfaces to inflate") }

        // Wall face -> adjacent volume cell
        let wallKeys = Set(wallIdx.map { GmshReader.FaceKey(els[$0].nodes) })
        var adjCell: [GmshReader.FaceKey: Int] = [:]
        for ci in cellIdx {
            for f in GmshReader.cellFaces(base: els[ci].type, els[ci].nodes) {
                let k = GmshReader.FaceKey(f)
                if wallKeys.contains(k) { adjCell[k] = ci }
            }
        }

        let nP = pts.count
        var isWallNode = [Bool](repeating: false, count: nP)
        var rawNormal = [Vec3](repeating: .zero, count: nP)
        var faceNormal: [Vec3] = []
        var faceCell: [Int] = []
        for wi in wallIdx {
            let nodes = els[wi].nodes
            guard let ci = adjCell[GmshReader.FaceKey(nodes)] else {
                throw MeshError.topology("wall face is not attached to a volume cell (non-manifold wall?)")
            }
            var A = areaVector(nodes, pts)
            if dot(A, centroid(els[ci].nodes, pts) - centroid(nodes, pts)) < 0 { A = -A }
            for n in nodes { rawNormal[Int(n)] += A; isWallNode[Int(n)] = true }
            faceNormal.append(normalized(A))
            faceCell.append(ci)
        }

        // Plane constraints: wall nodes on other boundaries slide along them.
        var planesOf = [[Vec3]](repeating: [], count: nP)
        var nonWallEdgeZone: [EdgeKey: Int] = [:]
        for bi in bndIdx where !isWall(els[bi].physical) {
            let nodes = els[bi].nodes
            let m = normalized(areaVector(nodes, pts))
            for n in nodes { planesOf[Int(n)].append(m) }
            for k in 0..<nodes.count {
                let a = nodes[k], b = nodes[(k + 1) % nodes.count]
                if isWallNode[Int(a)] && isWallNode[Int(b)] { nonWallEdgeZone[EdgeKey(a, b)] = els[bi].physical }
            }
        }
        for i in 0..<nP where !planesOf[i].isEmpty {
            // de-duplicate near-parallel planes, then orthonormalise
            var uniq: [Vec3] = []
            for m in planesOf[i] where !uniq.contains(where: { abs(dot($0, m)) > 0.995 }) { uniq.append(m) }
            planesOf[i] = orthonormalize(uniq)
        }

        // Wall-surface graph for smoothing
        var surfNbr = [[Int32]](repeating: [], count: nP)
        var nodeFaces = [[Int]](repeating: [], count: nP)
        for (fi, wi) in wallIdx.enumerated() {
            let nodes = els[wi].nodes
            for k in 0..<nodes.count {
                let a = nodes[k], b = nodes[(k + 1) % nodes.count]
                if !surfNbr[Int(a)].contains(b) { surfNbr[Int(a)].append(b) }
                if !surfNbr[Int(b)].contains(a) { surfNbr[Int(b)].append(a) }
                nodeFaces[Int(a)].append(fi)
            }
        }
        let wallNodes = (0..<nP).filter { isWallNode[$0] }

        // Normals: averaged, constrained, smoothed; each must still see all its faces.
        var nrm = [Vec3](repeating: .zero, count: nP)
        func visible(_ n: Vec3, _ i: Int) -> Bool { nodeFaces[i].allSatisfy { dot(n, faceNormal[$0]) > 0.15 } }
        for i in wallNodes {
            var n = normalized(rawNormal[i])
            if !planesOf[i].isEmpty {
                let c = constrain(n, planesOf[i])
                n = norm(c) > 0.05 ? normalized(c) : .zero
            }
            nrm[i] = n
        }
        for _ in 0..<4 {
            var next = nrm
            for i in wallNodes where nrm[i] != .zero {
                var acc = 2 * nrm[i]
                for j in surfNbr[i] where nrm[Int(j)] != .zero { acc += nrm[Int(j)] }
                var c = normalized(acc)
                if !planesOf[i].isEmpty { c = normalized(constrain(c, planesOf[i])) }
                if norm(c) > 0.5 && visible(c, i) { next[i] = c }
            }
            nrm = next
        }

        // Room available at each wall node: smallest height of an adjacent tet over its opposite face.
        var room = [Double](repeating: .infinity, count: nP)
        var roomSum = [Double](repeating: 0, count: nP), roomCount = [Int](repeating: 0, count: nP)
        var nodeCells = [[Int]](repeating: [], count: nP)
        for ci in cellIdx {
            let nodes = els[ci].nodes
            for n in nodes { nodeCells[Int(n)].append(ci) }
            guard els[ci].type == 4 else {
                for n in nodes where isWallNode[Int(n)] {
                    room[Int(n)] = min(room[Int(n)], 2 * norm(centroid(nodes, pts) - pts[Int(n)]))
                }
                continue
            }
            let V = abs(tetVolume(pts[Int(nodes[0])], pts[Int(nodes[1])], pts[Int(nodes[2])], pts[Int(nodes[3])]))
            for k in 0..<4 where isWallNode[Int(nodes[k])] {
                let opp = (0..<4).filter { $0 != k }.map { nodes[$0] }
                let A = norm(areaVector(opp, pts))
                if A > 0 { roomSum[Int(nodes[k])] += 3 * V / A; roomCount[Int(nodes[k])] += 1 }
            }
        }
        // mean height of the tets standing on each wall node (one sliver must not cap the stack;
        // the inversion check below is what guarantees validity)
        for i in 0..<nP where roomCount[i] > 0 { room[i] = min(room[i], roomSum[i] / Double(roomCount[i])) }

        // Target thickness per node, smoothed so neighbouring stacks do not step abruptly.
        let T0 = s.targetThickness
        let tMin = 0.02 * T0
        var T = [Double](repeating: 0, count: nP)
        for i in wallNodes { T[i] = min(T0, s.maxCellHeights * room[i]) }
        func smoothThickness() {
            for _ in 0..<20 {
                var changed = false
                for i in wallNodes {
                    var m = T[i]
                    for j in surfNbr[i] { m = min(m, 1.3 * T[Int(j)]) }
                    if m < T[i] { T[i] = m; changed = true }
                }
                if !changed { break }
            }
            for i in wallNodes { T[i] = max(T[i], tMin) }
        }
        smoothThickness()
        // nodes whose normal collapsed (corner of two planes): keep a tiny unconstrained offset
        for i in wallNodes where nrm[i] == .zero { nrm[i] = normalized(rawNormal[i]); T[i] = tMin }

        // Volume graph and a band of nodes around the walls (breadth-first levels).
        var nbr = [[Int32]](repeating: [], count: nP)
        for ci in cellIdx {
            let nodes = els[ci].nodes
            for a in 0..<nodes.count { for b in (a + 1)..<nodes.count {
                let x = nodes[a], y = nodes[b]
                if !nbr[Int(x)].contains(y) { nbr[Int(x)].append(y); nbr[Int(y)].append(x) }
            }}
        }
        let bandDepth = max(1, s.bandDepth)
        var level = [Int](repeating: -1, count: nP)
        var frontier = wallNodes
        for i in wallNodes { level[i] = 0 }
        for l in 1...(bandDepth + 1) {
            var next: [Int] = []
            for i in frontier { for j in nbr[i] where level[Int(j)] < 0 { level[Int(j)] = l; next.append(Int(j)) } }
            frontier = next
        }
        // ordered outward from the wall so in-place Gauss–Seidel sweeps carry the displacement in one pass
        let band = (0..<nP).filter { level[$0] > 0 && level[$0] <= bandDepth }.sorted { level[$0] < level[$1] }
        // boundary sliding constraints for every boundary node
        var bPlanes = [[Vec3]](repeating: [], count: nP)
        for bi in bndIdx {
            let nodes = els[bi].nodes
            let m = normalized(areaVector(nodes, pts))
            for n in nodes where !isWallNode[Int(n)] { bPlanes[Int(n)].append(m) }
        }
        for i in band where !bPlanes[i].isEmpty {
            var uniq: [Vec3] = []
            for m in bPlanes[i] where !uniq.contains(where: { abs(dot($0, m)) > 0.995 }) { uniq.append(m) }
            bPlanes[i] = orthonormalize(uniq)
        }

        func displacement() -> [Vec3] {
            var d = [Vec3](repeating: .zero, count: nP)
            for i in wallNodes { d[i] = T[i] * nrm[i] }
            for sweep in 0..<s.smoothingIterations {
                // alternate outward and inward sweeps (symmetric Gauss–Seidel)
                let order = sweep % 2 == 0 ? band : band.reversed()
                for i in order {
                    var acc = Vec3.zero, ws = 0.0
                    for j in nbr[i] {
                        let w = 1 / max(norm(pts[Int(j)] - pts[i]), 1e-300)
                        acc += w * d[Int(j)]; ws += w
                    }
                    var v = ws > 0 ? acc / ws : .zero
                    if !bPlanes[i].isEmpty { v = constrain(v, bPlanes[i]) }
                    d[i] = v
                }
            }
            return d
        }

        // Validity: displaced tets keep their orientation, volume and shape (see below), and
        // no prism stack folds over (converging normals in concave corners).
        let checkCells = cellIdx.filter { ci in els[ci].type == 4 && els[ci].nodes.contains { level[Int($0)] >= 0 && level[Int($0)] <= bandDepth } }
        var v0 = [Double](repeating: 0, count: els.count), q0 = v0
        for ci in checkCells {
            let n = els[ci].nodes
            v0[ci] = tetVolume(pts[Int(n[0])], pts[Int(n[1])], pts[Int(n[2])], pts[Int(n[3])])
            q0[ci] = abs(tetQuality(pts[Int(n[0])], pts[Int(n[1])], pts[Int(n[2])], pts[Int(n[3])]))
        }
        var d = displacement()
        var rounds = 0
        while true {
            var bad: [Int] = []
            for ci in checkCells {
                let n = els[ci].nodes
                let a = pts[Int(n[0])] + d[Int(n[0])], b = pts[Int(n[1])] + d[Int(n[1])]
                let c = pts[Int(n[2])] + d[Int(n[2])], e = pts[Int(n[3])] + d[Int(n[3])]
                let v = tetVolume(a, b, c, e)
                // keep orientation, a fifth of the volume and 40 % of the original shape quality
                if v0[ci] == 0 || v / v0[ci] < 0.2 || abs(tetQuality(a, b, c, e)) < 0.4 * q0[ci] { bad.append(ci) }
            }
            var badWallNodes = Set<Int>()
            for (fi, wi) in wallIdx.enumerated() {
                let nodes = els[wi].nodes
                let bottom = areaVector(nodes, pts)
                let topNodes = nodes.map { pts[Int($0)] + d[Int($0)] }
                let tc = topNodes.reduce(Vec3.zero, +) / Double(topNodes.count)
                var ta = Vec3.zero
                for k in 0..<topNodes.count { ta += cross(topNodes[k] - tc, topNodes[(k + 1) % topNodes.count] - tc) }
                ta *= 0.5
                // node order may run either way round; measure both faces in the same orientation
                let orient: Double = dot(bottom, faceNormal[fi]) >= 0 ? 1 : -1
                if orient * dot(ta, faceNormal[fi]) < 0.1 * norm(bottom) { for n in nodes { badWallNodes.insert(Int(n)) } }
            }
            if bad.isEmpty && badWallNodes.isEmpty { break }
            rounds += 1
            if rounds > 12 {
                throw MeshError.topology("prism layers would invert \(bad.count) cells and fold \(badWallNodes.count) wall nodes; use a larger wall cell size or a thinner layer stack")
            }
            // thin the layers at wall nodes within two hops of every offending cell
            var touched = badWallNodes
            for ci in bad {
                var ring = Set(els[ci].nodes.map(Int.init))
                for _ in 0..<2 { for i in Array(ring) { for j in nbr[i] { ring.insert(Int(j)) } } }
                for i in ring where isWallNode[i] { touched.insert(i) }
            }
            for i in touched { T[i] = max(0.5 * T[i], tMin) }
            smoothThickness()
            d = displacement()
        }

        // Layer nodes: k = 0 at the wall (new node), k = N is the original node, now displaced.
        let N = s.layers
        let original = pts
        for i in 0..<nP where d[i] != .zero { pts[i] += d[i] }
        var layerNode = [[Int32]](repeating: [], count: nP)
        for i in wallNodes {
            var ids = [Int32](repeating: 0, count: N + 1)
            ids[0] = Int32(pts.count); pts.append(original[i])
            let f = s.fractions(thickness: norm(d[i]))
            for k in 1..<N {
                ids[k] = Int32(pts.count)
                pts.append(original[i] + f[k] * d[i])
            }
            ids[N] = Int32(i)
            layerNode[i] = ids
        }

        // Prism (triangle walls) or hex (quad walls) stacks; walls move to layer 0.
        var report = InflationReport()
        report.layers = N
        report.wallFaces = wallIdx.count
        report.targetThickness = T0
        var newElements: [GmshReader.Element] = []
        for (fi, wi) in wallIdx.enumerated() {
            let nodes = els[wi].nodes
            let zone = els[faceCell[fi]].physical
            let type = nodes.count == 3 ? 6 : 5
            for k in 0..<N {
                let bottom = nodes.map { layerNode[Int($0)][k] }
                let top = nodes.map { layerNode[Int($0)][k + 1] }
                newElements.append(GmshReader.Element(type: type, nodes: bottom + top, physical: zone, dim: 3))
            }
            // side faces where the wall meets another boundary (inlet, outlet, symmetry...)
            for k2 in 0..<nodes.count {
                let a = nodes[k2], b = nodes[(k2 + 1) % nodes.count]
                if let z = nonWallEdgeZone[EdgeKey(a, b)] {
                    for k in 0..<N {
                        let quad = [layerNode[Int(a)][k], layerNode[Int(b)][k], layerNode[Int(b)][k + 1], layerNode[Int(a)][k + 1]]
                        newElements.append(GmshReader.Element(type: 3, nodes: quad, physical: z, dim: 2))
                    }
                }
            }
            els[wi].nodes = nodes.map { layerNode[Int($0)][0] }
        }
        report.prisms = newElements.filter { $0.dim == 3 }.count
        els += newElements

        var sum = 0.0, mn = Double.infinity, full = 0
        for i in wallNodes {
            let t = norm(d[i])
            sum += t; mn = min(mn, t)
            if t >= 0.95 * T0 { full += 1 }
        }
        report.meanThickness = sum / Double(max(wallNodes.count, 1))
        report.minThickness = mn
        report.coverage = Double(full) / Double(max(wallNodes.count, 1))
        report.relaxationRounds = rounds
        report.lastLayerHeight = T0 * (1 - s.fraction(N - 1))
        let rooms = wallNodes.map { room[$0] }.filter(\.isFinite)
        report.meanWallCellHeight = rooms.reduce(0, +) / Double(max(rooms.count, 1))
        parsed.points = pts
        parsed.elements = els
        return report
    }
}
