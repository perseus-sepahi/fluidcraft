import Foundation
import CurlewMesh
import CurlewSolver

/// Engineering modules: parametric wind-energy and electronics-cooling cases. Each module is a
/// set of design parameters (Codable, so a case can store them) and `build()`, which makes the
/// mesh and a complete OpenFOAM case. The tutorials are the default designs.
extension TutorialCatalog {
    public static let engineering: [Tutorial] = [
        Tutorial(id: "wind-farm", title: "Wind Farm: Three Turbines in a Row (actuator disks)",
                 summary: "Three 80 m rotors 7 diameters apart in a neutral atmospheric boundary layer (log-law inlet, z0 = 5 cm, 10 m/s at hub height). Each rotor is an actuator disk (Ct 0.75, Cp 0.56); the downstream turbines sit in the wakes. Reports: disk-averaged wind speed per turbine.",
                 needsGmsh: false, suggestedField: "x-velocity") { try WindFarmModule().build() },
        Tutorial(id: "wind-turbine", title: "Wind-Turbine Rotor (rotating frame, k-ω SST)",
                 summary: "Three twisted, tapered NACA 4412 blades (D = 2 m) at tip-speed ratio 6 in a 10 m/s wind. The rotor turns in a cylindrical MRF zone. Reports: torque coefficient (power coefficient = 6 × C_m) and thrust.",
                 needsGmsh: true, suggestedField: "velocity-magnitude") { try WindTurbineRotorModule().build() },
        Tutorial(id: "chip-air", title: "Electronics Cooling: Air-Cooled Heat Sink",
                 summary: "A 10 W chip package on an FR-4 board (orthotropic conductivity) under a 7-fin aluminium heat sink, in a 2 m/s air duct. Conjugate heat transfer with k-ω SST. Reports: chip and heat-sink temperatures, heat carried by the air, pressure drop.",
                 needsGmsh: false, suggestedField: "temperature") { try AirCooledHeatSinkModule().build() },
        Tutorial(id: "chip-liquid", title: "Electronics Cooling: Liquid Cold Plate",
                 summary: "A 100 W chip under a copper cold plate with four parallel water channels between inlet and outlet manifolds (laminar, 0.05 m/s inlet ≈ 0.45 L/min, channel Re ≈ 550). Reports: chip temperature, water temperature rise and heat removed, pressure drop.",
                 needsGmsh: false, suggestedField: "temperature") { try LiquidColdPlateModule().build() },
    ]

    /// Block-mesh axis through every given edge, with about `h` per cell (at least `minCells`).
    static func axis(_ edges: [Double], h: Double, minCells: Int = 2) -> BlockAxis {
        let e = Array(Set(edges.map { ($0 * 1e9).rounded() / 1e9 })).sorted()
        return BlockAxis(start: e[0], segments: zip(e.dropFirst(), e).map { b, a in
            AxisSegment(end: b, cells: max(minCells, Int(((b - a) / h).rounded())))
        })
    }

    /// Axis that is uniform (`h`) over [fineLo, fineHi] and grows geometrically to `hCoarse`
    /// towards `lo` and `hi`.
    static func refinedAxis(_ lo: Double, _ hi: Double, fine fineLo: Double, _ fineHi: Double, h: Double, hCoarse: Double) -> BlockAxis {
        var segs: [AxisSegment] = []
        let a = max(lo, min(fineLo, hi)), b = min(hi, max(fineHi, a))
        func graded(_ L: Double, from h0: Double, to h1: Double) -> (Int, Double) {
            let n = max(1, Int((L / (0.5 * (h0 + h1))).rounded()))
            return (n, n > 1 ? h1 / h0 : 1)
        }
        if a > lo + 1e-12 { let (n, g) = graded(a - lo, from: hCoarse, to: h); segs.append(AxisSegment(end: a, cells: n, grading: g)) }
        if b > a + 1e-12 { segs.append(AxisSegment(end: b, cells: max(1, Int(((b - a) / h).rounded())))) }
        if hi > b + 1e-12 { let (n, g) = graded(hi - b, from: h, to: hCoarse); segs.append(AxisSegment(end: hi, cells: n, grading: g)) }
        return BlockAxis(start: lo, segments: segs)
    }
}

// MARK: - Wind farm

/// Actuator-disk wind farm in a neutral atmospheric boundary layer (wind along +x, z up).
public struct WindFarmModule: Codable, Sendable, Equatable {
    public var rows = 1
    public var columns = 3
    /// Rotor diameter and hub height [m].
    public var diameter = 80.0
    public var hubHeight = 90.0
    /// Turbine spacing along and across the wind, in rotor diameters.
    public var streamwiseSpacing = 7.0
    public var lateralSpacing = 5.0
    /// Wind speed at hub height [m/s] and terrain roughness length z0 [m].
    public var windSpeed = 10.0
    public var roughnessLength = 0.05
    public var thrustCoefficient = 0.75
    public var powerCoefficient = 0.56
    /// Domain margins in rotor diameters: upstream, downstream, beside the outer rows, height.
    public var upstream = 7.5
    public var downstream = 15.0
    public var lateralMargin = 5.0
    public var height = 5.0
    /// Cells across a rotor diameter (lateral and vertical; half of it along the wind).
    public var cellsPerDiameter = 8.0
    public var turbulence: ViscousModel = .kEpsilonStandard
    public var iterations = 1000

    public init() {}

    public var turbineCount: Int { max(1, rows) * max(1, columns) }
    /// Turbine positions (x, y) at hub height.
    public var positions: [(x: Double, y: Double)] {
        let D = diameter
        var out: [(Double, Double)] = []
        for r in 0..<max(1, rows) {
            for c in 0..<max(1, columns) {
                out.append((upstream * D + Double(c) * streamwiseSpacing * D, lateralMargin * D + Double(r) * lateralSpacing * D))
            }
        }
        return out
    }

    public func build() throws -> (Mesh, CaseSetup) {
        let D = diameter, hub = hubHeight
        guard D > 0, hub > D / 2 else { throw SolverError("the hub must be higher than the rotor radius") }
        let nr = max(1, rows), nc = max(1, columns)
        let Lx = (upstream + Double(nc - 1) * streamwiseSpacing + downstream) * D
        let Ly = (2 * lateralMargin + Double(nr - 1) * lateralSpacing) * D
        let Lz = max(height * D, hub + 2 * D)
        let h = D / max(cellsPerDiameter, 2)
        let pos = positions
        let x = BlockAxis(from: 0, to: Lx, cells: max(4, Int((Lx / (2 * h)).rounded())))
        let yLo = pos.map(\.y).min()! - D, yHi = pos.map(\.y).max()! + D
        let y = TutorialCatalog.refinedAxis(0, Ly, fine: yLo, yHi, h: h, hCoarse: 4 * h)
        let z = TutorialCatalog.refinedAxis(0, Lz, fine: 0, hub + D, h: h, hCoarse: 4 * h)
        let box = try BlockMeshSpec(x: x, y: y, z: z, patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, 0], boxMax: [0, Ly, Lz]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [Lx, 0, 0], boxMax: [Lx, Ly, Lz]),
            PatchRule(name: "ground", kind: .wall, boxMin: [0, 0, 0], boxMax: [Lx, Ly, 0]),
            PatchRule(name: "top", kind: .symmetry, boxMin: [0, 0, Lz], boxMax: [Lx, Ly, Lz]),
            PatchRule(name: "sides", kind: .symmetry, boxMin: [0, 0, 0], boxMax: [Lx, 0, Lz]),
            PatchRule(name: "sides", kind: .symmetry, boxMin: [0, Ly, 0], boxMax: [Lx, Ly, Lz]),
        ]).build()
        // rotor disks: about two streamwise cells thick, circular cross-section
        let half = max(2 * h, D / 8)
        let zones = [MeshBuilder.CellZoneSpec(name: "air", kind: .fluid)] + (1...pos.count).map { MeshBuilder.CellZoneSpec(name: "turbine\($0)", kind: .fluid) }
        let mesh = try box.rezoned(zones: zones) { c in
            for (i, p) in pos.enumerated() where abs(c.x - p.x) < half && (c.y - p.y) * (c.y - p.y) + (c.z - hub) * (c.z - hub) < D * D / 4 { return i + 1 }
            return 0
        }
        for (i, z) in mesh.cellZones.enumerated() where i > 0 && z.cellCount == 0 {
            throw SolverError("\(z.name) has no cells: increase the cells per diameter")
        }
        var s = CaseSetup()
        s.title = "Wind farm"
        s.models.viscous = turbulence
        s.models.wallTreatment = .standardWallFunctions
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air" }
        for (i, p) in pos.enumerated() {
            var disk = ActuatorDisk()
            disk.diskArea = .pi * D * D / 4
            disk.thrustCoefficient = thrustCoefficient
            disk.powerCoefficient = powerCoefficient
            disk.upstreamPoint = [p.x - 2.5 * D, p.y, hub]
            disk.referenceVelocity = windSpeed
            s.cellZones["turbine\(i + 1)"]!.actuatorDisk = disk
        }
        var abl = ABLProfile()
        abl.referenceVelocity = windSpeed; abl.referenceHeight = hub; abl.roughnessLength = roughnessLength
        var inlet = BoundarySettings(type: .velocityInlet); inlet.atmosphericBoundaryLayer = abl
        s.boundaries["inlet"] = inlet
        var ground = BoundarySettings(type: .wall); ground.roughnessLength = roughnessLength
        s.boundaries["ground"] = ground
        s.initialization.method = .standard
        s.initialization.velocity = [.constant(0.9 * windSpeed), 0, 0]
        s.initialization.k = abl.k(.zero); s.initialization.epsilon = abl.epsilon(Vec3(0, 0, hub))
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.run.iterations = iterations
        s.openfoam.residualP = 1e-6; s.openfoam.residualU = 1e-7; s.openfoam.residualTurbulence = 1e-7
        s.reports = (1...pos.count).map { i in
            var r = ReportDefinition(name: "turbine\(i)-wind-speed", kind: .volumeAverage)
            r.field = "x-velocity"; r.zones = ["turbine\(i)"]; return r
        }
        s.includeReferencedLibraryMaterials()
        return (mesh, s)
    }
}

// MARK: - Wind-turbine rotor

/// Resolved rotor (lofted NACA blades + hub) turning in a cylindrical MRF zone, wind along +x.
public struct WindTurbineRotorModule: Codable, Sendable, Equatable {
    public var radius = 1.0
    public var blades = 3
    public var tipSpeedRatio = 6.0
    public var windSpeed = 10.0
    /// Design angle of attack along the blade [°]; sets the twist.
    public var angleOfAttack = 5.0
    public var airfoil = "4412"
    public var hubRadius = 0.15
    /// Cell size at the blade surface and far away, relative to the radius.
    public var bladeCellSize = 0.018
    public var farCellSize = 0.45
    /// Domain in radii: upstream, downstream, beside the rotor.
    public var upstream = 3.0
    public var downstream = 8.0
    public var lateral = 3.0
    public var turbulence: ViscousModel = .kOmegaSST
    public var iterations = 800

    public init() {}

    /// Rotor speed [rad/s].
    public var omega: Double { tipSpeedRatio * windSpeed / radius }

    public func build() throws -> (Mesh, CaseSetup) {
        guard let exe = GmshDriver.executable else { throw MeshError.io("Gmsh is needed for the rotor module") }
        guard GmshDriver.naca4Points(code: airfoil, n: 4).count > 0, airfoil.filter(\.isNumber).count == 4 else { throw SolverError("airfoil must be a NACA 4-digit code") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("curlew-rotor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let R = radius, up = upstream * R, dn = downstream * R, lat = lateral * R
        let mrfR = 1.15 * R, mrfH = 0.3 * R
        var g = "SetFactory(\"OpenCASCADE\");\nGeneral.Terminal = 1;\n"
            + CADSample.rotorScript(radius: R, blades: blades, tipSpeedRatio: tipSpeedRatio, angleOfAttack: angleOfAttack, airfoil: airfoil, hubRadius: hubRadius)
        g += """
        Box(100) = {\(-up), \(-lat), \(-lat), \(up + dn), \(2 * lat), \(2 * lat)};
        Cylinder(200) = {\(-mrfH), 0, 0, \(2 * mrfH), 0, 0, \(mrfR)};
        BooleanFragments{ Volume{100}; Delete; }{ Volume{200}; Delete; }
        others() = Volume{:};
        others() -= rotor();
        BooleanDifference{ Volume{others()}; Delete; }{ Volume{rotor()}; Delete; }
        e = \(1e-4 * R);
        inner() = Volume In BoundingBox{\(-mrfH)-e, \(-mrfR)-e, \(-mrfR)-e, \(mrfH)+e, \(mrfR)+e, \(mrfR)+e};
        outer() = Volume{:};
        outer() -= inner();
        inlet() = Surface In BoundingBox{\(-up)-e, \(-lat)-e, \(-lat)-e, \(-up)+e, \(lat)+e, \(lat)+e};
        outlet() = Surface In BoundingBox{\(dn)-e, \(-lat)-e, \(-lat)-e, \(dn)+e, \(lat)+e, \(lat)+e};
        blades() = Surface In BoundingBox{\(-0.97 * mrfH), \(-1.08 * R), \(-1.08 * R), \(0.97 * mrfH), \(1.08 * R), \(1.08 * R)};
        Physical Surface("inlet") = inlet();
        Physical Surface("outlet") = outlet();
        Physical Surface("blades") = blades();
        Physical Volume("rotor") = inner();
        Physical Volume("fluid") = outer();
        Field[1] = Distance;
        Field[1].SurfacesList = {blades()};
        Field[1].Sampling = 60;
        Field[2] = Threshold;
        Field[2].InField = 1;
        Field[2].SizeMin = \(bladeCellSize * R);
        Field[2].SizeMax = \(farCellSize * R);
        Field[2].DistMin = \(0.03 * R);
        Field[2].DistMax = \(2.5 * R);
        Background Field = 2;
        Mesh.MeshSizeExtendFromBoundary = 0;
        Mesh.MeshSizeFromPoints = 0;
        Mesh.MeshSizeFromCurvature = 0;
        Mesh.Algorithm = 6;
        Mesh.Algorithm3D = 1;
        Mesh.Optimize = 1;

        """
        let geo = dir.appendingPathComponent("rotor.geo"), msh = dir.appendingPathComponent("rotor.msh")
        try g.write(to: geo, atomically: true, encoding: .utf8)
        let (status, text) = try GmshDriver.run(exe, [geo.path, "-3", "-format", "msh41", "-o", msh.path, "-nopopup"], in: dir, log: nil)
        guard status == 0 else { throw MeshError.io("Gmsh failed on the rotor: " + text.split(separator: "\n").filter { $0.contains("Error") }.prefix(3).joined(separator: "\n")) }
        let mesh = try GmshReader.read(url: msh)
        var s = CaseSetup()
        s.title = "Wind-turbine rotor"
        s.models.viscous = turbulence
        s.adopt(mesh: mesh)
        for k in s.cellZones.keys { s.cellZones[k]!.material = "air" }
        s.cellZones["rotor"]!.frameMotion = true
        s.cellZones["rotor"]!.rotationAxisDirection = [1, 0, 0]
        s.cellZones["rotor"]!.rotationSpeed = omega
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(windSpeed); inlet.turbulentIntensity = 0.02
        s.boundaries["inlet"] = inlet
        s.boundaries["outlet"] = BoundarySettings(type: .pressureOutlet)
        var bl = BoundarySettings(type: .wall); bl.wallMotion = .rotating
        bl.rotationAxisDirection = [1, 0, 0]; bl.rotationSpeed = omega
        s.boundaries["blades"] = bl
        for z in mesh.boundaryZones where !["inlet", "outlet", "blades"].contains(z.name) {
            s.boundaries[z.name] = BoundarySettings(type: .symmetry)
            if let i = mesh.boundaryZones.firstIndex(where: { $0.name == z.name }) { mesh.updateBoundaryZone(i, kind: .symmetry) }
        }
        s.reference.velocity = windSpeed; s.reference.density = 1.225; s.reference.area = .pi * R * R; s.reference.length = R
        var cm = ReportDefinition(name: "torque-coefficient", kind: .momentCoefficient); cm.zones = ["blades"]; cm.direction = [1, 0, 0]
        var thrust = ReportDefinition(name: "thrust", kind: .force); thrust.zones = ["blades"]; thrust.direction = [1, 0, 0]
        s.reports = [cm, thrust]
        s.initialization.method = .standard
        s.initialization.velocity = [.constant(windSpeed), 0, 0]
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1; s.controls.urf.momentum = 0.7
        s.run.iterations = iterations
        s.openfoam.cores = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        s.includeReferencedLibraryMaterials()
        return (mesh, s)
    }
}

// MARK: - Air-cooled heat sink

/// A chip package on a circuit board under a plate-fin heat sink, in an air duct along +x.
public struct AirCooledHeatSinkModule: Codable, Sendable, Equatable {
    /// Chip power [W] and footprint (square side) and height [m].
    public var power = 10.0
    public var chipSize = 0.02
    public var chipHeight = 0.002
    /// Board (length along the flow, width) and its thickness [m]; material.
    public var boardLength = 0.12
    public var boardWidth = 0.06
    public var boardThickness = 0.0016
    public var boardMaterial = "fr4"
    /// Heat sink footprint (square side), base thickness, fins [m]; material.
    public var heatSinkSize = 0.03
    public var baseThickness = 0.003
    public var finCount = 7
    public var finThickness = 0.001
    public var finHeight = 0.02
    public var heatSinkMaterial = "aluminum"
    /// Duct height above the board [m], inlet air speed [m/s] and temperature [K].
    public var ductHeight = 0.0384
    public var inletVelocity = 2.0
    public var inletTemperature = 300.0
    public var turbulence: ViscousModel = .kOmegaSST
    /// Cell size [m].
    public var cellSize = 0.0018
    public var iterations = 1500

    public init() {}

    public func build() throws -> (Mesh, CaseSetup) {
        let board = boardThickness, chipTop = board + chipHeight, baseTop = chipTop + baseThickness, finTop = baseTop + finHeight
        let top = board + ductHeight
        guard finTop < top - cellSize else { throw SolverError("the fins must end below the top of the duct") }
        guard heatSinkSize >= chipSize, heatSinkSize < boardWidth, heatSinkSize < boardLength else { throw SolverError("the heat sink must cover the chip and fit on the board") }
        let n = max(1, finCount), t = finThickness
        guard Double(n) * t < heatSinkSize else { throw SolverError("the fins do not fit on the heat sink") }
        let cx = boardLength / 2, cy = boardWidth / 2
        let hx0 = cx - heatSinkSize / 2, hx1 = cx + heatSinkSize / 2, hy0 = cy - heatSinkSize / 2, hy1 = cy + heatSinkSize / 2
        let chx0 = cx - chipSize / 2, chx1 = cx + chipSize / 2, chy0 = cy - chipSize / 2, chy1 = cy + chipSize / 2
        let pitch = n > 1 ? (heatSinkSize - t) / Double(n - 1) : 0
        var yEdges = [0, chy0, chy1, boardWidth, hy0, hy1]
        let finY = (0..<n).map { n > 1 ? hy0 + Double($0) * pitch : cy - t / 2 }
        for y in finY { yEdges += [y, y + t] }
        var zones: [BlockMeshSpec.CellZoneRegion] = [
            .init(name: "board", kind: .solid, box: [0, 0, 0, boardLength, boardWidth, board]),
            .init(name: "chip", kind: .solid, box: [chx0, chy0, board, chx1, chy1, chipTop]),
            .init(name: "heatsink", kind: .solid, box: [hx0, hy0, chipTop, hx1, hy1, baseTop]),
        ]
        for y in finY { zones.append(.init(name: "heatsink", kind: .solid, box: [hx0, y, baseTop, hx1, y + t, finTop])) }
        let h = cellSize
        let mesh = try BlockMeshSpec(x: TutorialCatalog.axis([0, hx0, chx0, chx1, hx1, boardLength], h: h), y: TutorialCatalog.axis(yEdges, h: h),
                                     z: TutorialCatalog.axis([0, board, chipTop, baseTop, finTop, top], h: h), patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, 0, board], boxMax: [0, boardWidth, top]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [boardLength, 0, board], boxMax: [boardLength, boardWidth, top]),
        ], cellZones: zones).build()
        var s = CaseSetup()
        s.title = "Air-cooled chip"
        s.models.viscous = turbulence
        s.models.energy = true
        s.adopt(mesh: mesh)
        s.cellZones["fluid"]?.material = "air"
        s.cellZones["board"]?.material = boardMaterial
        s.cellZones["chip"]?.material = "chip-package"
        s.cellZones["heatsink"]?.material = heatSinkMaterial
        for k in ["board", "chip", "heatsink"] { s.cellZones[k]?.kind = .solid }
        s.cellZones["chip"]?.energySource = .constant(power / (chipSize * chipSize * chipHeight))
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(inletVelocity); inlet.temperature = .constant(inletTemperature); inlet.turbulentIntensity = 0.05
        s.boundaries["inlet"] = inlet
        var outlet = BoundarySettings(type: .pressureOutlet); outlet.temperature = .constant(inletTemperature)
        s.boundaries["outlet"] = outlet
        s.initialization.method = .standard
        s.initialization.velocity = [.constant(inletVelocity), 0, 0]
        s.initialization.temperature = .constant(inletTemperature)
        s.methods.coupling = .simplec; s.controls.urf.pressure = 1
        s.residuals.energy = 1e-8
        s.run.iterations = iterations
        var tc = ReportDefinition(name: "max-chip-temperature", kind: .volumeMaximum); tc.field = "temperature"; tc.zones = ["chip"]
        var th = ReportDefinition(name: "max-heatsink-temperature", kind: .volumeMaximum); th.field = "temperature"; th.zones = ["heatsink"]
        var q = ReportDefinition(name: "heat-to-air", kind: .heatTransferRate); q.zones = ["inlet", "outlet"]
        var dp = ReportDefinition(name: "inlet-pressure", kind: .areaWeightedAverage); dp.zones = ["inlet"]
        s.reports = [tc, th, q, dp]
        s.includeReferencedLibraryMaterials()
        return (mesh, s)
    }
}

// MARK: - Liquid cold plate

/// A chip under a cold plate with parallel coolant channels between an inlet and an outlet
/// manifold (flow along +x).
public struct LiquidColdPlateModule: Codable, Sendable, Equatable {
    public var power = 100.0
    public var chipSize = 0.02
    /// Board (along the flow, across) and thickness [m]; material.
    public var plateLength = 0.06
    public var plateWidth = 0.05
    public var boardThickness = 0.002
    public var boardMaterial = "fr4"
    /// Channels: number, width and height; floor and lid thickness of the plate [m].
    public var channelCount = 4
    public var channelWidth = 0.003
    public var channelHeight = 0.004
    public var floorThickness = 0.002
    public var lidThickness = 0.002
    /// Manifold length along the flow at each end [m].
    public var manifoldLength = 0.008
    public var plateMaterial = "copper"
    public var coolant = "water-liquid"
    public var inletVelocity = 0.05
    public var inletTemperature = 300.0
    public var cellSize = 0.0008
    public var iterations = 2000

    public init() {}

    /// Volume flow rate [L/min] through the inlet manifold.
    public var flowRateLitresPerMinute: Double {
        inletVelocity * (plateWidth - 2 * 0.006) * channelHeight * 60_000
    }

    public func build() throws -> (Mesh, CaseSetup) {
        let boardTop = boardThickness, chBottom = boardTop + floorThickness, chTop = chBottom + channelHeight, top = chTop + lidThickness
        let my0 = 0.006, my1 = plateWidth - 0.006
        let n = max(1, channelCount), w = channelWidth
        guard my1 - my0 > Double(n) * w * 1.5 else { throw SolverError("the channels do not fit across the plate") }
        guard plateLength > 2 * manifoldLength + 4 * cellSize, chipSize < plateLength - 2 * manifoldLength, chipSize < plateWidth else { throw SolverError("the plate is too short for the manifolds and chip") }
        let centres = (0..<n).map { my0 + (Double($0) + 0.5) * (my1 - my0) / Double(n) }
        let cx = plateLength / 2, cy = plateWidth / 2
        let chx0 = cx - chipSize / 2, chx1 = cx + chipSize / 2, chy0 = cy - chipSize / 2, chy1 = cy + chipSize / 2
        let m0 = manifoldLength, m1 = plateLength - manifoldLength
        var yEdges = [0, chy0, chy1, plateWidth, my0, my1]
        for c in centres { yEdges += [c - w / 2, c + w / 2] }
        var zones: [BlockMeshSpec.CellZoneRegion] = [
            .init(name: "board", kind: .solid, box: [0, 0, 0, plateLength, plateWidth, boardTop]),
            .init(name: "chip", kind: .solid, box: [chx0, chy0, 0, chx1, chy1, boardTop]),
            .init(name: "coldplate", kind: .solid, box: [0, 0, boardTop, plateLength, plateWidth, top]),
            .init(name: "coolant", kind: .fluid, box: [0, my0, chBottom, m0, my1, chTop]),
            .init(name: "coolant", kind: .fluid, box: [m1, my0, chBottom, plateLength, my1, chTop]),
        ]
        for c in centres { zones.append(.init(name: "coolant", kind: .fluid, box: [m0, c - w / 2, chBottom, m1, c + w / 2, chTop])) }
        let h = cellSize
        let mesh = try BlockMeshSpec(x: TutorialCatalog.axis([0, m0, chx0, chx1, m1, plateLength], h: h), y: TutorialCatalog.axis(yEdges, h: h, minCells: 3),
                                     z: TutorialCatalog.axis([0, boardTop, chBottom, chTop, top], h: h, minCells: 3), patches: [
            PatchRule(name: "inlet", kind: .velocityInlet, boxMin: [0, my0, chBottom], boxMax: [0, my1, chTop]),
            PatchRule(name: "outlet", kind: .pressureOutlet, boxMin: [plateLength, my0, chBottom], boxMax: [plateLength, my1, chTop]),
        ], cellZones: zones).build()
        var s = CaseSetup()
        s.title = "Liquid-cooled chip"
        s.models.viscous = .laminar
        s.models.energy = true
        s.adopt(mesh: mesh)
        s.cellZones["coolant"]?.material = coolant
        s.cellZones["board"]?.material = boardMaterial
        s.cellZones["chip"]?.material = "chip-package"
        s.cellZones["coldplate"]?.material = plateMaterial
        for k in ["board", "chip", "coldplate"] { s.cellZones[k]?.kind = .solid }
        s.cellZones["chip"]?.energySource = .constant(power / (chipSize * chipSize * boardTop))
        var inlet = BoundarySettings(type: .velocityInlet); inlet.velocityMagnitude = .constant(inletVelocity); inlet.temperature = .constant(inletTemperature)
        s.boundaries["inlet"] = inlet
        var outlet = BoundarySettings(type: .pressureOutlet); outlet.temperature = .constant(inletTemperature)
        s.boundaries["outlet"] = outlet
        s.initialization.method = .standard
        s.initialization.temperature = .constant(inletTemperature)
        // coolant starting at rest in narrow passages walled by solid cells: strong relaxation
        s.methods.coupling = .simple; s.controls.urf.pressure = 0.3; s.controls.urf.momentum = 0.3
        s.residuals.energy = 1e-8
        s.run.iterations = iterations
        var tc = ReportDefinition(name: "max-chip-temperature", kind: .volumeMaximum); tc.field = "temperature"; tc.zones = ["chip"]
        var tp = ReportDefinition(name: "max-coldplate-temperature", kind: .volumeMaximum); tp.field = "temperature"; tp.zones = ["coldplate"]
        var tw = ReportDefinition(name: "coolant-outlet-temperature", kind: .massWeightedAverage); tw.field = "temperature"; tw.zones = ["outlet"]
        var q = ReportDefinition(name: "heat-to-coolant", kind: .heatTransferRate); q.zones = ["inlet", "outlet"]
        var dp = ReportDefinition(name: "inlet-pressure", kind: .areaWeightedAverage); dp.zones = ["inlet"]
        s.reports = [tc, tp, tw, q, dp]
        s.includeReferencedLibraryMaterials()
        return (mesh, s)
    }
}
