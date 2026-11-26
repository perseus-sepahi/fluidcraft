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
    /// Exact CAD solid (STEP/IGES/BREP) meshed together with the fluid around it, sharing
    /// faces (conjugate heat transfer): the solid becomes cell zone `solid`, the box `fluid`.
    /// The box's bottom along `baseAxis` touches the solid (it sits on a board), so the solid's
    /// faces on that plane become the patch `base`, the rest of that box face `floor`.
    case cadConjugate(path: String, flowAxis: Int, baseAxis: Int, padding: [Double])
}

public struct MeshingSettings: Codable, Sendable, Equatable {
    public var template: MeshTemplate
    /// Global maximum element size.
    public var maxSize: Double = 0.05
    /// Size at walls (refinement target).
    public var wallSize: Double = 0.01
    /// Distance over which sizes grow from wallSize to maxSize.
    public var growthDistance: Double = 0.5
    /// Boundary layer: first-cell height, growth ratio, total thickness (0 disables).
    /// 2D meshes use Gmsh's BoundaryLayer field; 3D meshes get prism layers from OpenFOAM's
    /// snappyHexMesh (layer addition on the Gmsh mesh, `FoamLayers` in FluidCraftFoam).
    public var blFirstHeight: Double = 0
    public var blGrowth: Double = 1.2
    public var blThickness: Double = 0
    /// 3D: number of prism layers (0 = derive from the thickness).
    public var blLayers: Int = 0
    /// 3D: walls to inflate (empty = all walls).
    public var blZones: [String] = []
    /// Quad-dominant 2D meshes.
    public var quads = true
    /// Thickness of the 2D slab.
    public var depth2D: Double = 1
    public var algorithm2D = 6
    public var algorithm3D = 1
    /// Length unit of the CAD file (converted to metres on import).
    public var cadUnit: CADUnit = .metre
    /// Triangulated CAD (STL/OBJ/…): facets meeting at more than this angle [deg] start a
    /// new surface patch when Gmsh reparametrizes the triangulation for remeshing.
    public var featureAngle: Double = 40
    /// Internal flow: named openings as boxes (filled automatically from the geometry when
    /// empty); CAD faces inside a box become that patch.
    public var openings: [OpeningBox] = []
    /// External CAD box: name the box face on this axis's low side `ground` (the body stands
    /// on it; its padding there is 0). -1 = none.
    public var groundAxis = -1
    /// Regions meshed finer: min corner, max corner (metres) and cell size.
    public var refinementBoxes: [RefinementBox] = []
    /// Converter command for native CAD formats (`{input}`, `{output}`); empty = Settings/env.
    /// Never encoded or decoded: a command line must come from the user, not from a file.
    public var cadConverter: String = ""

    public init(template: MeshTemplate) { self.template = template }

    private enum CodingKeys: String, CodingKey {
        case template, maxSize, wallSize, growthDistance, blFirstHeight, blGrowth, blThickness, blLayers, blZones
        case quads, depth2D, algorithm2D, algorithm3D, cadUnit, featureAngle, openings
    }

    public var isThreeDimensional: Bool {
        switch template { case .pipe, .cad, .cadConjugate: return true; default: return false }
    }

    /// Prism-layer settings for 3D templates, or nil when the boundary layer is off.
    public var inflation3D: InflationSettings? {
        guard isThreeDimensional, blFirstHeight > 0, blLayers > 0 || blThickness > blFirstHeight else { return nil }
        let n = blLayers > 0 ? blLayers : InflationSettings.layers(firstHeight: blFirstHeight, growth: blGrowth, thickness: blThickness)
        return InflationSettings(firstHeight: blFirstHeight, growth: blGrowth, layers: n, zones: blZones)
    }
}

/// A named region of space selecting the CAD faces of one opening.
public struct RefinementBox: Codable, Sendable, Equatable {
    public var min: [Double]
    public var max: [Double]
    public var size: Double
    public init(min: [Double], max: [Double], size: Double) { self.min = min; self.max = max; self.size = size }
}

public struct OpeningBox: Codable, Sendable, Equatable {
    public var name: String
    public var min: [Double]
    public var max: [Double]
    public init(name: String, min: Vec3, max: Vec3) { self.name = name; self.min = [min.x, min.y, min.z]; self.max = [max.x, max.y, max.z] }

    /// Openings of a surface, with boxes inflated by `pad` so whole faces fall inside.
    public static func from(_ surf: TriSurface, flowAxis: Int) -> [OpeningBox] {
        let (lo, hi) = surf.bounds
        let pad = 1e-4 * Swift.max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        return surf.detectOpenings(flowAxis: flowAxis).map { OpeningBox(name: $0.name, min: $0.boxMin - Vec3(repeating: pad), max: $0.boxMax + Vec3(repeating: pad)) }
    }

    func geo() -> String { "Surface In BoundingBox{" + (min + max).map { String(format: "%.12g", $0) }.joined(separator: ", ") + "}" }
}

public enum GmshDriver {
    public static var executable: URL? {
        if let env = ProcessInfo.processInfo.environment["FLUIDCRAFT_GMSH"], FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        // chosen in Settings › Tools
        if let p = UserDefaults.standard.string(forKey: "fluidcraft.gmsh"), !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let candidates = ["/Applications/Gmsh.app/Contents/MacOS/gmsh", "/opt/homebrew/bin/gmsh", "/usr/local/bin/gmsh",
                          NSHomeDirectory() + "/Applications/Gmsh.app/Contents/MacOS/gmsh"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }

    public static var isAvailable: Bool { executable != nil }

    public struct Result: Sendable {
        public var mesh: Mesh; public var script: String; public var log: String
        /// Summary of the prism layers OpenFOAM added (set by the caller that adds them).
        public var layers: String?
        public init(mesh: Mesh, script: String, log: String, layers: String? = nil) {
            self.mesh = mesh; self.script = script; self.log = log; self.layers = layers
        }
    }

    /// Generate the .geo script for the settings.
    public static func script(_ s: MeshingSettings) throws -> (geo: String, dim: Int) {
        var g = "SetFactory(\"OpenCASCADE\");\nGeneral.Terminal = 1;\neps = 1e-7;\n"
        func sizing(_ curvesOrSurfaces: String, dim: Int) -> String { GmshDriver.sizing(s, curvesOrSurfaces, dim: dim) }
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
        case .cadConjugate(let path, let axis, let baseAxis, let pad):
            dim = 3
            let p = pad.count == 6 ? pad : [2, 4, 1, 1, 0, 2]
            if s.cadUnit != .metre { g += "Geometry.OCCScaling = \(s.cadUnit.toMetres);\n" }
            let names = ["x", "y", "z"]
            let fa = names[max(0, min(2, axis))], ba = max(0, min(2, baseAxis))
            // padding along the base axis below the body is forced to 0: the body sits on the floor
            var pp = p
            pp[2 * ba] = 0
            g += """
            Geometry.OCCBoundsUseStl = 1;   // tight bounds: the floor must touch the base exactly
            v() = ShapeFromFile("\(GmshDriver.literal(path))");
            bb() = BoundingBox Volume{v()};
            lx = bb(3)-bb(0); ly = bb(4)-bb(1); lz = bb(5)-bb(2); Lr = Max(lx, Max(ly, lz));
            eps = 1e-5*Lr;
            X0 = bb(0)-\(pp[0])*Lr; X1 = bb(3)+\(pp[1])*Lr;
            Y0 = bb(1)-\(pp[2])*Lr; Y1 = bb(4)+\(pp[3])*Lr;
            Z0 = bb(2)-\(pp[4])*Lr; Z1 = bb(5)+\(pp[5])*Lr;
            Box(1000) = {X0, Y0, Z0, X1-X0, Y1-Y0, Z1-Z0};
            BooleanFragments{ Volume{1000}; Delete; }{ Volume{v()}; Delete; }
            solid() = Volume In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, bb(3)+eps, bb(4)+eps, bb(5)+eps};
            all() = Volume{:};
            fluid() = all();
            fluid() -= solid();
            inlet() = Surface In BoundingBox{X0-eps, Y0-eps, Z0-eps, \(fa == "x" ? "X0" : "X1")+eps, \(fa == "y" ? "Y0" : "Y1")+eps, \(fa == "z" ? "Z0" : "Z1")+eps};
            outlet() = Surface In BoundingBox{\(fa == "x" ? "X1" : "X0")-eps, \(fa == "y" ? "Y1" : "Y0")-eps, \(fa == "z" ? "Z1" : "Z0")-eps, X1+eps, Y1+eps, Z1+eps};
            bottom() = Surface In BoundingBox{X0-eps, Y0-eps, Z0-eps, \(ba == 0 ? "X0" : "X1")+eps, \(ba == 1 ? "Y0" : "Y1")+eps, \(ba == 2 ? "Z0" : "Z1")+eps};
            base() = Surface In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, \(ba == 0 ? "bb(0)" : "bb(3)")+eps, \(ba == 1 ? "bb(1)" : "bb(4)")+eps, \(ba == 2 ? "bb(2)" : "bb(5)")+eps};
            floor() = bottom();
            floor() -= base();
            boxall() = Surface In BoundingBox{X0-eps, Y0-eps, Z0-eps, X1+eps, Y1+eps, Z1+eps};
            body() = Surface In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, bb(3)+eps, bb(4)+eps, bb(5)+eps};
            walls() = boxall();
            walls() -= body();
            walls() -= inlet();
            walls() -= outlet();
            walls() -= floor();
            Physical Surface("inlet") = inlet();
            Physical Surface("outlet") = outlet();
            Physical Surface("base") = base();
            Physical Surface("floor") = floor();
            Physical Surface("farfield") = walls();
            Physical Volume("fluid") = fluid();
            Physical Volume("solid") = solid();

            """
            g += sizing("body()", dim: 3)
        case .cad(let path, let external, let axis, let pad):
            dim = 3
            let a = ["x", "y", "z"][max(0, min(2, axis))]
            guard let fmt = CADFormat.detect(URL(fileURLWithPath: path)) else {
                throw MeshError.unsupported("unknown CAD format '\((path as NSString).pathExtension)'; use \(CADFormat.extensions.joined(separator: ", "))")
            }
            if !fmt.isBRep {
                let surf = try SurfaceReader.read(url: URL(fileURLWithPath: path), unit: s.cadUnit)
                return (try triangulatedScript(s, surface: surf, stlName: "surface.stl", external: external, axis: axis, padding: pad), 3)
            }
            if s.cadUnit != .metre { g += "Geometry.OCCScaling = \(s.cadUnit.toMetres);\n" }
            // tight bounding boxes, and selection tolerances relative to the model: OCC pads
            // boxes by ~1e-7, which made a box face fall outside a fixed 1e-7 tolerance
            g += "Geometry.OCCBoundsUseStl = 1;\n"
            g += "v() = ShapeFromFile(\"\(GmshDriver.literal(path))\");\n"
            g += "bb() = BoundingBox Volume{v()};\n"
            g += "eps = 1e-5*Max(bb(3)-bb(0), Max(bb(4)-bb(1), bb(5)-bb(2)));\n"
            if external {
                let p = pad.count == 6 ? pad : [3, 6, 3, 3, 3, 3]
                // box extents as plain variables: the Boolean renumbers volumes, so never query the box by tag
                g += """
                lx = bb(3)-bb(0); ly = bb(4)-bb(1); lz = bb(5)-bb(2); Lr = Max(lx, Max(ly, lz));
                X0 = bb(0)-\(p[0])*Lr; X1 = bb(3)+\(p[1])*Lr;
                Y0 = bb(1)-\(p[2])*Lr; Y1 = bb(4)+\(p[3])*Lr;
                Z0 = bb(2)-\(p[4])*Lr; Z1 = bb(5)+\(p[5])*Lr;
                Box(1000) = {X0, Y0, Z0, X1-X0, Y1-Y0, Z1-Z0};
                BooleanDifference{ Volume{1000}; Delete; }{ Volume{v()}; Delete; }
                inlet() = Surface In BoundingBox{X0-eps, Y0-eps, Z0-eps, \(a == "x" ? "X0" : "X1")+eps, \(a == "y" ? "Y0" : "Y1")+eps, \(a == "z" ? "Z0" : "Z1")+eps};
                outlet() = Surface In BoundingBox{\(a == "x" ? "X1" : "X0")-eps, \(a == "y" ? "Y1" : "Y0")-eps, \(a == "z" ? "Z1" : "Z0")-eps, X1+eps, Y1+eps, Z1+eps};
                body() = Surface In BoundingBox{bb(0)-eps, bb(1)-eps, bb(2)-eps, bb(3)+eps, bb(4)+eps, bb(5)+eps};
                farfield() = Surface{:};
                farfield() -= body();
                farfield() -= inlet();
                farfield() -= outlet();

                """
                if (0..<3).contains(s.groundAxis) {
                    // the floor the body stands on (the box face at the low end of the ground axis)
                    let lo = ["X0", "Y0", "Z0"], hi = ["X1", "Y1", "Z1"]
                    var c = [lo[0] + "-eps", lo[1] + "-eps", lo[2] + "-eps", hi[0] + "+eps", hi[1] + "+eps", hi[2] + "+eps"]
                    c[3 + s.groundAxis] = lo[s.groundAxis] + "+eps"
                    g += "ground() = Surface In BoundingBox{\(c.joined(separator: ", "))};\nfarfield() -= ground();\nPhysical Surface(\"ground\") = ground();\n"
                }
                g += """
                Physical Surface("inlet") = inlet();
                Physical Surface("outlet") = outlet();
                Physical Surface("farfield") = farfield();
                Physical Surface("body") = body();
                Physical Volume("fluid") = Volume{:};

                """
                g += sizing("body()", dim: 3)
            } else if !s.openings.isEmpty {
                g += "wall() = Surface{:};\n"
                for (i, o) in s.openings.enumerated() {
                    g += "op\(i)() = \(o.geo());\nwall() -= op\(i)();\nPhysical Surface(\"\(o.name)\") = op\(i)();\n"
                }
                g += "Physical Surface(\"wall\") = wall();\nPhysical Volume(\"fluid\") = Volume{:};\n\n"
                g += sizing("wall()", dim: 3)
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
            g += "Mesh.Algorithm = 6;\nMesh.Algorithm3D = \(s.algorithm3D);\nMesh.Optimize = 1;\nMesh.OptimizeNetgen = 1;\n"
        }
        g += "Mesh.ElementOrder = 1;\n"
        return (g, dim)
    }

    /// Distance/threshold size field towards the given walls (plus a 2D boundary-layer field).
    static func sizing(_ s: MeshingSettings, _ curvesOrSurfaces: String, dim: Int) -> String {
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
        // refinement regions: Box fields combined with the wall-distance field (smallest wins)
        let boxes = s.refinementBoxes.filter { $0.min.count == 3 && $0.max.count == 3 && $0.size > 0 }
        if !boxes.isEmpty {
            var ids = [2]
            for (i, b) in boxes.enumerated() {
                let id = 10 + i
                ids.append(id)
                t += "Field[\(id)] = Box;\nField[\(id)].VIn = \(b.size);\nField[\(id)].VOut = \(s.maxSize);\n"
                t += "Field[\(id)].XMin = \(b.min[0]); Field[\(id)].YMin = \(b.min[1]); Field[\(id)].ZMin = \(b.min[2]);\n"
                t += "Field[\(id)].XMax = \(b.max[0]); Field[\(id)].YMax = \(b.max[1]); Field[\(id)].ZMax = \(b.max[2]);\n"
            }
            t += "Field[30] = Min;\nField[30].FieldsList = {\(ids.map(String.init).joined(separator: ", "))};\nBackground Field = 30;\n\n"
        }
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

    /// Script for a triangulated CAD surface (STL/OBJ/PLY/OFF/3MF) already written to
    /// `stlName` in the working directory. Gmsh's built-in kernel classifies the facets into
    /// smooth patches (split where facets meet at more than `featureAngle`), reparametrizes
    /// them and remeshes at the requested sizes; the volume is the box minus the body
    /// (external) or the inside of the surface (internal). Named selections follow the same
    /// rules as STEP import: inlet/outlet at the ends of the flow axis.
    public static func triangulatedScript(_ s: MeshingSettings, surface: TriSurface, stlName: String,
                                          external: Bool, axis: Int, padding pad: [Double]) throws -> String {
        let (lo, hi) = surface.bounds
        let size = hi - lo
        let L = Swift.max(size.x, size.y, size.z)
        guard L > 0 else { throw MeshError.topology("CAD surface has zero extent") }
        let open = surface.openOrNonManifoldEdges
        if open > 0 {
            throw MeshError.topology("the surface has \(open) open or non-manifold edges; a volume mesh needs a closed (watertight) surface")
        }
        let ax = max(0, min(2, axis))
        let e = 1e-5 * L
        var g = """
        General.Terminal = 1;
        Merge "\(GmshDriver.literal(stlName))";
        ClassifySurfaces{\(s.featureAngle) * Pi / 180, 1, 1, Pi};
        CreateGeometry;
        body() = Surface{:};

        """
        func n(_ v: Double) -> String { String(format: "%.12g", v) }
        if external {
            let p = pad.count == 6 ? pad : [3, 6, 3, 3, 3, 3]
            let X0 = lo.x - p[0] * L, X1 = hi.x + p[1] * L
            let Y0 = lo.y - p[2] * L, Y1 = hi.y + p[3] * L
            let Z0 = lo.z - p[4] * L, Z1 = hi.z + p[5] * L
            let c = [(X0, Y0, Z0), (X1, Y0, Z0), (X1, Y1, Z0), (X0, Y1, Z0), (X0, Y0, Z1), (X1, Y0, Z1), (X1, Y1, Z1), (X0, Y1, Z1)]
            for (i, q) in c.enumerated() { g += "bp\(i) = newp; Point(bp\(i)) = {\(n(q.0)), \(n(q.1)), \(n(q.2))};\n" }
            let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
            for (i, ed) in edges.enumerated() { g += "bl\(i) = newl; Line(bl\(i)) = {bp\(ed.0), bp\(ed.1)};\n" }
            // faces as signed edge loops (outward orientation is fixed up by Gmsh's volume meshing)
            let faces: [(String, [Int])] = [
                ("xmin", [-3, 8 + 3, 7, -(8 + 0)]), ("xmax", [1, 8 + 2, -5, -(8 + 1)]),
                ("ymin", [0, 8 + 1, -4, -(8 + 0)]), ("ymax", [-2, 8 + 2, 6, -(8 + 3)]),
                ("zmin", [0, 1, 2, 3]), ("zmax", [4, 5, 6, 7]),
            ]
            for (name, loop) in faces {
                let refs = loop.map { $0 < 0 ? "-bl\(-$0)" : "bl\($0)" }
                g += "ll_\(name) = newll; Curve Loop(ll_\(name)) = {\(refs.joined(separator: ", "))};\n"
                g += "s_\(name) = news; Plane Surface(s_\(name)) = {ll_\(name)};\n"
            }
            let names = ["x", "y", "z"]
            let inlet = "s_\(names[ax])min", outlet = "s_\(names[ax])max"
            let far = faces.map { "s_\($0.0)" }.filter { $0 != inlet && $0 != outlet }
            g += """
            sl_box = newsl; Surface Loop(sl_box) = {\(faces.map { "s_\($0.0)" }.joined(separator: ", "))};
            sl_body = newsl; Surface Loop(sl_body) = {body()};
            Volume(1) = {sl_box, sl_body};
            Physical Surface("inlet") = {\(inlet)};
            Physical Surface("outlet") = {\(outlet)};
            Physical Surface("farfield") = {\(far.joined(separator: ", "))};
            Physical Surface("body") = {body()};
            Physical Volume("fluid") = {1};

            """
            g += sizing(s, "body()", dim: 3)
        } else {
            _ = e
            let openings = s.openings.isEmpty ? OpeningBox.from(surface, flowAxis: ax) : s.openings
            g += "sl_body = newsl; Surface Loop(sl_body) = {body()};\nVolume(1) = {sl_body};\nwall() = body();\n"
            for (i, o) in openings.enumerated() {
                g += "op\(i)() = \(o.geo());\nwall() -= op\(i)();\nPhysical Surface(\"\(o.name)\") = op\(i)();\n"
            }
            g += "Physical Surface(\"wall\") = wall();\nPhysical Volume(\"fluid\") = {1};\n\n"
            g += sizing(s, "wall()", dim: 3)
        }
        g += "Mesh.Algorithm = 6;\nMesh.Algorithm3D = \(s.algorithm3D);\nMesh.Optimize = 1;\nMesh.OptimizeNetgen = 1;\nMesh.ElementOrder = 1;\n"
        return g
    }

    /// Triangulate exact CAD (STEP/IGES/BREP) into a surface for snappyHexMesh: Gmsh meshes
    /// only the model's faces, with sizes between `minSize` and `maxSize` refined by curvature.
    public static func tessellate(path: String, unit: CADUnit, minSize: Double, maxSize: Double,
                                  workDir: URL? = nil) throws -> TriSurface {
        guard let exe = executable else { throw MeshError.io("Gmsh not found. Install it from Settings › Tools (or Gmsh.app in /Applications, or set FLUIDCRAFT_GMSH).") }
        let dir = workDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-tess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var g = "SetFactory(\"OpenCASCADE\");\nGeneral.Terminal = 1;\n"
        if unit != .metre { g += "Geometry.OCCScaling = \(unit.toMetres);\n" }
        g += """
        v() = ShapeFromFile("\(GmshDriver.literal(path))");
        Physical Surface("body") = Surface{:};
        Mesh.MeshSizeMin = \(minSize);
        Mesh.MeshSizeMax = \(maxSize);
        Mesh.MeshSizeFromCurvature = 24;
        Mesh.MeshSizeExtendFromBoundary = 1;
        Mesh.Algorithm = 6;
        Mesh.StlOneSolidPerSurface = 2;

        """
        let geoURL = dir.appendingPathComponent("tessellate.geo"), stlURL = dir.appendingPathComponent("surface.stl")
        try g.write(to: geoURL, atomically: true, encoding: .utf8)
        let (status, text) = try run(exe, [geoURL.path, "-2", "-format", "stl", "-o", stlURL.path, "-nopopup"], in: dir, log: nil)
        guard status == 0, FileManager.default.fileExists(atPath: stlURL.path) else {
            let errs = text.split(separator: "\n").filter { $0.contains("Error") }.prefix(5).joined(separator: "\n")
            throw MeshError.io("Gmsh tessellation failed (status \(status)).\n\(errs)")
        }
        return try SurfaceReader.read(url: stlURL, unit: .metre)
    }

    public static func run(_ exe: URL, _ args: [String], in dir: URL, log: ((String) -> Void)?) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe.closeOnExec()
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
        return (p.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Run Gmsh on the settings and import the result. `reader` converts the written `.msh`
    /// (FluidCraft's OpenFOAM layer passes `gmshToFoam`); without one FluidCraft's own reader is used.
    public static func generate(_ s: MeshingSettings, workDir: URL? = nil, log: ((String) -> Void)? = nil,
                                reader: ((URL, Double) throws -> Mesh)? = nil) throws -> Result {
        guard let exe = executable else { throw MeshError.io("Gmsh not found. Install it from Settings › Tools (or Gmsh.app in /Applications, or set FLUIDCRAFT_GMSH).") }
        let dir = workDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("fluidcraft-gmsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = s
        if case .cadConjugate(let path0, let axis, let baseAxis, let pad) = s.template {
            let path = try CADConversion.prepare(path0, converter: s.cadConverter.isEmpty ? CADConversion.defaultConverter : s.cadConverter, workDir: dir)
            guard CADFormat.detect(URL(fileURLWithPath: path))?.isBRep == true else {
                throw MeshError.unsupported("conjugate (solid + fluid) meshing needs exact CAD (STEP, IGES, BREP, FreeCAD or a converted native file)")
            }
            s.template = .cadConjugate(path: path, flowAxis: axis, baseAxis: baseAxis, padding: pad)
        }
        if case .cad(let path0, let external, let axis, let pad) = s.template {
            // FreeCAD and native formats → B-rep the OpenCASCADE reader understands
            let path = try CADConversion.prepare(path0, converter: s.cadConverter.isEmpty ? CADConversion.defaultConverter : s.cadConverter, workDir: dir)
            if path != path0 { log?("Converted \((path0 as NSString).lastPathComponent) → \((path as NSString).lastPathComponent)\n") }
            s.template = .cad(path: path, external: external, flowAxis: axis, padding: pad)
            if !external, s.openings.isEmpty, let f = CADFormat.detect(URL(fileURLWithPath: path)), f.isBRep {
                // coarse probe triangulation to find the flat caps (inlets/outlets) of the body
                let probe = try tessellate(path: path, unit: s.cadUnit, minSize: 1e-9, maxSize: 1e9, workDir: dir.appendingPathComponent("probe"))
                s.openings = OpeningBox.from(probe, flowAxis: axis)
                log?("Openings: " + s.openings.map(\.name).joined(separator: ", ") + "\n")
            }
        }
        let geo: String, dim: Int
        if case .cad(let path, let external, let axis, let pad) = s.template,
           let fmt = CADFormat.detect(URL(fileURLWithPath: path)), !fmt.isBRep {
            let surf = try SurfaceReader.read(url: URL(fileURLWithPath: path), unit: s.cadUnit)
            log?("Read \(surf.triangleCount) triangles, \(surf.regionNames.count) region(s) from \((path as NSString).lastPathComponent)\n")
            try SurfaceWriter.stl(surf).write(to: dir.appendingPathComponent("surface.stl"), atomically: true, encoding: .utf8)
            geo = try triangulatedScript(s, surface: surf, stlName: "surface.stl", external: external, axis: axis, padding: pad)
            dim = 3
        } else {
            (geo, dim) = try script(s)
        }
        let geoURL = dir.appendingPathComponent("geometry.geo")
        let mshURL = dir.appendingPathComponent("mesh.msh")
        try geo.write(to: geoURL, atomically: true, encoding: .utf8)
        let (status, text) = try run(exe, [geoURL.path, "-\(dim)", "-format", "msh41", "-o", mshURL.path, "-nopopup"], in: dir, log: log)
        guard status == 0, FileManager.default.fileExists(atPath: mshURL.path) else {
            let errs = text.split(separator: "\n").filter { $0.contains("Error") }.prefix(5).joined(separator: "\n")
            throw MeshError.io("Gmsh failed (status \(status)).\n\(errs)")
        }
        let mesh = try reader?(mshURL, s.depth2D) ?? GmshReader.read(url: mshURL, depth2D: s.depth2D)
        return Result(mesh: mesh, script: geo, log: text)
    }

    /// NACA 4-digit coordinates (chord 1), closed trailing edge, cosine spacing; TE -> upper -> LE -> lower -> TE (excluded).
    /// Text safe inside a Gmsh string literal: quotes, backslashes and line breaks are removed,
    /// so a file name can never end the literal and add commands (Gmsh scripts can run
    /// programs with SystemCall).
    public static func literal(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 != "\"" && $0 != "\\" && !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
    }

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
