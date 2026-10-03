import Foundation

/// Geometry + meshing jobs executed by an installed Gmsh (≥ 4.11 with OpenCASCADE).
public enum MeshTemplate: Codable, Sendable, Equatable {
    /// 2D channel with a circular cylinder (Schäfer & Turek 1996 layout by default).
    case channelCylinder(length: Double, height: Double, cx: Double, cy: Double, radius: Double)
    /// NACA 4-digit airfoil (chord 1) inside a circular far field.
    case naca4(code: String, farfieldRadius: Double)
    /// 3D circular pipe along +x.
    case pipe(length: Double, diameter: Double)
    /// Imported CAD (STEP/IGES/BREP/STL). External: body subtracted from a box; internal: body is the fluid.
    case cad(path: String, external: Bool, flowAxis: Int, padding: [Double])
}

public struct MeshingSettings: Codable, Sendable, Equatable {
    public var template: MeshTemplate
    /// Global maximum element size.
    public var maxSize: Double = 0.05
    /// Size at walls (refinement target).
    public var wallSize: Double = 0.01
    /// Distance over which sizes grow from wallSize to maxSize.
    public var growthDistance: Double = 0.5
    /// Boundary layer (2D): first-cell height, growth ratio, total thickness (0 disables).
    public var blFirstHeight: Double = 0
    public var blGrowth: Double = 1.2
    public var blThickness: Double = 0
    /// Quad-dominant 2D meshes.
    public var quads = true
    /// Thickness of the 2D slab.
    public var depth2D: Double = 1
    public var algorithm2D = 6
    public var algorithm3D = 1

    public init(template: MeshTemplate) { self.template = template }
}

public enum GmshDriver {
    public static var executable: URL? {
        if let env = ProcessInfo.processInfo.environment["CURLEW_GMSH"], FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let candidates = ["/Applications/Gmsh.app/Contents/MacOS/gmsh", "/opt/homebrew/bin/gmsh", "/usr/local/bin/gmsh",
                          NSHomeDirectory() + "/Applications/Gmsh.app/Contents/MacOS/gmsh"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }

    public static var isAvailable: Bool { executable != nil }

    public struct Result: Sendable { public var mesh: Mesh; public var script: String; public var log: String }

    /// Generate the .geo script for the settings.
    public static func script(_ s: MeshingSettings) throws -> (geo: String, dim: Int) {
        var g = "SetFactory(\"OpenCASCADE\");\nGeneral.Terminal = 1;\neps = 1e-7;\n"
        func sizing(_ curvesOrSurfaces: String, dim: Int) -> String {
            var t = """
            Field[1] = Distance;
            Field[1].\(dim == 2 ? "CurvesList" : "SurfacesList") = {\(curvesOrSurfaces)};
            Field[1].Sampling = 200;
            Field[2] = Threshold;
            Field[2].InField = 1;
            Field[2].SizeMin = \(s.wallSize);
            Field[2].SizeMax = \(s.maxSize);
            Field[2].DistMin = \(s.wallSize * 2);
            Field[2].DistMax = \(s.growthDistance);
            Background Field = 2;
            Mesh.MeshSizeExtendFromBoundary = 0;
            Mesh.MeshSizeFromPoints = 0;
            Mesh.MeshSizeFromCurvature = 0;
            Mesh.MeshSizeMax = \(s.maxSize);

            """
            if dim == 2 && s.blFirstHeight > 0 && s.blThickness > 0 {
                t += """
                Field[3] = BoundaryLayer;
                Field[3].CurvesList = {\(curvesOrSurfaces)};
                Field[3].Size = \(s.blFirstHeight);
                Field[3].Ratio = \(s.blGrowth);
                Field[3].Thickness = \(s.blThickness);
                Field[3].Quads = 1;
                BoundaryLayer Field = 3;

                """
            }
            return t
        }
        var dim = 2
        switch s.template {
        case .channelCylinder(let L, let H, let cx, let cy, let r):
            g += """
            Rectangle(1) = {0, 0, 0, \(L), \(H)};
            Disk(2) = {\(cx), \(cy), 0, \(r), \(r)};
            BooleanDifference{ Surface{1}; Delete; }{ Surface{2}; Delete; }
            inlet() = Curve In BoundingBox{-eps, -eps, -eps, eps, \(H)+eps, eps};
            outlet() = Curve In BoundingBox{\(L)-eps, -eps, -eps, \(L)+eps, \(H)+eps, eps};
            bottom() = Curve In BoundingBox{-eps, -eps, -eps, \(L)+eps, eps, eps};
            top() = Curve In BoundingBox{-eps, \(H)-eps, -eps, \(L)+eps, \(H)+eps, eps};
            cyl() = Curve In BoundingBox{\(cx - r)-eps, \(cy - r)-eps, -eps, \(cx + r)+eps, \(cy + r)+eps, eps};
            Physical Curve("inlet") = inlet();
            Physical Curve("outlet") = outlet();
            Physical Curve("wall") = {bottom(), top()};
            Physical Curve("cylinder") = cyl();
            Physical Surface("fluid") = Surface{:};

            """
            g += sizing("cyl()", dim: 2)
        case .naca4(let code, let R):
            let pts = naca4Points(code: code, n: 120)
            var ids: [Int] = []
            for (i, p) in pts.enumerated() {
                g += "Point(\(1000 + i)) = {\(p.0), \(p.1), 0};\n"
                ids.append(1000 + i)
            }
            // closed loop: TE upper -> LE -> TE lower (shared TE point)
            g += "Spline(1) = {\(ids.map(String.init).joined(separator: ", ")), \(ids[0])};\n"
            g += """
            Curve Loop(1) = {1};
            Circle(2) = {0.5, 0, 0, \(R), 0, 2*Pi};
            Curve Loop(2) = {2};
            Plane Surface(1) = {2, 1};
            Physical Curve("airfoil") = {1};
            Physical Curve("farfield") = {2};
            Physical Surface("fluid") = {1};

            """
            g += sizing("1", dim: 2)
            if s.blFirstHeight > 0 && s.blThickness > 0 { g += "Field[3].FanPointsList = {\(ids[0])};\n" }
        case .pipe(let L, let D):
            dim = 3
            g += """
            Cylinder(1) = {0, 0, 0, \(L), 0, 0, \(D / 2)};
            inlet() = Surface In BoundingBox{-eps, -\(D), -\(D), eps, \(D), \(D)};
            outlet() = Surface In BoundingBox{\(L)-eps, -\(D), -\(D), \(L)+eps, \(D), \(D)};
            all() = Surface{:};
            wall() = all();
            wall() -= inlet();
            wall() -= outlet();
            Physical Surface("inlet") = inlet();
            Physical Surface("outlet") = outlet();
            Physical Surface("wall") = wall();
            Physical Volume("fluid") = {1};

            """
            g += sizing("wall()", dim: 3)
        case .cad(let path, let external, let axis, let pad):
            dim = 3
            let ext = (path as NSString).pathExtension.lowercased()
            let a = ["x", "y", "z"][max(0, min(2, axis))]
            if ext == "stl" {
                throw MeshError.unsupported("STL import: convert the STL to STEP or use a watertight STEP/IGES model")
            }
            g += "v() = ShapeFromFile(\"\(path.replacingOccurrences(of: "\"", with: ""))\");\n"
            g += "bb() = BoundingBox Volume{v()};\n"
            if external {
                let p = pad.count == 6 ? pad : [3, 6, 3, 3, 3, 3]
                g += """
                lx = bb(3)-bb(0); ly = bb(4)-bb(1); lz = bb(5)-bb(2); Lr = Max(lx, Max(ly, lz));
                Box(1000) = {bb(0)-\(p[0])*Lr, bb(1)-\(p[2])*Lr, bb(2)-\(p[4])*Lr, lx+(\(p[0])+\(p[1]))*Lr, ly+(\(p[2])+\(p[3]))*Lr, lz+(\(p[4])+\(p[5]))*Lr};
                BooleanDifference{ Volume{1000}; Delete; }{ Volume{v()}; Delete; }
                ob() = BoundingBox Volume{1000};
                inlet() = Surface In BoundingBox{ob(0)-eps, ob(1)-eps, ob(2)-eps, \(a == "x" ? "ob(0)" : "ob(3)")+eps, \(a == "y" ? "ob(1)" : "ob(4)")+eps, \(a == "z" ? "ob(2)" : "ob(5)")+eps};
                outlet() = Surface In BoundingBox{\(a == "x" ? "ob(3)" : "ob(0)")-eps, \(a == "y" ? "ob(4)" : "ob(1)")-eps, \(a == "z" ? "ob(5)" : "ob(2)")-eps, ob(3)+eps, ob(4)+eps, ob(5)+eps};
                boxAll() = Surface In BoundingBox{ob(0)-eps, ob(1)-eps, ob(2)-eps, ob(3)+eps, ob(4)+eps, ob(5)+eps};
                body() = Surface In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, bb(3)+eps, bb(4)+eps, bb(5)+eps};
                farfield() = Surface{:};
                farfield() -= body();
                farfield() -= inlet();
                farfield() -= outlet();
                Physical Surface("inlet") = inlet();
                Physical Surface("outlet") = outlet();
                Physical Surface("farfield") = farfield();
                Physical Surface("body") = body();
                Physical Volume("fluid") = Volume{:};

                """
                g += sizing("body()", dim: 3)
            } else {
                g += """
                inlet() = Surface In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, \(a == "x" ? "bb(0)" : "bb(3)")+eps, \(a == "y" ? "bb(1)" : "bb(4)")+eps, \(a == "z" ? "bb(2)" : "bb(5)")+eps};
                outlet() = Surface In BoundingBox{\(a == "x" ? "bb(3)" : "bb(0)")-eps, \(a == "y" ? "bb(4)" : "bb(1)")-eps, \(a == "z" ? "bb(5)" : "bb(2)")-eps, bb(3)+eps, bb(4)+eps, bb(5)+eps};
                wall() = Surface{:};
                wall() -= inlet();
                wall() -= outlet();
                Physical Surface("inlet") = inlet();
                Physical Surface("outlet") = outlet();
                Physical Surface("wall") = wall();
                Physical Volume("fluid") = Volume{:};

                """
                g += sizing("wall()", dim: 3)
            }
        }
        if dim == 2 && s.quads {
            g += "Mesh.RecombineAll = 1;\nMesh.Algorithm = 8;\nMesh.RecombinationAlgorithm = 1;\n"
        } else if dim == 2 {
            g += "Mesh.Algorithm = \(s.algorithm2D);\n"
        } else {
            g += "Mesh.Algorithm = 6;\nMesh.Algorithm3D = \(s.algorithm3D);\nMesh.Optimize = 1;\n"
        }
        g += "Mesh.ElementOrder = 1;\n"
        return (g, dim)
    }

    /// Run Gmsh on the settings and import the result.
    public static func generate(_ s: MeshingSettings, workDir: URL? = nil, log: ((String) -> Void)? = nil) throws -> Result {
        guard let exe = executable else { throw MeshError.io("Gmsh not found. Install Gmsh.app in /Applications or set CURLEW_GMSH.") }
        let (geo, dim) = try script(s)
        let dir = workDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("curlew-gmsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let geoURL = dir.appendingPathComponent("geometry.geo")
        let mshURL = dir.appendingPathComponent("mesh.msh")
        try geo.write(to: geoURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = exe
        p.arguments = [geoURL.path, "-\(dim)", "-format", "msh41", "-o", mshURL.path, "-nopopup"]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var output = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); output.append(d); lock.unlock()
            if let log, let s = String(data: d, encoding: .utf8) { log(s) }
        }
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); output.append(rest); lock.unlock()
        let text = String(decoding: output, as: UTF8.self)
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: mshURL.path) else {
            let errs = text.split(separator: "\n").filter { $0.contains("Error") }.prefix(5).joined(separator: "\n")
            throw MeshError.io("Gmsh failed (status \(p.terminationStatus)).\n\(errs)")
        }
        let mesh = try GmshReader.read(url: mshURL, depth2D: s.depth2D)
        return Result(mesh: mesh, script: geo, log: text)
    }

    /// NACA 4-digit coordinates (chord 1), closed trailing edge, cosine spacing; TE -> upper -> LE -> lower -> TE (excluded).
    public static func naca4Points(code: String, n: Int) -> [(Double, Double)] {
        let digits = Array(code.filter(\.isNumber)).compactMap { Int(String($0)) }
        let m = digits.count == 4 ? Double(digits[0]) / 100 : 0
        let p = digits.count == 4 ? Double(digits[1]) / 10 : 0
        let t = digits.count == 4 ? Double(digits[2] * 10 + digits[3]) / 100 : 0.12
        func yt(_ x: Double) -> Double {
            5 * t * (0.2969 * sqrt(x) - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
        }
        func camber(_ x: Double) -> (Double, Double) {
            guard m > 0, p > 0 else { return (0, 0) }
            if x < p { return (m / (p * p) * (2 * p * x - x * x), 2 * m / (p * p) * (p - x)) }
            return (m / ((1 - p) * (1 - p)) * ((1 - 2 * p) + 2 * p * x - x * x), 2 * m / ((1 - p) * (1 - p)) * (p - x))
        }
        var upper: [(Double, Double)] = [], lower: [(Double, Double)] = []
        for i in 0...n {
            let beta = Double.pi * Double(i) / Double(n)
            let x = 0.5 * (1 - cos(beta))
            let (yc, dy) = camber(x)
            let th = atan(dy)
            let y = yt(x)
            upper.append((x - y * sin(th), yc + y * cos(th)))
            lower.append((x + y * sin(th), yc - y * cos(th)))
        }
        // TE (x=1) -> LE along upper, then LE -> TE along lower, without duplicating LE or TE
        var out: [(Double, Double)] = upper.reversed()
        out += lower[1..<n]
        return out
    }
}
