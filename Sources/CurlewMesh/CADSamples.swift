import Foundation

/// Sample CAD models for trying the CAD workflow: each is a short OpenCASCADE script that Gmsh
/// turns into a STEP file, so the samples are exact B-rep geometry (like a file from a CAD
/// system) and parametric.
public enum CADSample: String, CaseIterable, Sendable, Identifiable {
    case sphere, ahmedBody, nacaWing, pipeElbow, teeJunction, manifold, heatSink, turbineBlade, turbineRotor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sphere: return "Sphere (D = 1 m)"
        case .ahmedBody: return "Ahmed body, 25° slant (car benchmark)"
        case .nacaWing: return "NACA 0012 wing, 4° incidence"
        case .pipeElbow: return "90° pipe elbow (D = 50 mm)"
        case .teeJunction: return "T-junction (mixing tee)"
        case .manifold: return "Coolant manifold (30 mm header, three 15 mm branches)"
        case .heatSink: return "Plate-fin heat sink (60 × 60 mm, 9 fins)"
        case .turbineBlade: return "Wind-turbine blade (twisted, tapered NACA 4412)"
        case .turbineRotor: return "Three-blade wind-turbine rotor (D = 2 m)"
        }
    }

    public enum Analysis: String, Sendable { case external, internalFlow, conjugate }

    /// The analysis the sample is meant for, its flow direction and a typical speed [m/s].
    public var suggested: (analysis: Analysis, flowAxis: Int, speed: Double, fluid: String) {
        switch self {
        case .sphere: return (.external, 0, 1, "air")
        case .ahmedBody: return (.external, 0, 40, "air")
        case .nacaWing: return (.external, 0, 20, "air")
        case .pipeElbow: return (.internalFlow, 0, 1, "water-liquid")
        case .teeJunction: return (.internalFlow, 0, 0.5, "water-liquid")
        case .manifold: return (.internalFlow, 0, 0.5, "water-liquid")
        case .heatSink: return (.conjugate, 0, 3, "air")
        case .turbineBlade: return (.external, 0, 10, "air")
        case .turbineRotor: return (.external, 0, 10, "air")
        }
    }

    public var summary: String {
        switch self {
        case .sphere: return "Drag of a sphere; compare C_D with the standard drag curve."
        case .ahmedBody: return "Simplified car (Ahmed et al. 1984): drag and the slant-back wake at 40 m/s."
        case .nacaWing: return "Finite wing at 4° incidence: lift, drag and tip vortices."
        case .pipeElbow: return "Pressure drop and secondary flow in a bend; the exit on the side is found automatically."
        case .teeJunction: return "Three openings (inlet, outlet, branch) detected from the geometry."
        case .manifold: return "Five openings found automatically; how evenly the header feeds its three branches (flow split) and the pressure drop."
        case .heatSink: return "Aluminium heat sink on a 10 W source in an air duct (conjugate heat transfer)."
        case .turbineBlade: return "A single blade in a uniform stream (static loads)."
        case .turbineRotor: return "Rotor geometry for the rotating (MRF) wind-turbine tutorial."
        }
    }

    // MARK: Geometry

    /// OpenCASCADE script that builds the model and saves `out`.
    public func script(saving out: String) -> String {
        var g = "SetFactory(\"OpenCASCADE\");\nGeneral.Terminal = 1;\n"
        switch self {
        case .sphere:
            g += "Sphere(1) = {0, 0, 0, 0.5};\n"
        case .ahmedBody:
            // 1044 x 389 x 288 mm, 100 mm front radii, 25° slant over the last 222 mm
            g += """
            L = 1.044; W = 0.389; H = 0.288; R = 0.1; S = 0.222; a = 25*Pi/180;
            Box(1) = {0, -W/2, 0.05, L, W, H};
            f() = Curve In BoundingBox{-1e-6, -1, -1, 1e-6, 1, 1};
            Fillet{1}{f()}{R}
            Box(2) = {L - S, -W, 0.05 + H, 2*S, 2*W, H};
            Rotate {{0, 1, 0}, {L - S, 0, 0.05 + H}, a} { Volume{2}; }
            BooleanDifference{ Volume{1}; Delete; }{ Volume{2}; Delete; }

            """
        case .nacaWing:
            let pts = GmshDriver.naca4Points(code: "0012", n: 60)
            let c = 0.25, aoa = 4.0 * .pi / 180
            for (i, p) in pts.enumerated() {
                let x = (p.0 - 0.25) * c, y = p.1 * c
                g += String(format: "Point(%d) = {%.9g, %.9g, 0};\n", 100 + i, x * cos(aoa) + y * sin(aoa), -x * sin(aoa) + y * cos(aoa))
            }
            g += "Spline(1) = {\((0..<pts.count).map { "\(100 + $0)" }.joined(separator: ", ")), 100};\n"
            g += "Curve Loop(1) = {1};\nPlane Surface(1) = {1};\nExtrude {0, 0, 1} { Surface{1}; }\n"
        case .pipeElbow:
            // 0.5 m straight, 90° bend of radius 0.1 m, 0.5 m straight (D = 50 mm), swept along a wire
            g += """
            Point(1) = {0, 0, 0}; Point(2) = {0.5, 0, 0}; Point(3) = {0.5, 0.1, 0}; Point(4) = {0.6, 0.1, 0}; Point(5) = {0.6, 0.6, 0};
            Line(1) = {1, 2}; Circle(2) = {2, 3, 4}; Line(3) = {4, 5};
            Wire(1) = {1, 2, 3};
            Disk(1) = {0, 0, 0, 0.025};
            Rotate {{0, 1, 0}, {0, 0, 0}, Pi/2} { Surface{1}; }
            Extrude { Surface{1}; } Using Wire {1}
            Delete { Surface{1}; }

            """
        case .teeJunction:
            g += """
            Cylinder(1) = {0, 0, 0, 0.6, 0, 0, 0.025};
            Cylinder(2) = {0.3, 0, 0, 0, -0.3, 0, 0.015};
            BooleanUnion{ Volume{1}; Delete; }{ Volume{2}; Delete; }

            """
        case .manifold:
            g += """
            Cylinder(1) = {0, 0, 0, 0.3, 0, 0, 0.015};
            Cylinder(2) = {0.075, 0, 0, 0, -0.12, 0, 0.0075};
            Cylinder(3) = {0.15, 0, 0, 0, -0.12, 0, 0.0075};
            Cylinder(4) = {0.225, 0, 0, 0, -0.12, 0, 0.0075};
            BooleanUnion{ Volume{1}; Delete; }{ Volume{2:4}; Delete; }

            """
        case .heatSink:
            // base 60 x 60 x 5 mm, 9 fins 1.2 mm thick and 30 mm tall, fins along x (flow direction)
            g += "Box(1) = {0, 0, 0, 0.06, 0.06, 0.005};\n"
            let n = 9, t = 0.0012
            let pitch = (0.06 - t) / Double(n - 1)
            for i in 0..<n { g += String(format: "Box(%d) = {0, %.9g, 0.005, 0.06, %.9g, 0.03};\n", 2 + i, Double(i) * pitch, t) }
            g += "BooleanUnion{ Volume{1}; Delete; }{ Volume{2:\(1 + n)}; Delete; }\n"
        case .turbineBlade:
            g += CADSample.bladeScript(radius: 1, firstTag: 1000, volumeTag: 1)
        case .turbineRotor:
            g += CADSample.rotorScript(radius: 1)
        }
        g += "Save \"\(GmshDriver.literal(out))\";\n"
        return g
    }

    /// One blade along +z (rotation about +x): NACA 4412 sections, chord ~ 1/r (Betz) capped at
    /// 0.12 R, twist for a 5° angle of attack at tip-speed ratio 6. Lofted with ThruSections.
    static func bladeScript(radius R: Double, firstTag: Int, volumeTag: Int,
                            tipSpeedRatio lambda: Double = 6, angleOfAttack: Double = 5, airfoil: String = "4412") -> String {
        let alpha = angleOfAttack * .pi / 180
        let stations = [0.12, 0.25, 0.45, 0.65, 0.85, 1.0]
        var g = ""
        var wires: [Int] = []
        var tag = firstTag
        for (si, rr) in stations.enumerated() {
            let r = rr * R
            let phi = atan(1 / (lambda * rr))
            let theta = phi - alpha
            let c = min(0.12, 0.052 / rr) * R
            let pts = GmshDriver.naca4Points(code: airfoil, n: 30)
            var ids: [Int] = []
            for p in pts {
                // chord from LE to TE along (sinθ x̂ + cosθ ŷ), suction side towards +x (downstream)
                let xc = (p.0 - 0.3) * c, yc = p.1 * c
                let chord = (sin(theta), cos(theta)), up = (cos(theta), -sin(theta))
                let x = xc * chord.0 + yc * up.0, y = xc * chord.1 + yc * up.1
                g += String(format: "Point(%d) = {%.9g, %.9g, %.9g};\n", tag, x, y, r)
                ids.append(tag); tag += 1
            }
            // two splines meeting at the leading and trailing edges: a single closed spline
            // lofts into periodic faces with a seam that Gmsh cannot mesh on the copies
            let le = pts.count / 2          // naca4Points: TE → LE along the upper side, then the lower side
            let up = firstTag + 500 + 2 * si, lo = up + 1, wire = firstTag + 700 + si
            g += "Spline(\(up)) = {\(ids[0...le].map(String.init).joined(separator: ", "))};\n"
            g += "Spline(\(lo)) = {\(ids[le...].map(String.init).joined(separator: ", ")), \(ids[0])};\n"
            g += "Wire(\(wire)) = {\(up), \(lo)};\n"
            wires.append(wire)
        }
        g += "ThruSections(\(volumeTag)) = {\(wires.map(String.init).joined(separator: ", "))};\n"
        return g
    }

    /// Rotor (hub + blades, rotating about +x); the resulting volumes are in the list `rotor()`.
    public static func rotorScript(radius R: Double, blades: Int = 3, tipSpeedRatio: Double = 6, angleOfAttack: Double = 5,
                                   airfoil: String = "4412", hubRadius: Double = 0.15) -> String {
        let n = max(1, min(8, blades))
        var g = bladeScript(radius: R, firstTag: 1000, volumeTag: 1, tipSpeedRatio: tipSpeedRatio, angleOfAttack: angleOfAttack, airfoil: airfoil)
        g += "copies() = {};\n"
        for k in 1..<max(n, 1) where n > 1 {
            g += "copies() += Rotate {{1, 0, 0}, {0, 0, 0}, \(2 * Double(k) / Double(n))*Pi} { Duplicata { Volume{1}; } };\n"
        }
        g += """
        Sphere(10) = {0, 0, 0, \(hubRadius * R)};
        // poles on the rotation axis and the seam between blades 2 and 3 (OCC puts them on z,
        // where blade 1 would cut through the pole and seam and Gmsh cannot mesh the hub)
        Rotate {{0, 1, 0}, {0, 0, 0}, Pi/2} { Volume{10}; }

        """
        // the seam now lies opposite blade 1; with an even blade count a blade sits there, so
        // turn the hub half a blade pitch
        if n % 2 == 0 { g += "Rotate {{1, 0, 0}, {0, 0, 0}, Pi/\(n)} { Volume{10}; }\n" }
        g += """
        rotor() = BooleanUnion{ Volume{10}; Delete; }{ Volume{1, copies()}; Delete; };

        """
        return g
    }

    /// Write the sample as STEP into `directory` (created if needed) and return its path.
    public func export(to directory: URL) throws -> URL {
        guard let exe = GmshDriver.executable else { throw MeshError.io("Gmsh is needed to build the CAD samples (install Gmsh.app)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("\(rawValue).step")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let geo = directory.appendingPathComponent("\(rawValue).geo")
        try script(saving: out.path).write(to: geo, atomically: true, encoding: .utf8)
        let (status, text) = try GmshDriver.run(exe, [geo.path, "-0", "-nopopup"], in: directory, log: nil)
        guard status == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw MeshError.io("could not build sample \(rawValue): " + text.split(separator: "\n").filter { $0.contains("Error") }.prefix(3).joined(separator: "\n"))
        }
        return out
    }

    /// Default folder for exported samples (no spaces, so OpenFOAM can use it too).
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CurlewFoam/samples")
    }
}
