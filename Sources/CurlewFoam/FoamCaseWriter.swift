import Foundation
import CurlewMesh
import CurlewSolver

// MARK: - Report

/// What was written and how the run should proceed.
public struct FoamCaseReport: Sendable {
    public var application: FoamApplication
    public var turbulence: FoamTurbulenceModel
    public var cores: Int
    public var runsPotentialFoam: Bool
    public var files: [String] = []
    public var warnings: [String] = []
    /// Report definitions OpenFOAM evaluates live: Curlew report name → how to read it from
    /// the log. Reports not listed are computed by Curlew from the loaded results.
    public var liveReports: [FoamLiveReport] = []
    /// p is kinematic (p/rho) in this case; results are multiplied by `density`.
    public var kinematicPressure: Bool
    public var density: Double
    public var operatingPressure: Double
    /// Multi-region (CHT) cases: region names, fluid region first.
    public var regions: [String] = []
    public var isMultiRegion: Bool { !regions.isEmpty }
}

/// How a Curlew report is read from a function object's log output.
public struct FoamLiveReport: Sendable, Equatable {
    public var report: String
    /// `object/quantity` key as produced by `FoamLogParser`.
    public var key: String
    /// For vector quantities: project onto this direction (nil = scalar).
    public var direction: Vec3?
    public var scale: Double
    public var offset: Double
}

// MARK: - Writer

/// Writes an OpenFOAM (ESI v2xxx) case equivalent to a Curlew setup: polyMesh with cell
/// zones, `0/` fields, `constant/` physics and `system/` dictionaries, laid out exactly as a
/// hand-made case so it also runs from a terminal with the generated `Allrun`.
public enum FoamCaseWriter {

    public static func resolvedApplication(_ s: CaseSetup) -> FoamApplication {
        if s.openfoam.application != .automatic { return s.openfoam.application }
        // LES and DES only make sense time-accurate
        let transient = s.general.time == .transient || s.openfoam.turbulence.resolvesScales
        let hasSolid = s.cellZones.values.contains { $0.kind == .solid }
        if hasSolid && s.general.solver != .densityBased { return transient ? .chtMultiRegionFoam : .chtMultiRegionSimpleFoam }
        if s.general.solver == .densityBased { return .rhoCentralFoam }
        let fluid = fluidMaterial(s)
        if fluid?.densityMethod == .idealGas { return transient ? .rhoPimpleFoam : .rhoSimpleFoam }
        if fluid?.densityMethod == .incompressibleIdealGas {
            return transient ? .buoyantPimpleFoam : .buoyantSimpleFoam
        }
        // the Boussinesq solvers have no radiation: radiating cases use heRhoThermo
        if s.models.energy && s.openfoam.radiation.model != .none {
            return transient ? .buoyantPimpleFoam : .buoyantSimpleFoam
        }
        if s.models.energy || fluid?.densityMethod == .boussinesq {
            return transient ? .buoyantBoussinesqPimpleFoam : .buoyantBoussinesqSimpleFoam
        }
        return transient ? .pimpleFoam : .simpleFoam
    }

    public static func resolvedTurbulence(_ s: CaseSetup, application: FoamApplication) -> FoamTurbulenceModel {
        guard application.supportsTurbulence else { return .laminar }
        let t = s.openfoam.turbulence == .fromCurlew ? FoamTurbulenceModel.from(s.models.viscous) : s.openfoam.turbulence
        return t
    }

    /// potentialFoam initializes U (and phi) before the solver: always for the potentialFoam
    /// option, and for Curlew's hybrid initialization, on incompressible single-region cases
    /// with an inflow (with walls only there is no potential flow to compute). Never on top of
    /// a previous solution.
    public static func runsPotentialFoam(_ s: CaseSetup, app: FoamApplication, mesh: Mesh, initial: FlowState?) -> Bool {
        guard initial == nil || initial!.isInitialization, !app.isThermal, !app.isMultiRegion, app != .potentialFoam, !s.openfoam.continueFromLatestTime else { return false }
        switch s.openfoam.initialFields {
        case .potentialFoam: return true
        case .uniform: return false
        case .curlew:
            guard s.initialization.method == .hybrid else { return false }
            return mesh.boundaryZones.contains { z in
                let k = s.boundaries[z.name]?.type ?? z.kind
                return k == .velocityInlet || k == .massFlowInlet || k == .pressureFarField
            }
        }
    }

    static func fluidMaterial(_ s: CaseSetup) -> Material? {
        let zone = s.cellZones.values.first { $0.kind == .fluid }
        return s.material(named: zone?.material ?? "air") ?? s.materials.first { $0.kind == .fluid }
    }

    /// Write the case. `initial` supplies nonuniform initial fields (Curlew's standard
    /// initialization or a previous solution) on this mesh; nil writes uniform values.
    @discardableResult
    public static func write(mesh m: Mesh, setup inSetup: CaseSetup, to dir: URL, initial: FlowState? = nil,
                             writeMesh: Bool = true, writeFields: Bool = true, startTime: Double = 0) throws -> FoamCaseReport {
        var s = inSetup
        s.adopt(mesh: m)
        let bad = s.openfoam.invalidKeywordSettings
        guard bad.isEmpty else {
            throw SolverError("OpenFOAM settings with characters a scheme or solver name cannot have (use OpenFOAM page › Case Files for raw dictionary text): " + bad.joined(separator: "; "))
        }
        let app = resolvedApplication(s)
        let hasSolid = m.cellZones.contains { s.cellZones[$0.name]?.kind == .solid || $0.kind == .solid }
        if hasSolid && !app.isMultiRegion {
            throw SolverError("The mesh has solid cell zones: use chtMultiRegionSimpleFoam or chtMultiRegionFoam (Application: Automatic).")
        }
        let periodicEntries = try periodicPatchEntries(m, s)
        if app.isMultiRegion && (!periodicEntries.isEmpty || !s.openfoam.baffles.isEmpty) {
            throw SolverError("Periodic patches and baffles are not supported in conjugate (multi-region) cases yet.")
        }
        if app.isMultiRegion {
            var r = try FoamCHTWriter.write(mesh: m, setup: s, app: app, to: dir, initial: initial,
                                            writeMesh: writeMesh, writeFields: writeFields, startTime: startTime)
            try applyFileOverrides(s.openfoam, dir: dir, report: &r)
            return r
        }
        let w = Writer(mesh: m, setup: s, dir: dir, initial: initial, startTime: startTime)
        w.writesFields = writeFields
        try w.prepare()
        if writeMesh {
            var kinds: [String: ZoneKind] = [:]
            for z in m.boundaryZones { kinds[z.name] = s.boundaries[z.name]?.type ?? z.kind }
            try MeshWriters.writeFoamPolyMesh(m, caseDir: dir, kindOverride: kinds, patchEntries: periodicEntries)
            w.report.files += ["constant/polyMesh/{points,faces,owner,neighbour,boundary,cellZones}"]
        }
        try w.writeAll()
        try applyFileOverrides(s.openfoam, dir: dir, report: &w.report)
        return w.report
    }

    /// system/curlewPostProcess: the post-processing function objects, run by
    /// `<solver> -postProcess -latestTime -dict system/curlewPostProcess`.
    public static func postProcessDictionary(_ s: CaseSetup, usesPrgh: Bool? = nil, thermal: Bool? = nil) -> String {
        let pp = s.openfoam.postProcessing
        let app = resolvedApplication(s)
        let prgh = usesPrgh ?? app.usesPrgh
        let basic = "U \(prgh ? "p_rgh p" : "p")" + ((thermal ?? app.isThermal) || app.isBoussinesq ? " T" : "")
        func fieldList(_ text: String) -> String {
            let w = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Writer.word(String($0)) }
            return w.isEmpty ? basic : w.joined(separator: " ")
        }
        var t = FoamFile.header("dictionary", "curlewPostProcess", location: "system") + "functions\n{\n"
        let known = Set(FoamPostProcessing.availableFunctions.map(\.name))
        for f in pp.functions where known.contains(f) && !FoamPostProcessing.duringSolveFunctions.contains(f) {
            let lib = ["yPlus", "wallShearStress", "wallHeatFlux", "turbulenceFields", "CourantNo", "PecletNo", "MachNo", "vorticity", "Q", "Lambda2",
                       "enstrophy", "streamFunction", "flowType", "writeCellCentres", "writeCellVolumes"].contains(f) ? "fieldFunctionObjects" : "fieldFunctionObjects"
            t += "    \(f)\n    {\n        type            \(f);\n        libs            (\(lib));\n"
            if f == "turbulenceFields" { t += "        fields          (k epsilon omega nut);\n" }
            t += "    }\n"
        }
        for l in pp.lineSamples where l.start.count == 3 && l.end.count == 3 {
            guard let n = Writer.word(l.name) else { continue }
            t += """
                \(n)
                {
                    type            sets;
                    libs            (sampling);
                    interpolationScheme cellPoint;
                    setFormat       csv;
                    fields          (\(fieldList(l.fields)));
                    sets
                    {
                        \(n)
                        {
                            type            uniform;
                            axis            distance;
                            start           \(FoamNum.vec(l.start));
                            end             \(FoamNum.vec(l.end));
                            nPoints         \(max(2, l.points));
                        }
                    }
                }

            """
        }
        let isos = pp.isoSurfaces.filter { Writer.word($0.name) != nil && Writer.word($0.field) != nil }
        if !isos.isEmpty {
            var surf = ""
            for i in isos {
                surf += "            \(Writer.word(i.name)!)\n            {\n                type            isoSurface;\n                isoField        \(Writer.word(i.field)!);\n                isoValue        \(FoamNum.s(i.value));\n                interpolate     true;\n            }\n"
            }
            t += """
                isoSurfaces
                {
                    type            surfaces;
                    libs            (sampling);
                    surfaceFormat   vtk;
                    interpolationScheme cellPoint;
                    fields          (\(basic));
                    surfaces
                    {
            \(surf)        }
                }

            """
        }
        for e in pp.expressionFields where e.isSafe {
            guard let n = Writer.word(e.name) else { continue }
            let reads = e.referencedFields.compactMap(Writer.word)
            t += "    \(n)\n    {\n        type            exprField;\n        libs            (fieldFunctionObjects);\n        field           \(n);\n        expression      \"\(e.expression)\";\n        action          new;\n        autowrite       true;\n"
            if !reads.isEmpty { t += "        readFields      (\(reads.joined(separator: " ")));\n" }
            t += "    }\n"
        }
        for h in pp.histograms {
            guard let f = Writer.word(h.field) else { continue }
            t += "    histogram_\(f)\n    {\n        type            histogram;\n        libs            (fieldFunctionObjects);\n        field           \(f);\n        model           equalBinWidth;\n        nBins           \(max(2, h.bins));\n        setFormat       csv;\n    }\n"
        }
        let htc = pp.heatTransferCoeff
        if htc.enabled && (thermal ?? app.isThermal) {
            let walls = htc.patches.compactMap { Writer.word(MeshWriters.foamName($0)) }
            let patchList = walls.isEmpty ? "(\".*\")" : "(" + walls.joined(separator: " ") + ")"
            var model = "        htcModel        \(htc.model.rawValue);\n"
            switch htc.model {
            case .fixedReferenceTemperature: model += "        TRef            \(FoamNum.s(htc.referenceTemperature));\n"
            case .localReferenceTemperature: break
            case .ReynoldsAnalogy:
                model += "        UInf            (\(FoamNum.s(s.reference.velocity)) 0 0);\n        rho             rhoInf;\n        rhoInf          \(FoamNum.s(s.reference.density));\n        Cp              CpInf;\n        CpInf           \(FoamNum.s(fluidMaterial(s)?.specificHeat ?? 1005));\n"
            }
            t += "    heatTransferCoeff\n    {\n        type            heatTransferCoeff;\n        libs            (fieldFunctionObjects);\n        field           T;\n        patches         \(patchList);\n" + model + "    }\n"
        }
        if let a = pp.streamlineSeedStart, a.count == 3, pp.streamlineSeedEnd.count == 3 {
            t += """
                streamlines
                {
                    type            streamLine;
                    libs            (fieldFunctionObjects);
                    setFormat       vtk;
                    U               U;
                    direction       bidirectional;
                    fields          (\(basic));
                    lifeTime        10000;
                    nSubCycle       5;
                    cloud           particleTracks;
                    seedSampleSet
                    {
                        type            uniform;
                        axis            distance;
                        start           \(FoamNum.vec(a));
                        end             \(FoamNum.vec(pp.streamlineSeedEnd));
                        nPoints         \(max(2, pp.streamlineSeeds));
                    }
                }

            """
        }
        return t + "}\n"
    }

    /// polyMesh/boundary entries for periodic pairs: cyclicAMI with the translation or rotation
    /// that maps each side onto the other.
    static func periodicPatchEntries(_ m: Mesh, _ s: CaseSetup) throws -> [String: String] {
        var out: [String: String] = [:]
        func centroid(_ z: BoundaryZone) -> Vec3 {
            var a = 0.0, c = Vec3(0, 0, 0)
            for f in z.faceRange { a += m.faceAreaMag[f]; c = c + m.faceAreaMag[f] * m.faceCentres[f] }
            return a > 0 ? (1 / a) * c : c
        }
        for z in m.boundaryZones {
            guard let link = s.boundaries[z.name]?.periodic, out[z.name] == nil else { continue }
            guard let pz = m.boundaryZones.first(where: { $0.name == link.partner }), pz.name != z.name else {
                throw SolverError("periodic patch \(z.name): partner '\(link.partner)' is not a patch of the mesh")
            }
            let a = MeshWriters.foamName(z.name), b = MeshWriters.foamName(pz.name)
            func entries(_ nbr: String, _ sign: Double) -> String {
                var t = "type            cyclicAMI;\ninGroups        1(cyclicAMI);\nneighbourPatch  \(nbr);\nmatchTolerance  0.0001;\n"
                if link.rotational {
                    t += "transform       rotational;\nrotationAxis    \(FoamNum.vec(link.axis));\nrotationCentre  \(FoamNum.vec(link.centre));\nrotationAngle   \(FoamNum.s(sign * link.angle));\n"
                } else {
                    let d = link.separation.map { Vec3($0[0], $0[1], $0[2]) } ?? (centroid(pz) - centroid(z))
                    t += "transform       translational;\nseparationVector \(FoamNum.vec(sign * d));\n"
                }
                return t
            }
            out[z.name] = entries(b, 1)
            out[pz.name] = entries(a, -1)
        }
        return out
    }

    /// Replace generated files with the user's text (OpenFOAM page › Case Files). Paths stay
    /// inside the case directory.
    static func applyFileOverrides(_ o: FoamSettings, dir: URL, report: inout FoamCaseReport) throws {
        for (path, text) in o.fileOverrides.sorted(by: { $0.key < $1.key }) {
            let p = path.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, !p.hasPrefix("/"), !p.split(separator: "/").contains("..") else { continue }
            let url = dir.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            report.warnings.append("\(p) replaced by the text from OpenFOAM › Case Files.")
        }
    }
}

// MARK: - Implementation

final class Writer {
    let m: Mesh
    let s: CaseSetup
    let o: FoamSettings
    let dir: URL
    let initial: FlowState?
    let startTime: Double
    let app: FoamApplication
    let turb: FoamTurbulenceModel
    let mat: Material
    let bcd: BoundaryData
    let exprs: [String: Expr]
    var report: FoamCaseReport
    let thermal: Bool
    let buoyant: Bool
    let boussinesq: Bool
    let usesPrgh: Bool
    let solvesT: Bool
    let compressible: Bool      // rho* family (psi/rho thermo with absolute p)
    let rho: Double
    let nu: Double
    let pop: Double
    let timeDir: String
    var writesFields = true
    /// Function objects added by the multi-region writer (solid-region reports), already tagged.
    var extraFunctions = ""
    /// Multi-region: only one fluid region writes controlDict/decomposeParDict/g.
    var writesGlobalFiles = true
    /// Multi-region: the region this writer fills (files go to 0/<region>, constant/<region>,
    /// system/<region>), and its interface patches → (neighbour region, neighbour patch).
    let region: String?
    let interfaces: [String: (region: String, patch: String)]

    init(mesh: Mesh, setup: CaseSetup, dir: URL, initial: FlowState?, startTime: Double,
         region: String? = nil, interfaces: [String: (region: String, patch: String)] = [:], app appOverride: FoamApplication? = nil) {
        m = mesh; s = setup; o = setup.openfoam; self.dir = dir; self.initial = initial; self.startTime = startTime
        self.region = region; self.interfaces = interfaces
        app = appOverride ?? FoamCaseWriter.resolvedApplication(setup)
        turb = FoamCaseWriter.resolvedTurbulence(setup, application: app)
        mat = FoamCaseWriter.fluidMaterial(setup) ?? Material(name: "air")
        let compiled = (try? Expr.compileNamed(setup.expressions.map { ($0.name, $0.definition) })) ?? [:]
        exprs = compiled
        bcd = (try? BoundaryData(mesh: mesh, setup: setup, exprs: compiled, time: 0))!
        thermal = app.isThermal
        buoyant = app.isBuoyant
        boussinesq = app.isBoussinesq
        usesPrgh = app.usesPrgh
        solvesT = app.solvesTemperature
        compressible = thermal && !buoyant
        rho = mat.density
        nu = mat.viscosity / mat.density
        pop = setup.general.operatingPressure
        timeDir = FoamNum.time(startTime)
        report = FoamCaseReport(application: app, turbulence: turb, cores: max(1, setup.openfoam.cores),
                                runsPotentialFoam: FoamCaseWriter.runsPotentialFoam(setup, app: app, mesh: mesh, initial: initial),
                                kinematicPressure: !app.isThermal, density: mat.density, operatingPressure: setup.general.operatingPressure)
    }

    func prepare() throws {
        let fm = FileManager.default
        for d in (writesFields ? [timeDir] : []) + ["constant", "system"] {
            try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        if s.models.viscous == .inviscid && !thermal {
            report.warnings.append("Inviscid flow is run as laminar with the material viscosity in \(app.rawValue).")
        }
        if mat.viscosityMethod == .sutherland && !thermal {
            report.warnings.append("Sutherland viscosity needs a thermophysical solver; \(app.rawValue) uses the reference viscosity.")
        }
        if s.general.solver == .densityBased && app != .rhoCentralFoam {
            report.warnings.append("The density-based setup is solved with \(app.rawValue).")
        }
        if s.models.energy && !solvesT {
            report.warnings.append("\(app.rawValue) does not solve energy; temperature is not computed.")
        }
    }

    func writeAll() throws {
        if writesFields { try writeFields() }
        if region == nil { try writeBaffles(); try writePreProcessing(); try writePostProcessing() }
        try writeRadiation()
        try writeConstant()
        try writeSystem()
        if region == nil {
            try writeExtras()
            try writeScripts()
        }
    }

    // MARK: Pre- and post-processing (OpenFOAM utilities)

    /// A field name safe to write into a dictionary.
    static func word(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.first!.isLetter, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return nil }
        return t
    }

    func writePreProcessing() throws {
        let pre = o.preProcessing
        if !pre.mapFieldsSource.isEmpty && !pre.mapFieldsConsistent {
            try put("system/mapFieldsDict", FoamFile.header("dictionary", "mapFieldsDict", location: "system")
                    + "// patches with the same name are mapped; list pairs here for others\npatchMap        ();\ncuttingPatches  ();\n")
        }
        guard !pre.setFieldsRegions.isEmpty else { return }
        func values(_ vs: [FoamFieldValue]) -> String {
            vs.compactMap { v -> String? in
                guard let f = Writer.word(v.field) else { return nil }
                if v.isVector { return "volVectorFieldValue \(f) \(FoamNum.vec(v.vector!))" }
                // pressures are kinematic in incompressible solvers
                let scale = (f == "p" || f == "p_rgh") && !thermal ? 1 / rho : 1
                return "volScalarFieldValue \(f) \(FoamNum.s(v.scalar * scale))"
            }.joined(separator: "\n            ")
        }
        var t = FoamFile.header("dictionary", "setFieldsDict", location: "system") + "defaultFieldValues ();\n\nregions\n(\n"
        for r in pre.setFieldsRegions where r.a.count == 3 {
            switch r.shape {
            case .box:
                t += "    boxToCell\n    {\n        box \(FoamNum.vec(r.a)) \(FoamNum.vec(r.b.count == 3 ? r.b : r.a));\n"
            case .sphere:
                t += "    sphereToCell\n    {\n        origin \(FoamNum.vec(r.a));\n        radius \(FoamNum.s(r.radius));\n"
            case .cylinder:
                t += "    cylinderToCell\n    {\n        p1 \(FoamNum.vec(r.a));\n        p2 \(FoamNum.vec(r.b.count == 3 ? r.b : r.a));\n        radius \(FoamNum.s(r.radius));\n"
            }
            t += "        fieldValues\n        (\n            \(values(r.values))\n        );\n    }\n"
        }
        t += ");\n"
        try put("system/setFieldsDict", t)
    }

    func writePostProcessing() throws {
        guard !o.postProcessing.isEmpty else { return }
        try put("system/curlewPostProcess", FoamCaseWriter.postProcessDictionary(s, usesPrgh: usesPrgh, thermal: thermal))
    }

    // MARK: Baffles (createBaffles)

    /// system/createBafflesDict: each baffle's faces come from a plate, disk or box surface;
    /// OpenFOAM's createBaffles makes them into a patch pair before the run.
    func writeBaffles() throws {
        let list = o.baffles.filter { !$0.name.isEmpty }
        guard !list.isEmpty else { return }
        let pName = usesPrgh ? "p_rgh" : "p"
        let pScale = thermal ? 1.0 : 1 / rho      // kinematic pressure for incompressible solvers
        var t = FoamFile.header("dictionary", "createBafflesDict", location: "system")
        t += "internalFacesOnly true;\n\nbaffles\n{\n"
        for b in list {
            let n = MeshWriters.foamName(b.name)
            var sel: String
            switch b.shape {
            case .disk: sel = "        surface     searchableDisk;\n        origin      \(FoamNum.vec(b.origin));\n        normal      \(FoamNum.vec(b.normal));\n        radius      \(FoamNum.s(b.radius));\n"
            case .plate: sel = "        surface     searchablePlate;\n        origin      \(FoamNum.vec(b.origin));\n        span        \(FoamNum.vec(b.span));\n"
            case .box:
                let hi = zip(b.origin, b.span).map { $0 + $1 }
                sel = "        surface     searchableBox;\n        min         \(FoamNum.vec(b.origin));\n        max         \(FoamNum.vec(hi));\n"
            }
            var pair: String
            switch b.kind {
            case .fan:
                // fan jump: pressure rise as a function of the face-normal velocity Q / A
                let A = max(b.nominalArea, 1e-12)
                let pts = b.fanCurve.filter { $0.count == 2 }.sorted { $0[0] < $1[0] }
                let table = pts.map { "(\(FoamNum.s($0[0] / A)) \(FoamNum.s($0[1] * pScale)))" }.joined(separator: " ")
                pair = """
                        patchPairs
                        {
                            type            cyclic;
                            patchFields
                            {
                                \(pName)
                                {
                                    type            fan;
                                    patchType       cyclic;
                                    jump            uniform 0;
                                    value           uniform 0;
                                    jumpTable       table (\(table));
                                    uniformJump     \(b.uniformJump ? "true" : "false");
                                }
                            }
                        }

                """
            case .porousJump:
                pair = """
                        patchPairs
                        {
                            type            cyclic;
                            patchFields
                            {
                                \(pName)
                                {
                                    type            porousBafflePressure;
                                    patchType       cyclic;
                                    D               \(FoamNum.s(b.darcy));
                                    I               \(FoamNum.s(b.inertial));
                                    length          \(FoamNum.s(b.thickness));
                                    uniformJump     \(b.uniformJump ? "true" : "false");
                                    jump            uniform 0;
                                    value           uniform 0;
                                }
                            }
                        }

                """
            case .thinWall:
                var f = "                U { type noSlip; }\n"
                f += "                \(pName) { type \(usesPrgh ? "fixedFluxPressure" : "zeroGradient"); value uniform 0; }\n"
                if usesPrgh { f += "                p { type calculated; value uniform \(FoamNum.s(thermal ? pop : 0)); }\n" }
                if solvesT { f += "                T { type zeroGradient; }\n" }
                for fld in turbulenceFieldNames {
                    switch fld {
                    case "k": f += "                k { type kqRWallFunction; value uniform 1e-10; }\n"
                    case "omega": f += "                omega { type omegaWallFunction; value uniform 1; }\n"
                    case "epsilon": f += "                epsilon { type epsilonWallFunction; value uniform 1; }\n"
                    case "nuTilda": f += "                nuTilda { type fixedValue; value uniform 0; }\n"
                    default: f += "                \(fld) { type zeroGradient; }\n"
                    }
                }
                if turb.family != .laminar {
                    f += "                nut { type \(nutWallFunction); value uniform 0; }\n"
                    if thermal || boussinesq { f += "                alphat { type \(boussinesq ? "alphatJayatillekeWallFunction" : "compressible::alphatWallFunction"); Prt \(FoamNum.s(s.models.turbulentPrandtl)); value uniform 0; }\n" }
                } else {
                    f += "                nut { type calculated; value uniform 0; }\n"
                }
                pair = "        patchPairs\n        {\n            type            wall;\n            patchFields\n            {\n\(f)            }\n        }\n"
            }
            t += "    \(n)\n    {\n        type        searchableSurface;\n" + sel + pair + "    }\n"
        }
        t += "}\n"
        try put("system/createBafflesDict", t)
    }

    // MARK: Files

    func put(_ path0: String, _ text: String) throws {
        // multi-region: region files live in <dir>/<region>/; run control and gravity stay global
        var path = path0
        let global = ["system/controlDict", "system/decomposeParDict", "constant/g"].contains(path0)
        if global && !writesGlobalFiles { return }
        if let r = region, !global,
           let slash = path0.firstIndex(of: "/") {
            path = String(path0[..<slash]) + "/" + r + String(path0[slash...])
        }
        var body = text
        if let extra = o.dictionaryAppends[path], !extra.isEmpty { body += "\n// Appended from Curlew (OpenFOAM settings)\n" + extra + "\n" }
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        report.files.append(path)
    }

    // MARK: Patches

    struct Patch { let zone: BoundaryZone; let name: String; let kind: ZoneKind; let b: BoundarySettings; let first: Int }

    var patches: [Patch] {
        m.boundaryZones.map { z in
            let b = s.boundaries[z.name] ?? BoundarySettings(type: z.kind)
            return Patch(zone: z, name: MeshWriters.foamName(z.name), kind: z.kind == .empty ? .empty : b.type, b: b, first: z.start - m.nInternalFaces)
        }
    }

    /// Far-field velocity: compressible setups specify Mach number and flow direction.
    func farFieldVelocity(_ p: Patch, _ bf: Int) -> Vec3 {
        guard compressible else { return bcd.uSpec[bf] }
        let gamma = mat.specificHeat / max(mat.specificHeat - mat.gasConstant, 1e-12)
        let c = sqrt(gamma * mat.gasConstant * max(bcd.thermal.value[bf], 1))
        let d = p.b.flowDirection.count == 3 ? normalized(Vec3(p.b.flowDirection[0], p.b.flowDirection[1], p.b.flowDirection[2])) : Vec3(1, 0, 0)
        return d * p.b.machNumber * c
    }

    /// Compressible case whose inflow is supersonic (Mach ≥ 1 on an inlet or far field):
    /// outlets then extrapolate pressure instead of fixing it.
    var supersonic: Bool {
        guard compressible else { return false }
        let gamma = mat.specificHeat / max(mat.specificHeat - mat.gasConstant, 1e-12)
        for p in patches where [.velocityInlet, .pressureFarField, .massFlowInlet].contains(p.kind) {
            for i in 0..<p.zone.count {
                let bf = p.first + i
                let c = sqrt(gamma * mat.gasConstant * max(bcd.thermal.value[bf], 1))
                if norm(p.kind == .pressureFarField ? farFieldVelocity(p, bf) : bcd.uSpec[bf]) >= c { return true }
            }
        }
        return false
    }

    var hasFixedPressure: Bool {
        // a periodic side keeps its original type in the setup but fixes nothing
        patches.contains { [.pressureOutlet, .pressureInlet, .pressureFarField].contains($0.kind) && !periodicNames.contains($0.zone.name) }
    }

    func override(_ p: Patch, _ field: String) -> String? {
        o.patchOverrides.first { ($0.patch == p.zone.name || $0.patch == p.name) && $0.field == field }?.text
    }

    // MARK: Per-patch OpenFOAM conditions (OpenFOAM page › Boundary Conditions)

    /// `<model>Coeffs { … }` with the user's turbulence-model coefficients.
    var coefficientBlock: String {
        let c = o.turbulenceCoefficients.filter { k, v in Writer.word(k) != nil && v.isFinite }
        guard !c.isEmpty else { return "" }
        return "    \(turb.rawValue)Coeffs\n    {\n" + c.sorted { $0.key < $1.key }.map { "        \($0.key.padding(toLength: 15, withPad: " ", startingAt: 0)) \(FoamNum.s($0.value));\n" }.joined() + "    }\n"
    }

    func patchMeanVelocity(_ p: Patch) -> Vec3 {
        var a = 0.0, u = Vec3(0, 0, 0)
        for i in 0..<p.zone.count { let f = p.zone.start + i; a += m.faceAreaMag[f]; u = u + m.faceAreaMag[f] * bcd.uSpec[p.first + i] }
        return a > 0 ? (1 / a) * u : u
    }

    /// Velocity condition chosen on the OpenFOAM page for this patch, or nil for Curlew's own.
    func patchOptionVelocity(_ p: Patch) throws -> String? {
        let po = o.options(forPatch: p.zone.name)
        guard po.condition != .automatic, po.condition.applies(to: p.kind) else { return nil }
        let initial = vecValues(p) { bcd.uSpec[$0] }
        switch po.condition {
        case .volumetricFlowRate:
            return "        type            flowRateInletVelocity;\n        volumetricFlowRate \(FoamNum.s(po.volumetricFlowRate));\n        extrapolateProfile no;\n        value           \(initial);\n"
        case .syntheticTurbulence:
            if !app.isTransient { report.warnings.append("Synthetic inflow on \(p.zone.name) needs a transient application (LES/DES); \(app.rawValue) is steady.") }
            let u = patchMeanVelocity(p)
            let k = 1.5 * pow(po.turbulenceIntensity * norm(u), 2)
            let r = FoamNum.s(2 * k / 3)
            return """
                    type            turbulentDFSEMInlet;
                    delta           \(FoamNum.s(po.delta));
                    R               uniform (\(r) 0 0 \(r) 0 \(r));
                    U               uniform \(FoamNum.vec(u));
                    L               uniform \(FoamNum.s(po.lengthScale));
                    nCellPerEddy    1;
                    value           \(initial);

            """
        case .profileFromFile:
            try writeBoundaryProfile(p, file: po.profileFile)
            return "        type            timeVaryingMappedFixedValue;\n        offset          (0 0 0);\n        setAverage      off;\n        mapMethod       planarInterpolation;\n        value           \(initial);\n"
        default:
            return nil
        }
    }

    /// Pressure condition chosen on the OpenFOAM page (kinematic or absolute `p`), or nil.
    func patchOptionPressure(_ p: Patch, fixed: String) -> String? {
        let po = o.options(forPatch: p.zone.name)
        guard po.condition.applies(to: p.kind) else { return nil }
        switch po.condition {
        case .fanCurve:
            // kinematic solvers: pressure rise per unit density
            let scale = thermal ? 1 : 1 / rho
            let pts = po.fanCurve.filter { $0.count == 2 }.map { "(\(FoamNum.s($0[0])) \(FoamNum.s($0[1] * scale)))" }
            guard pts.count >= 2 else { report.warnings.append("Fan curve on \(p.zone.name) needs two or more points; the Curlew condition is used."); return nil }
            return "        type            fanPressure;\n        direction       \(p.kind == .pressureInlet ? "in" : "out");\n        fanCurve        table (\(pts.joined(separator: " ")));\n        p0              \(fixed);\n        value           \(fixed);\n"
        case .nonReflecting:
            guard app.isTransient else {
                report.warnings.append("The non-reflecting outlet \(p.zone.name) needs a transient application; it is a fixed pressure in \(app.rawValue).")
                return nil
            }
            let far = po.farFieldDistance > 0 ? "        fieldInf        \(fixed.replacingOccurrences(of: "uniform ", with: ""));\n        lInf            \(FoamNum.s(po.farFieldDistance));\n" : ""
            if thermal {
                let gamma = mat.specificHeat / max(mat.specificHeat - mat.gasConstant, 1e-12)
                return "        type            waveTransmissive;\n        field           p;\n        psi             thermo:psi;\n        gamma           \(FoamNum.s(gamma));\n" + far + "        value           \(fixed);\n"
            }
            return "        type            advective;\n        phi             phi;\n" + far + "        value           \(fixed);\n"
        default:
            return nil
        }
    }

    /// constant/boundaryData/<patch>/{points, 0/U} from a CSV of x, y, z, Ux, Uy, Uz.
    func writeBoundaryProfile(_ p: Patch, file: String) throws {
        let path = (file as NSString).expandingTildeInPath
        guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw SolverError("Velocity profile for \(p.zone.name): cannot read '\(file)' (CSV with x, y, z, Ux, Uy, Uz).")
        }
        var pts: [Vec3] = [], vel: [Vec3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let v = line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == ";" }).compactMap { Double($0) }
            guard v.count >= 6, v.prefix(6).allSatisfy(\.isFinite) else { continue }    // header and comment lines
            pts.append(Vec3(v[0], v[1], v[2])); vel.append(Vec3(v[3], v[4], v[5]))
        }
        guard pts.count >= 3 else { throw SolverError("Velocity profile for \(p.zone.name): '\(file)' has \(pts.count) data rows; planar interpolation needs at least 3 points spread over the patch.") }
        let base = "constant/boundaryData/\(p.name)"
        try put("\(base)/points", "// points of the inflow profile (from \((path as NSString).lastPathComponent))\n\(pts.count)\n(\n" + pts.map(FoamNum.vec).joined(separator: "\n") + "\n)\n")
        try put("\(base)/0/U", "// velocity at the profile points\n\(vel.count)\n(\n" + vel.map(FoamNum.vec).joined(separator: "\n") + "\n)\n")
    }

    // MARK: Expressions

    /// The OpenFOAM expression for a quantity that varies in time (nil when it is constant or
    /// only varies in space: those are written as uniform/nonuniform values).
    func timeExpression(_ q: Quantity) -> String? {
        guard case .expression(let src) = q, let e = try? Expr(src, named: exprs), e.dependsOnTime else { return nil }
        return e.openFOAM()
    }

    func quantityExpression(_ q: Quantity) -> String {
        switch q {
        case .constant(let d): return Expr.foamNumber(d)
        case .expression(let src): return (try? Expr(src, named: exprs))?.openFOAM() ?? "0"
        }
    }

    /// `exprFixedValue` text for a time-dependent patch value.
    func exprBC(_ expression: String, initial: String) -> String {
        "        type            exprFixedValue;\n        valueExpr       \"\(expression)\";\n        value           \(initial);\n"
    }

    /// Relative spread of the distance from the rotation axis over the zone's side boundary
    /// (faces between the zone and the rest whose normal is not along the axis).
    func mrfZoneBoundaryRadiusSpread(zone zi: Int, settings c: CellZoneSettings) -> Double? {
        let o = Vec3(c.rotationAxisOrigin[0], c.rotationAxisOrigin[1], c.rotationAxisOrigin[2])
        let a = normalized(Vec3(c.rotationAxisDirection[0], c.rotationAxisDirection[1], c.rotationAxisDirection[2]))
        var rmin = Double.infinity, rmax = 0.0
        for f in 0..<m.nInternalFaces {
            let inP = m.cellZone[Int(m.owner[f])] == Int32(zi), inN = m.cellZone[Int(m.neighbour[f])] == Int32(zi)
            guard inP != inN, abs(dot(normalized(m.faceAreas[f]), a)) < 0.5 else { continue }
            let d = m.faceCentres[f] - o
            let r = norm(d - dot(d, a) * a)
            rmin = min(rmin, r); rmax = max(rmax, r)
        }
        guard rmax > 0, rmin.isFinite else { return nil }
        return (rmax - rmin) / rmax
    }

    /// Entries shared by the atmBoundaryLayerInlet* conditions.
    func ablEntries(_ a: ABLProfile) -> String {
        """
                flowDir         \(FoamNum.vec(a.flowDirection));
                zDir            \(FoamNum.vec(a.verticalDirection));
                Uref            \(FoamNum.s(a.referenceVelocity));
                Zref            \(FoamNum.s(a.referenceHeight));
                z0              uniform \(FoamNum.s(a.roughnessLength));
                d               uniform \(FoamNum.s(a.displacement));
                kappa           \(FoamNum.s(ABLProfile.kappa));
                Cmu             \(FoamNum.s(ABLProfile.cmu));

        """
    }

    /// qr coupling at an interface: the radiating fluid side supplies qr to the solid.
    func interfaceRadiation(_ patch: String) -> (own: String, nbr: String) {
        guard radiating else { return ("none", "none") }
        return ("qr", "none")
    }

    var radiating: Bool { thermal && o.radiation.model != .none && app != .rhoCentralFoam }

    func emissivity(_ p: Patch) -> Double { o.radiation.patchEmissivity[p.zone.name] ?? o.radiation.emissivity }

    /// Radiation dictionaries and the G (P1) or IDefault (fvDOM) field.
    func writeRadiation() throws {
        guard radiating else { return }
        let r = o.radiation
        let a = r.model == .P1 ? max(r.absorption, 1e-3) : r.absorption
        if r.model == .P1 && r.absorption <= 0 { report.warnings.append("P1 radiation needs an absorbing gas; absorption set to 1e-3 1/m (use fvDOM for transparent air).") }
        var t = FoamFile.header("dictionary", "radiationProperties", location: "constant") + """
        radiation       on;
        radiationModel  \(r.model.rawValue);
        solverFreq      \(max(1, r.solverFrequency));

        """
        if r.model == .fvDOM {
            t += "fvDOMCoeffs\n{\n    nPhi            \(max(1, r.nPhi));\n    nTheta          \(max(1, r.nTheta));\n    tolerance       1e-3;\n    maxIter         10;\n}\n\n"
        }
        t += """
        absorptionEmissionModel constantAbsorptionEmission;
        constantAbsorptionEmissionCoeffs
        {
            absorptivity    absorptivity [0 -1 0 0 0 0 0] \(FoamNum.s(a));
            emissivity      emissivity   [0 -1 0 0 0 0 0] \(FoamNum.s(a));
            E               E            [1 -1 -3 0 0 0 0] 0;
        }
        scatterModel    none;
        sootModel       none;

        """
        try put("constant/radiationProperties", t)
        var b = FoamFile.header("dictionary", "boundaryRadiationProperties", location: "constant")
        b += "\".*\"\n{\n    type            lookup;\n    emissivity      \(FoamNum.s(r.emissivity));\n    absorptivity    \(FoamNum.s(r.emissivity));\n}\n"
        for p in patches where r.patchEmissivity[p.zone.name] != nil {
            b += "\(p.name)\n{\n    type            lookup;\n    emissivity      \(FoamNum.s(emissivity(p)));\n    absorptivity    \(FoamNum.s(emissivity(p)));\n}\n"
        }
        try put("constant/boundaryRadiationProperties", b)
        if writesFields {
            if r.model == .P1 {
                // Marshak's condition on every patch: walls emit with their emissivity, openings
                // radiate to a black surrounding at the boundary temperature.
                try field("G", cls: "volScalarField", dim: "[1 0 -3 0 0 0 0]", values: "uniform 0") { _ in
                    "        type            MarshakRadiation;\n        value           uniform 0;\n"
                }
            } else {
                try field("IDefault", cls: "volScalarField", dim: "[1 0 -3 0 0 0 0]", values: "uniform 0") { p in
                    "        type            greyDiffusiveRadiation;\n        value           uniform 0;\n"
                }
            }
        }
    }

    // MARK: Field writing

    func vecValues(_ p: Patch, _ f: (Int) -> Vec3) -> String {
        let vals = (0..<p.zone.count).map { f(p.first + $0) }
        if vals.allSatisfy({ norm($0 - vals[0]) <= 1e-12 * max(1, norm(vals[0])) }) { return "uniform \(FoamNum.vec(vals[0]))" }
        return "nonuniform List<vector> \(vals.count)\n(\n" + vals.map(FoamNum.vec).joined(separator: "\n") + "\n)"
    }

    func scalarValues(_ p: Patch, _ f: (Int) -> Double) -> String {
        let vals = (0..<p.zone.count).map { f(p.first + $0) }
        if vals.allSatisfy({ abs($0 - vals[0]) <= 1e-12 * max(1, abs(vals[0])) }) { return "uniform \(FoamNum.s(vals[0]))" }
        return "nonuniform List<scalar> \(vals.count)\n(\n" + vals.map(FoamNum.s).joined(separator: "\n") + "\n)"
    }

    func internalScalar(_ cells: [Double]?, uniform: Double) -> String {
        guard let c = cells, c.count == m.nCells else { return "uniform \(FoamNum.s(uniform))" }
        if let f = c.first, c.allSatisfy({ $0 == f }) { return "uniform \(FoamNum.s(f))" }
        return "nonuniform List<scalar> \(c.count)\n(\n" + c.map(FoamNum.s).joined(separator: "\n") + "\n)\n"
    }

    func internalVector(_ cells: [Vec3]?, uniform: Vec3) -> String {
        guard let c = cells, c.count == m.nCells else { return "uniform \(FoamNum.vec(uniform))" }
        return "nonuniform List<vector> \(c.count)\n(\n" + c.map(FoamNum.vec).joined(separator: "\n") + "\n)\n"
    }

    /// Writes `<time>/<name>`. `patch` returns the entries inside the patch braces;
    /// constraint patches (empty, symmetry) are handled here.
    func field(_ name: String, cls: String, dim: String, values internalValues: String, patch: (Patch) throws -> String) throws {
        var t = FoamFile.header(cls, name, location: timeDir)
        t += "dimensions      \(dim);\n\ninternalField   \(internalValues);\n\nboundaryField\n{\n"
        for p in patches {
            let body: String
            if let raw = override(p, name) { body = raw.split(separator: "\n", omittingEmptySubsequences: false).map { "        " + $0 }.joined(separator: "\n") + "\n" }
            else if p.kind == .empty { body = "        type            empty;\n" }
            else if periodicNames.contains(p.zone.name) { body = "        type            cyclicAMI;\n" }
            else if p.kind == .symmetry { body = "        type            \(MeshWriters.foamPatchType(.symmetry));\n" }
            else { body = try patch(p) }
            t += "    \(p.name)\n    {\n" + body + "    }\n"
        }
        t += "}\n"
        try put("\(timeDir)/\(name)", t)
    }

    // MARK: 0/

    var initialVelocity: Vec3 {
        let v = s.initialization.velocity
        return Vec3(v[0].constantValue ?? 0, v.count > 1 ? v[1].constantValue ?? 0 : 0, v.count > 2 ? v[2].constantValue ?? 0 : 0)
    }

    func pressureValue(_ gauge: Double) -> Double { thermal ? pop + gauge : gauge / rho }

    func writeFields() throws {
        let st = initial
        let wall = "        type            noSlip;\n"
        // U
        let u0 = st.map(\.u)
        try field("U", cls: "volVectorField", dim: "[0 1 -1 0 0 0 0]", values: internalVector(u0, uniform: initialVelocity)) { p in
            let b = p.b
            if let t = try self.patchOptionVelocity(p) { return t }
            switch p.kind {
            case .wall:
                if b.shearCondition == .specifiedShear || self.s.models.viscous == .inviscid { return "        type            slip;\n" }
                switch b.wallMotion {
                case .stationary: return wall
                case .moving: return "        type            fixedValue;\n        value           \(vecValues(p) { bcd.uSpec[$0] });\n"
                case .rotating:
                    return """
                            type            rotatingWallVelocity;
                            origin          \(FoamNum.vec(b.rotationAxisOrigin));
                            axis            \(FoamNum.vec(b.rotationAxisDirection));
                            omega           \(FoamNum.s(b.rotationSpeed));
                            value           uniform (0 0 0);

                    """
                }
            case .velocityInlet where b.atmosphericBoundaryLayer != nil && self.turb.family != .laminar:
                return "        type            atmBoundaryLayerInletVelocity;\n" + self.ablEntries(b.atmosphericBoundaryLayer!)
                    + "        value           \(vecValues(p) { bcd.uSpec[$0] });\n"
            case .velocityInlet:
                let initial = vecValues(p) { bcd.uSpec[$0] }
                if b.velocitySpecification == .magnitudeNormal, let e = timeExpression(b.velocityMagnitude) {
                    return exprBC("-(\(e))*normal()", initial: initial)
                }
                if b.velocitySpecification == .components, b.velocity.contains(where: { timeExpression($0) != nil }) {
                    let c = b.velocity.map(quantityExpression)
                    return exprBC("vector(\(c[0]), \(c.count > 1 ? c[1] : "0"), \(c.count > 2 ? c[2] : "0"))", initial: initial)
                }
                return "        type            fixedValue;\n        value           \(initial);\n"
            case .massFlowInlet:
                if thermal {
                    return "        type            flowRateInletVelocity;\n        massFlowRate    \(FoamNum.s(b.massFlowRate.constantValue ?? 0));\n        rhoInlet        \(FoamNum.s(rho));\n        value           uniform (0 0 0);\n"
                }
                return "        type            fixedValue;\n        value           \(vecValues(p) { bcd.uSpec[$0] });\n"
            case .pressureOutlet where self.compressible:
                return "        type            zeroGradient;\n"
            case .pressureOutlet, .pressureInlet:
                return "        type            pressureInletOutletVelocity;\n        value           uniform (0 0 0);\n"
            case .pressureFarField where self.supersonic:
                return "        type            fixedValue;\n        value           \(vecValues(p) { self.farFieldVelocity(p, $0) });\n"
            case .pressureFarField:
                let u = vecValues(p) { self.farFieldVelocity(p, $0) }
                return "        type            freestreamVelocity;\n        freestreamValue \(u);\n        value           \(u);\n"
            default:
                return "        type            zeroGradient;\n"
            }
        }

        // p (and p_rgh)
        let pInternal = internalScalar(st.map { $0.p.map(pressureValue) }, uniform: pressureValue(s.initialization.gaugePressure.constantValue ?? 0))
        let pDim = thermal ? "[1 -1 -2 0 0 0 0]" : "[0 2 -2 0 0 0 0]"
        func fixedP(_ p: Patch) -> String { scalarValues(p) { pressureValue(bcd.pSpec[$0]) } }
        if usesPrgh {
            let pLevel = thermal ? pop : 0
            let rhoName = boussinesq ? "        rho             rhok;\n" : ""
            try field("p", cls: "volScalarField", dim: pDim, values: pInternal) { _ in
                "        type            calculated;\n        value           uniform \(FoamNum.s(pLevel));\n"
            }
            try field("p_rgh", cls: "volScalarField", dim: pDim, values: pInternal) { p in
                switch p.kind {
                case .pressureOutlet, .pressureFarField:
                    return "        type            prghPressure;\n" + rhoName + "        p               \(fixedP(p));\n        value           \(fixedP(p));\n"
                case .pressureInlet:
                    return "        type            prghTotalPressure;\n" + rhoName + "        p0              \(fixedP(p));\n        value           \(fixedP(p));\n"
                default:
                    return "        type            fixedFluxPressure;\n" + rhoName + "        value           uniform \(FoamNum.s(pLevel));\n"
                }
            }
        } else {
            let superOutlet = supersonic
            try field("p", cls: "volScalarField", dim: pDim, values: pInternal) { p in
                if let t = self.patchOptionPressure(p, fixed: fixedP(p)) { return t }
                switch p.kind {
                case .pressureOutlet where superOutlet: return "        type            zeroGradient;\n"
                case .pressureFarField where superOutlet:
                    return "        type            fixedValue;\n        value           \(fixedP(p));\n"
                case .pressureFarField where self.compressible:
                    return "        type            freestreamPressure;\n        freestreamValue \(fixedP(p));\n        supersonic      \(superOutlet ? "true" : "false");\n        value           \(fixedP(p));\n"
                case .pressureOutlet:
                    if let e = self.timeExpression(p.b.gaugePressure) {
                        return self.exprBC(self.thermal ? "\(Expr.foamNumber(self.pop)) + (\(e))" : "(\(e))/\(Expr.foamNumber(self.rho))", initial: fixedP(p))
                    }
                    return "        type            fixedValue;\n        value           \(fixedP(p));\n"
                case .pressureInlet: return "        type            totalPressure;\n        p0              \(fixedP(p));\n        value           \(fixedP(p));\n"
                case .pressureFarField: return "        type            freestreamPressure;\n        freestreamValue \(fixedP(p));\n        value           \(fixedP(p));\n"
                default: return "        type            zeroGradient;\n"
                }
            }
        }

        // T, alphat
        if solvesT {
            let T0 = s.initialization.temperature.constantValue ?? 300
            try field("T", cls: "volScalarField", dim: "[0 0 0 1 0 0 0]", values: internalScalar(st?.T, uniform: T0)) { p in
                let b = p.b
                if self.interfaces[p.zone.name] != nil {
                    return "        type            compressible::turbulentTemperatureRadCoupledMixed;\n        Tnbr            T;\n        qrNbr           \(self.interfaceRadiation(p.zone.name).nbr);\n        qr              \(self.interfaceRadiation(p.zone.name).own);\n        kappaMethod     fluidThermo;\n        value           uniform \(FoamNum.s(T0));\n"
                }
                switch p.kind {
                case .wall:
                    switch b.thermalCondition {
                    case .temperature:
                        if let e = self.timeExpression(b.temperature) { return self.exprBC(e, initial: scalarValues(p) { bcd.thermal.value[$0] }) }
                        return "        type            fixedValue;\n        value           \(scalarValues(p) { bcd.thermal.value[$0] });\n"
                    case .adiabatic: return "        type            zeroGradient;\n"
                    case .heatFlux where self.boussinesq:
                        // -k dT/dn_in = q  →  dT/dn_out = q / k
                        return "        type            fixedGradient;\n        gradient        \(scalarValues(p) { bcd.thermal.coeff[$0] / max(mat.thermalConductivity, 1e-300) });\n"
                    case .convection where self.boussinesq:
                        // Robin as mixed: valueFraction = h / (h + k/δ) per face
                        let frac = scalarValues(p) { bf in
                            let f = bf + m.nInternalFaces
                            let d = max(abs(dot(m.faceCentres[f] - m.cellCentres[Int(m.owner[f])], normalized(m.faceAreas[f]))), 1e-300)
                            let h = bcd.thermal.coeff[bf]
                            return h / (h + mat.thermalConductivity / d)
                        }
                        return "        type            mixed;\n        refValue        \(scalarValues(p) { bcd.thermal.value[$0] });\n        refGradient     uniform 0;\n        valueFraction   \(frac);\n        value           uniform \(FoamNum.s(T0));\n"
                    case .heatFlux:
                        return "        type            externalWallHeatFluxTemperature;\n        mode            flux;\n        q               \(scalarValues(p) { bcd.thermal.coeff[$0] });\n        kappaMethod     fluidThermo;\n        value           uniform \(FoamNum.s(T0));\n"
                    case .convection:
                        return "        type            externalWallHeatFluxTemperature;\n        mode            coefficient;\n        h               \(scalarValues(p) { bcd.thermal.coeff[$0] });\n        Ta              \(scalarValues(p) { bcd.thermal.value[$0] });\n        kappaMethod     fluidThermo;\n        value           uniform \(FoamNum.s(T0));\n"
                    }
                case .velocityInlet, .massFlowInlet, .pressureInlet:
                    if let e = self.timeExpression(b.temperature) { return self.exprBC(e, initial: scalarValues(p) { bcd.thermal.value[$0] }) }
                    return "        type            fixedValue;\n        value           \(scalarValues(p) { bcd.thermal.value[$0] });\n"
                case .pressureFarField where self.supersonic:
                    return "        type            fixedValue;\n        value           \(scalarValues(p) { bcd.thermal.value[$0] });\n"
                case .pressureOutlet where self.supersonic:
                    return "        type            zeroGradient;\n"
                default:
                    let v = scalarValues(p) { bcd.thermal.value[$0] }
                    return "        type            inletOutlet;\n        inletValue      \(v);\n        value           \(v);\n"
                }
            }
            if turb.family != .laminar || boussinesq {
                let prt = FoamNum.s(s.models.turbulentPrandtl)
                let laminar = turb.family == .laminar
                let bq = boussinesq
                try field("alphat", cls: "volScalarField", dim: bq ? "[0 2 -1 0 0 0 0]" : "[1 -1 -1 0 0 0 0]", values: "uniform 0") { p in
                    p.kind == .wall && !laminar ? "        type            \(bq ? "alphatJayatillekeWallFunction" : "compressible::alphatWallFunction");\n        Prt             \(prt);\n        value           uniform 0;\n"
                                    : "        type            calculated;\n        value           uniform 0;\n"
                }
            }
        }

        // Turbulence
        try writeTurbulenceFields()

        // Passive scalars (scalarTransport function objects)
        for (i, sc) in s.models.passiveScalars.enumerated() {
            let name = MeshWriters.foamName(sc.name)
            let cells = st.flatMap { i < $0.scalars.count ? $0.scalars[i] : nil }
            try field(name, cls: "volScalarField", dim: "[0 0 0 0 0 0 0]", values: internalScalar(cells, uniform: 0)) { p in
                let v = p.b.scalars[sc.name] ?? 0
                switch p.kind {
                case .velocityInlet, .massFlowInlet, .pressureInlet: return "        type            fixedValue;\n        value           uniform \(FoamNum.s(v));\n"
                case .pressureOutlet, .outflow, .pressureFarField: return "        type            inletOutlet;\n        inletValue      uniform 0;\n        value           uniform 0;\n"
                default: return "        type            zeroGradient;\n"
                }
            }
        }
    }

    /// Patches that are one side of a periodic pair.
    lazy var periodicNames: Set<String> = {
        var n = Set<String>()
        for z in m.boundaryZones { if let l = s.boundaries[z.name]?.periodic, !l.partner.isEmpty { n.insert(z.name); n.insert(l.partner) } }
        return n
    }()

    var nutWallFunction: String {
        switch o.wallTreatment {
        case .lowRe: return "nutLowReWallFunction"
        case .standardWallFunctions: return "nutkWallFunction"
        case .spalding: return "nutUSpaldingWallFunction"
        case .automatic:
            if turb == .kEpsilon || turb == .realizableKE || turb == .RNGkEpsilon {
                return s.models.wallTreatment == .standardWallFunctions ? "nutkWallFunction" : "nutUSpaldingWallFunction"
            }
            return turb == .LaunderSharmaKE ? "nutLowReWallFunction" : "nutUSpaldingWallFunction"
        }
    }

    func writeTurbulenceFields() throws {
        guard turb.family != .laminar else { return }
        let st = initial
        let ini = s.initialization
        func inletAverage(_ v: (Int) -> Double) -> Double {
            let vals = (0..<bcd.nB).filter { [.velocityInlet].contains(bcd.kind[$0]) }.map(v)
            return vals.isEmpty ? v(0) : vals.reduce(0, +) / Double(vals.count)
        }
        func turbField(_ name: String, _ dim: String, cells: [Double]?, uniform: Double, inlet: @escaping (Int) -> Double, wall: String) throws {
            try field(name, cls: "volScalarField", dim: dim, values: internalScalar(cells, uniform: uniform)) { p in
                switch p.kind {
                case .wall: return wall
                case .velocityInlet where p.b.atmosphericBoundaryLayer != nil && ["k", "epsilon", "omega"].contains(name):
                    let t = ["k": "atmBoundaryLayerInletK", "epsilon": "atmBoundaryLayerInletEpsilon", "omega": "atmBoundaryLayerInletOmega"][name]!
                    return "        type            \(t);\n" + self.ablEntries(p.b.atmosphericBoundaryLayer!) + "        value           \(self.scalarValues(p, inlet));\n"
                case .velocityInlet, .massFlowInlet, .pressureInlet:
                    return "        type            fixedValue;\n        value           \(scalarValues(p, inlet));\n"
                default:
                    let v = scalarValues(p, inlet)
                    return "        type            inletOutlet;\n        inletValue      \(v);\n        value           \(v);\n"
                }
            }
        }
        let lowRe = o.wallTreatment == .lowRe || turb == .LaunderSharmaKE
        let les = turb.family == .LES && !turb.rawValue.contains("DES")
        if turb.fields.contains("k") {
            let kw = (lowRe || les) ? "        type            fixedValue;\n        value           uniform 1e-10;\n"
                                    : "        type            kqRWallFunction;\n        value           uniform 0;\n"
            try turbField("k", "[0 2 -2 0 0 0 0]", cells: st?.k, uniform: initial == nil ? (s.initialization.method == .standard && ini.computeFrom.isEmpty ? ini.k : inletAverage { bcd.k.value[$0] }) : 0,
                          inlet: { self.bcd.k.value[$0] }, wall: kw)
        }
        if turb.fields.contains("omega") {
            try turbField("omega", "[0 0 -1 0 0 0 0]", cells: st?.omega, uniform: initial == nil ? (s.initialization.method == .standard && ini.computeFrom.isEmpty ? ini.omega : inletAverage { bcd.omega.value[$0] }) : 0,
                          inlet: { self.bcd.omega.value[$0] }, wall: "        type            omegaWallFunction;\n        value           uniform 1;\n")
        }
        if turb.fields.contains("epsilon") {
            try turbField("epsilon", "[0 2 -3 0 0 0 0]", cells: st?.epsilon, uniform: initial == nil ? (s.initialization.method == .standard && ini.computeFrom.isEmpty ? ini.epsilon : inletAverage { bcd.epsilon.value[$0] }) : 0,
                          inlet: { self.bcd.epsilon.value[$0] },
                          wall: turb == .LaunderSharmaKE ? "        type            fixedValue;\n        value           uniform 1e-10;\n" : "        type            epsilonWallFunction;\n        value           uniform 1;\n")
        }
        if turb.fields.contains("nuTilda") {
            try turbField("nuTilda", "[0 2 -1 0 0 0 0]", cells: st?.nuTilda, uniform: initial == nil ? (s.initialization.method == .standard && ini.computeFrom.isEmpty ? ini.modifiedTurbulentViscosity : inletAverage { bcd.nuTilda.value[$0] }) : 0,
                          inlet: { self.bcd.nuTilda.value[$0] }, wall: "        type            fixedValue;\n        value           uniform 0;\n")
        }
        if turb.fields.contains("ReThetat") {
            // Langtry–Menter correlation of the transition onset Reynolds number with the inlet turbulence intensity
            func reTheta(_ bf: Int) -> Double {
                let u = max(norm(self.bcd.uSpec[bf]), 1e-6)
                let tu = max(100 * (2 * max(self.bcd.k.value[bf], 0) / 3).squareRoot() / u, 0.027)
                return tu <= 1.3 ? 1173.51 - 589.428 * tu + 0.2196 / (tu * tu) : 331.5 * pow(tu - 0.5658, -0.671)
            }
            try turbField("ReThetat", "[0 0 0 0 0 0 0]", cells: nil, uniform: inletAverage(reTheta), inlet: reTheta,
                          wall: "        type            zeroGradient;\n")
            try turbField("gammaInt", "[0 0 0 0 0 0 0]", cells: nil, uniform: 1, inlet: { _ in 1 }, wall: "        type            zeroGradient;\n")
        }
        if turb.fields.contains("R") {
            func rr(_ k: Double) -> String { let d = FoamNum.s(2 * max(k, 0) / 3); return "(\(d) 0 0 \(d) 0 \(d))" }
            func rlist(_ p: Patch) -> String {
                let n = p.zone.count
                guard n > 0 else { return "uniform (0 0 0 0 0 0)" }
                let vals = (0..<n).map { rr(self.bcd.k.value[p.zone.start - m.nInternalFaces + $0]) }
                return Set(vals).count == 1 ? "uniform \(vals[0])" : "nonuniform List<symmTensor> \(n)(" + vals.joined(separator: " ") + ")"
            }
            let k0 = initial == nil ? (s.initialization.method == .standard && ini.computeFrom.isEmpty ? ini.k : inletAverage { bcd.k.value[$0] }) : 0
            let rInternal: String
            if let kc = st?.k, kc.count == m.nCells { rInternal = "nonuniform List<symmTensor> \(m.nCells)(" + kc.map(rr).joined(separator: " ") + ")" }
            else { rInternal = "uniform \(rr(k0))" }
            let lesR = turb.family == .LES
            try field("R", cls: "volSymmTensorField", dim: "[0 2 -2 0 0 0 0]", values: rInternal) { p in
                switch p.kind {
                case .wall: return lesR ? "        type            fixedValue;\n        value           uniform (0 0 0 0 0 0);\n"
                                        : "        type            kqRWallFunction;\n        value           uniform (0 0 0 0 0 0);\n"
                case .velocityInlet, .massFlowInlet, .pressureInlet:
                    return "        type            fixedValue;\n        value           \(rlist(p));\n"
                default:
                    return "        type            inletOutlet;\n        inletValue      \(rlist(p));\n        value           \(rlist(p));\n"
                }
            }
        }
        let rhoCells = st?.rho
        let nutCells = st.map { state in (0..<m.nCells).map { state.muT[$0] / max(rhoCells?[$0] ?? rho, 1e-300) } }
        let nutWall = nutWallFunction
        let kBased = turb.fields.contains("k") || turb.fields.contains("R")
        try field("nut", cls: "volScalarField", dim: "[0 2 -1 0 0 0 0]", values: internalScalar(nutCells, uniform: 0)) { p in
            let po = self.o.options(forPatch: p.zone.name)
            if p.kind == .wall && po.condition == .roughWall && po.roughnessHeight > 0 && kBased {
                return "        type            nutkRoughWallFunction;\n        Ks              uniform \(FoamNum.s(po.roughnessHeight));\n        Cs              uniform \(FoamNum.s(po.roughnessConstant));\n        value           uniform 0;\n"
            }
            if p.kind == .wall && p.b.roughnessLength > 0 {
                // rough ground: atmospheric log law with aerodynamic roughness z0
                return "        type            atmNutkWallFunction;\n        boundNut        false;\n        z0              uniform \(FoamNum.s(p.b.roughnessLength));\n        value           uniform 0;\n"
            }
            return p.kind == .wall ? "        type            \(nutWall);\n        value           uniform 0;\n"
                                   : "        type            calculated;\n        value           uniform 0;\n"
        }
    }

    // MARK: constant/

    func writeConstant() throws {
        // Turbulence
        var t = FoamFile.header("dictionary", "turbulenceProperties", location: "constant")
        switch turb.family {
        case .laminar:
            t += "simulationType  laminar;\n"
        case .RAS:
            t += "simulationType  RAS;\n\nRAS\n{\n    RASModel        \(turb.rawValue);\n    turbulence      on;\n    printCoeffs     on;\n\(turb == .kOmegaSSTSAS ? "    delta           cubeRootVol;\n    cubeRootVolCoeffs { deltaCoeff 1; }\n" : "")\(coefficientBlock)}\n"
        case .LES:
            // IDDES models only accept the IDDES filter width.
            let delta = turb.rawValue.hasSuffix("IDDES") ? "IDDESDelta" : o.lesDelta
            t += """
            simulationType  LES;

            LES
            {
                LESModel        \(turb.rawValue);
                turbulence      on;
                printCoeffs     on;
                delta           \(delta);
            \(coefficientBlock)

                IDDESDeltaCoeffs
                {
                    hmax            maxDeltaxyzCubeRoot;
                    maxDeltaxyzCubeRootCoeffs { }
                }

                cubeRootVolCoeffs { deltaCoeff 1; }
                maxDeltaxyzCoeffs { deltaCoeff 2; }
                smoothCoeffs
                {
                    delta           cubeRootVol;
                    cubeRootVolCoeffs { deltaCoeff 1; }
                    maxDeltaRatio   1.1;
                }
                vanDriestCoeffs
                {
                    delta           cubeRootVol;
                    cubeRootVolCoeffs { deltaCoeff 1; }
                    smoothCoeffs { delta cubeRootVol; cubeRootVolCoeffs { deltaCoeff 1; } maxDeltaRatio 1.1; }
                    Aplus           26;
                    Cdelta          0.158;
                }
            }

            """
        }
        try put("constant/turbulenceProperties", t)

        if thermal {
            try writeThermophysical()
        } else {
            var tp = FoamFile.header("dictionary", "transportProperties", location: "constant")
            if mat.viscosityMethod == .powerLaw {
                tp += """
                transportModel  powerLaw;

                nu              \(FoamNum.s(nu));

                powerLawCoeffs
                {
                    nuMax       \(FoamNum.s(mat.powerLawMax / rho));
                    nuMin       \(FoamNum.s(mat.powerLawMin / rho));
                    k           \(FoamNum.s(mat.powerLawK / rho));
                    n           \(FoamNum.s(mat.powerLawN));
                }

                """
            } else {
                tp += "transportModel  Newtonian;\n\nnu              \(FoamNum.s(nu));\n"
            }
            if boussinesq {
                let pr = mat.thermalConductivity > 0 ? mat.viscosity * mat.specificHeat / mat.thermalConductivity : 0.71
                let beta = mat.densityMethod == .boussinesq ? mat.thermalExpansion : 0
                tp += "\n// Boussinesq: rhok = 1 - beta (T - TRef)\nbeta            \(FoamNum.s(beta));\nTRef            \(FoamNum.s(s.general.operatingTemperature));\nPr              \(FoamNum.s(pr));\nPrt             \(FoamNum.s(s.models.turbulentPrandtl));\n"
            }
            try put("constant/transportProperties", tp)
        }

        if thermal || boussinesq || s.general.gravityEnabled {
            let g = s.general.gravityEnabled ? s.general.gravity : [0, 0, 0]
            try put("constant/g", FoamFile.header("uniformDimensionedVectorField", "g", location: "constant")
                    + "dimensions      [0 1 -2 0 0 0 0];\nvalue           \(FoamNum.vec(g));\n")
        }

        // MRF zones
        let mrf = m.cellZones.compactMap { z -> (String, CellZoneSettings)? in
            guard let c = s.cellZones[z.name], c.frameMotion else { return nil }
            return (MeshWriters.foamName(z.name), c)
        }
        for (zi, z) in m.cellZones.enumerated() {
            guard let c = s.cellZones[z.name], c.frameMotion else { continue }
            if let spread = mrfZoneBoundaryRadiusSpread(zone: zi, settings: c), spread > 0.02 {
                report.warnings.append(String(format: "MRF zone %@ is not a surface of revolution (its boundary radius varies by %.0f %%): the frame change creates spurious flow at the zone boundary. Use a cylindrical zone around the rotor.", z.name as NSString, 100 * spread))
            }
        }
        if !mrf.isEmpty {
            var t = FoamFile.header("dictionary", "MRFProperties", location: "constant")
            for (name, c) in mrf {
                t += """
                MRF_\(name)
                {
                    cellZone        \(name);
                    active          yes;
                    nonRotatingPatches ();
                    origin          \(FoamNum.vec(c.rotationAxisOrigin));
                    axis            \(FoamNum.vec(c.rotationAxisDirection));
                    omega           \(FoamNum.s(c.rotationSpeed));
                }

                """
            }
            try put("constant/MRFProperties", t)
        }

        // fvOptions: porosity and volumetric sources
        var opts = ""
        for z in m.cellZones {
            guard let c = s.cellZones[z.name] else { continue }
            let name = MeshWriters.foamName(z.name)
            if let por = c.porous {
                opts += """
                porosity_\(name)
                {
                    type            explicitPorositySource;
                    explicitPorositySourceCoeffs
                    {
                        selectionMode   cellZone;
                        cellZone        \(name);
                        type            DarcyForchheimer;
                        d               \(FoamNum.vec(por.viscousResistance));
                        f               \(FoamNum.vec(por.inertialResistance));
                        coordinateSystem { origin (0 0 0); e1 (1 0 0); e2 (0 1 0); }
                    }
                }

                """
            }
            let scale = thermal ? 1 : 1 / rho
            if c.momentumSource.contains(where: { $0.constantValue == nil }) {
                // expression source evaluated by OpenFOAM at cell centres (and time)
                let comps = (0..<3).map { $0 < c.momentumSource.count ? quantityExpression(c.momentumSource[$0]) : "0" }
                opts += """
                momentumSource_\(name)
                {
                    type            vectorSemiImplicitSource;
                    selectionMode   cellZone;
                    cellZone        \(name);
                    volumeMode      specific;
                    sources
                    {
                        U
                        {
                            explicit { type exprField; expression "vector(\(comps[0]), \(comps[1]), \(comps[2]))*\(Expr.foamNumber(scale))"; }
                            implicit 0;
                        }
                    }
                }

                """
            }
            let ms = c.momentumSource.map { $0.constantValue ?? 0 }
            if ms.contains(where: { $0 != 0 }) && !c.momentumSource.contains(where: { $0.constantValue == nil }) {
                opts += """
                momentumSource_\(name)
                {
                    type            vectorSemiImplicitSource;
                    selectionMode   cellZone;
                    cellZone        \(name);
                    volumeMode      specific;
                    sources { U (\(FoamNum.vec(ms.map { $0 * scale })) 0); }
                }

                """
            }
            if let q = c.energySource.constantValue, q != 0, solvesT {
                let (fieldName, value) = boussinesq ? ("T", q / (rho * mat.specificHeat)) : (internalEnergy ? "e" : "h", q)
                opts += """
                energySource_\(name)
                {
                    type            scalarSemiImplicitSource;
                    selectionMode   cellZone;
                    cellZone        \(name);
                    volumeMode      specific;
                    sources { \(fieldName) (\(FoamNum.s(value)) 0); }
                }

                """
            }
            if case .expression = c.energySource, solvesT {
                let (fieldName, factor) = boussinesq ? ("T", 1 / (rho * mat.specificHeat)) : (internalEnergy ? "e" : "h", 1.0)
                opts += """
                energySource_\(name)
                {
                    type            scalarSemiImplicitSource;
                    selectionMode   cellZone;
                    cellZone        \(name);
                    volumeMode      specific;
                    sources
                    {
                        \(fieldName)
                        {
                            explicit { type exprField; expression "(\(quantityExpression(c.energySource)))*\(Expr.foamNumber(factor))"; }
                            implicit 0;
                        }
                    }
                }

                """
            }
        }
        if thermal && app != .rhoCentralFoam {
            // Curlew's temperature limits (Controls), tightened to a physical floor: nothing in
            // an incompressible heat-transfer case gets colder than its coldest boundary.
            var coldest = s.initialization.temperature.constantValue ?? 300
            for bf in 0..<bcd.nB where bcd.thermal.kind[bf] == .fixedValue { coldest = min(coldest, bcd.thermal.value[bf]) }
            let lim = s.controls.limits
            let floor = max(lim.minimumTemperature, (compressible ? 0.5 : 0.9) * coldest)
            opts += """
            limitT
            {
                type            limitTemperature;
                selectionMode   all;
                min             \(FoamNum.s(floor));
                max             \(FoamNum.s(lim.maximumTemperature));
            }

            """
        }
        if let ub = o.meanVelocity, ub.count == 3 {
            opts += """
            meanVelocity
            {
                type            meanVelocityForce;
                selectionMode   all;
                fields          (U);
                Ubar            \(FoamNum.vec(ub));
                relaxation      1;
            }

            """
        }
        if let umax = o.limitVelocity, umax > 0 {
            opts += """
            limitU
            {
                type            limitVelocity;
                selectionMode   all;
                max             \(FoamNum.s(umax));
            }

            """
        }
        for z in m.cellZones {
            guard let disk = s.cellZones[z.name]?.actuatorDisk else { continue }
            let name = MeshWriters.foamName(z.name)
            if thermal { report.warnings.append("Actuator disk \(z.name): actuationDiskSource is written for an incompressible U equation.") }
            opts += """
            actuatorDisk_\(name)
            {
                type            actuationDiskSource;
                variant         Froude;
                selectionMode   cellZone;
                cellZone        \(name);
                diskArea        \(FoamNum.s(disk.diskArea));
                diskDir         \(FoamNum.vec(disk.direction));
                writeToFile     true;
                sink            true;
                Cp              \(FoamNum.s(disk.powerCoefficient));
                Ct              \(FoamNum.s(disk.thrustCoefficient));
                monitorMethod   points;
                monitorCoeffs
                {
                    points      (\(FoamNum.vec(disk.upstreamPoint)));
                }
            }

            """
        }
        opts += try extraFvOptions()
        if !opts.isEmpty { try put("constant/fvOptions", FoamFile.header("dictionary", "fvOptions", location: "constant") + opts) }
        try writeDynamicMeshDict()
    }

    /// fvOptions and constraints from OpenFOAM page › Sources and Constraints.
    func extraFvOptions() throws -> String {
        var t = ""
        for opt in o.fvOptions {
            guard let name = Writer.word(opt.name) else { report.warnings.append("fvOption '\(opt.name)' skipped: not an OpenFOAM word."); continue }
            var selection = "    selectionMode   all;\n"
            if !opt.zone.isEmpty {
                guard m.cellZones.contains(where: { $0.name == opt.zone }) else { throw SolverError("fvOption \(opt.name): cell zone '\(opt.zone)' is not in the mesh.") }
                selection = "    selectionMode   cellZone;\n    cellZone        \(MeshWriters.foamName(opt.zone));\n"
            }
            switch opt.kind {
            case .fixedTemperature:
                guard thermal else { report.warnings.append("fvOption \(opt.name): fixedTemperatureConstraint needs a thermophysical solver; skipped."); continue }
                t += "\(name)\n{\n    type            fixedTemperatureConstraint;\n" + selection + "    mode            uniform;\n    temperature     constant \(FoamNum.s(opt.temperature));\n}\n\n"
            case .velocityDamping:
                t += "\(name)\n{\n    type            velocityDampingConstraint;\n" + selection + "    UMax            \(FoamNum.s(opt.maximumVelocity));\n}\n\n"
            case .rotorDisk:
                guard !opt.zone.isEmpty else { throw SolverError("Rotor \(opt.name): choose the cell zone the rotor sweeps.") }
                let r = opt.rotor
                let sections = r.sections.filter { $0.count == 3 }.map { "            (profile1 (\(FoamNum.s($0[0])) \(FoamNum.s($0[1])) \(FoamNum.s($0[2]))))" }
                let profile = r.profile.filter { $0.count == 3 }.map { "                    (\(FoamNum.s($0[0])) \(FoamNum.s($0[1])) \(FoamNum.s($0[2])))" }
                guard sections.count >= 2, profile.count >= 2 else { throw SolverError("Rotor \(opt.name): needs at least two blade sections and two airfoil table rows.") }
                if thermal { report.warnings.append("Rotor \(opt.name): rotorDisk is written for an incompressible U equation.") }
                t += """
                \(name)
                {
                    type            rotorDisk;
                \(selection)    fields          (U);
                    nBlades         \(max(1, r.blades));
                    tipEffect       \(FoamNum.s(r.tipEffect));
                    inletFlowType   local;
                    geometryMode    specified;
                    origin          \(FoamNum.vec(r.origin));
                    axis            \(FoamNum.vec(r.axis));
                    refDirection    \(FoamNum.vec(r.referenceDirection));
                    rpm             \(FoamNum.s(r.rpm));
                    trimModel       fixedTrim;
                    rhoRef          \(FoamNum.s(rho));
                    rhoInf          \(FoamNum.s(rho));
                    fixedTrimCoeffs { theta0 \(FoamNum.s(r.collectivePitch)); theta1c 0; theta1s 0; }
                    flapCoeffs { beta0 0; beta1c 0; beta2s 0; }
                    blade
                    {
                        data
                        (
                \(sections.joined(separator: "\n"))
                        );
                    }
                    profiles
                    {
                        profile1
                        {
                            type    lookup;
                            data
                            (
                \(profile.joined(separator: "\n"))
                            );
                        }
                    }
                }


                """
            }
        }
        return t
    }

    /// constant/dynamicMeshDict for adaptive refinement (dynamicRefineFvMesh).
    func writeDynamicMeshDict() throws {
        let a = o.adaptiveRefinement
        guard a.enabled, region == nil else { return }
        guard app.isTransient else { report.warnings.append("Adaptive refinement needs a transient application; \(app.rawValue) is steady, so it is off."); return }
        let hist = m.cellShapeHistogram()
        if hist.contains(where: { $0.key != "hexahedra" && $0.value > 0 }) {
            report.warnings.append("Adaptive refinement (hexRef8) only refines hexahedra; this mesh also has \(hist.filter { $0.key != "hexahedra" && $0.value > 0 }.keys.sorted().joined(separator: ", ")).")
        }
        let fieldName = a.isExpression ? "refinementIndicator" : (Writer.word(a.field) ?? "p")
        let t = FoamFile.header("dictionary", "dynamicMeshDict", location: "constant") + """
        dynamicFvMesh   dynamicRefineFvMesh;

        dynamicRefineFvMeshCoeffs
        {
            refineInterval  \(max(1, a.refineInterval));
            field           \(fieldName);
            lowerRefineLevel \(FoamNum.s(a.lowerLevel));
            upperRefineLevel \(FoamNum.s(a.upperLevel));
            unrefineLevel   \(FoamNum.s(a.unrefineLevel));
            nBufferLayers   \(max(1, a.bufferLayers));
            maxRefinement   \(max(1, a.maxRefinement));
            maxCells        \(max(1, a.maxCells));
            correctFluxes
            (
                (phi none)
                (nHatf none)
            );
            dumpLevel       true;
        }

        """
        try put("constant/dynamicMeshDict", t)
    }

    func writeThermophysical() throws {
        if !o.thermo.isAutomatic { return try writeThermophysicalModel() }
        let psi = compressible && mat.densityMethod == .idealGas
        let eos: String
        var eosCoeffs: String
        switch mat.densityMethod {
        case .idealGas: eos = "perfectGas"; eosCoeffs = ""
        case .incompressibleIdealGas: eos = "incompressiblePerfectGas"; eosCoeffs = "pRef \(FoamNum.s(pop));"
        case .boussinesq:
            eos = "Boussinesq"
            eosCoeffs = "rho0 \(FoamNum.s(mat.density)); T0 \(FoamNum.s(s.general.operatingTemperature)); beta \(FoamNum.s(mat.thermalExpansion));"
        case .constant: eos = "rhoConst"; eosCoeffs = "rho \(FoamNum.s(mat.density));"
        }
        if compressible && !psi {
            report.warnings.append("\(app.rawValue) with \(mat.densityMethod.rawValue) density uses heRhoThermo/\(eos).")
        }
        let sutherland = mat.viscosityMethod == .sutherland
        let mu = s.models.viscous == .inviscid && app == .rhoCentralFoam ? 0 : mat.viscosity
        let transport: String
        if sutherland {
            let As = mat.viscosity * (mat.sutherlandT0 + mat.sutherlandS) / pow(mat.sutherlandT0, 1.5)
            transport = "As \(FoamNum.s(As)); Ts \(FoamNum.s(mat.sutherlandS));"
        } else {
            let pr = mat.thermalConductivity > 0 ? mat.viscosity * mat.specificHeat / mat.thermalConductivity : 0.71
            transport = "mu \(FoamNum.s(mu)); Pr \(FoamNum.s(pr));"
        }
        let t = FoamFile.header("dictionary", "thermophysicalProperties", location: "constant") + """
        thermoType
        {
            type            \(psi ? "hePsiThermo" : "heRhoThermo");
            mixture         pureMixture;
            transport       \(sutherland ? "sutherland" : "const");
            thermo          hConst;
            equationOfState \(eos);
            specie          specie;
            energy          \(compressible ? "sensibleInternalEnergy" : "sensibleEnthalpy");
        }

        mixture
        {
            specie          { molWeight \(FoamNum.s(mat.molecularWeight)); }
            equationOfState { \(eosCoeffs) }
            thermodynamics  { Cp \(FoamNum.s(mat.specificHeat)); Hf 0; }
            transport       { \(transport) }
        }

        """
        try put("constant/thermophysicalProperties", t)
    }

    /// thermophysicalProperties from OpenFOAM page › Thermophysical Model (temperature-dependent
    /// properties, real-gas equations of state). Combinations OpenFOAM is not compiled for are refused.
    func writeThermophysicalModel() throws {
        let th = o.thermo
        let (transport, eos) = thermoChoice
        let thermoName = th.thermo.rawValue
        let (transport0, eos0) = (transport, eos)
        let energy = internalEnergy ? "sensibleInternalEnergy" : "sensibleEnthalpy"
        let key = "\(transport0),\(energy),\(thermoName),\(eos0)"
        let psi = compressible && (eos == "perfectGas" || eos == "PengRobinsonGas") && FoamThermoSettings.psiThermoTypes.contains(key)
        guard psi || FoamThermoSettings.rhoThermoTypes.contains(key) else {
            let near = FoamThermoSettings.rhoThermoTypes.filter { $0.hasSuffix(",\(eos)") && $0.contains(energy) }.sorted()
            throw SolverError("OpenFOAM has no thermophysical model \(transport) transport + \(thermoName) thermo + \(eos) (\(energy)). "
                              + (near.isEmpty ? "" : "With \(eos) it has: " + near.map { $0.replacingOccurrences(of: ",\(energy),", with: " + ").replacingOccurrences(of: ",\(eos)", with: "") }.joined(separator: "; ") + "."))
        }
        func poly(_ c: [Double]) -> String { "(" + (0..<8).map { FoamNum.s($0 < c.count ? c[$0] : 0) }.joined(separator: " ") + ")" }
        func list(_ c: [Double]) -> String { "(" + c.map(FoamNum.s).joined(separator: " ") + ")" }
        let eosCoeffs: String
        switch eos {
        case "incompressiblePerfectGas": eosCoeffs = "pRef \(FoamNum.s(pop));"
        case "Boussinesq": eosCoeffs = "rho0 \(FoamNum.s(mat.density)); T0 \(FoamNum.s(s.general.operatingTemperature)); beta \(FoamNum.s(mat.thermalExpansion));"
        case "rhoConst": eosCoeffs = "rho \(FoamNum.s(mat.density));"
        case "perfectFluid": eosCoeffs = "R \(FoamNum.s(th.perfectFluidR)); rho0 \(FoamNum.s(th.perfectFluidRho0));"
        case "PengRobinsonGas": eosCoeffs = "Tc \(FoamNum.s(th.criticalTemperature)); Vc \(FoamNum.s(th.criticalVolume)); Pc \(FoamNum.s(th.criticalPressure)); omega \(FoamNum.s(th.acentricFactor));"
        case "icoPolynomial": eosCoeffs = "rhoCoeffs<8> \(poly(th.rhoCoeffs));"
        default: eosCoeffs = ""
        }
        let thermoCoeffs: String
        switch th.thermo {
        case .hConst: thermoCoeffs = "Cp \(FoamNum.s(mat.specificHeat)); Hf 0;"
        case .janaf:
            guard th.highCpCoeffs.count == 7, th.lowCpCoeffs.count == 7 else { throw SolverError("JANAF thermo needs 7 high- and 7 low-temperature coefficients.") }
            thermoCoeffs = "Tlow \(FoamNum.s(th.janafTlow)); Thigh \(FoamNum.s(th.janafThigh)); Tcommon \(FoamNum.s(th.janafTcommon)); highCpCoeffs \(list(th.highCpCoeffs)); lowCpCoeffs \(list(th.lowCpCoeffs));"
        case .hPolynomial: thermoCoeffs = "Hf \(FoamNum.s(th.formationEnthalpy)); Sf \(FoamNum.s(th.formationEntropy)); CpCoeffs<8> \(poly(th.cpCoeffs));"
        }
        let transportCoeffs: String
        switch transport {
        case "sutherland":
            let As = mat.viscosity * (mat.sutherlandT0 + mat.sutherlandS) / pow(mat.sutherlandT0, 1.5)
            transportCoeffs = "As \(FoamNum.s(As)); Ts \(FoamNum.s(mat.sutherlandS));"
        case "polynomial": transportCoeffs = "muCoeffs<8> \(poly(th.muCoeffs)); kappaCoeffs<8> \(poly(th.kappaCoeffs));"
        default:
            let pr = mat.thermalConductivity > 0 ? mat.viscosity * mat.specificHeat / mat.thermalConductivity : 0.71
            transportCoeffs = "mu \(FoamNum.s(mat.viscosity)); Pr \(FoamNum.s(pr));"
        }
        let t = FoamFile.header("dictionary", "thermophysicalProperties", location: "constant") + """
        thermoType
        {
            type            \(psi ? "hePsiThermo" : "heRhoThermo");
            mixture         pureMixture;
            transport       \(transport);
            thermo          \(thermoName);
            equationOfState \(eos);
            specie          specie;
            energy          \(energy);
        }

        mixture
        {
            specie          { molWeight \(FoamNum.s(mat.molecularWeight)); }
            equationOfState { \(eosCoeffs) }
            thermodynamics  { \(thermoCoeffs) }
            transport       { \(transportCoeffs) }
        }

        """
        try put("constant/thermophysicalProperties", t)
    }

    // MARK: system/

    var energyField: String? { boussinesq ? "T" : (thermal ? (internalEnergy ? "e" : "h") : nil) }

    /// The resolved OpenFOAM thermophysical choice: (transport, equation of state).
    var thermoChoice: (transport: String, eos: String) {
        let th = o.thermo
        let transport = th.transport == .automatic ? (mat.viscosityMethod == .sutherland ? "sutherland" : "const") : th.transport.rawValue
        if th.equationOfState != .automatic { return (transport, th.equationOfState.rawValue) }
        switch mat.densityMethod {
        case .idealGas: return (transport, "perfectGas")
        case .incompressibleIdealGas: return (transport, "incompressiblePerfectGas")
        case .boussinesq: return (transport, "Boussinesq")
        case .constant: return (transport, "rhoConst")
        }
    }

    /// Energy variable of thermophysical solvers: compressible solvers use internal energy, the
    /// rest enthalpy, unless OpenFOAM has the chosen thermophysical model only in the other form.
    var internalEnergy: Bool {
        guard thermal, !o.thermo.isAutomatic else { return compressible }
        let (tr, eos) = thermoChoice
        func has(_ e: String) -> Bool {
            let k = "\(tr),\(e),\(o.thermo.thermo.rawValue),\(eos)"
            return FoamThermoSettings.rhoThermoTypes.contains(k) || FoamThermoSettings.psiThermoTypes.contains(k)
        }
        if compressible { return has("sensibleInternalEnergy") || !has("sensibleEnthalpy") }
        return !has("sensibleEnthalpy") && has("sensibleInternalEnergy")
    }
    var turbulenceFieldNames: [String] { turb.family == .laminar ? [] : turb.fields }
    var scalarNames: [String] { s.models.passiveScalars.map { MeshWriters.foamName($0.name) } }

    func conv(_ c: ConvectionScheme, field: String, vector: Bool = false) -> String {
        let steady = !app.isTransient
        let b = steady ? "bounded " : ""
        switch c {
        case .firstOrderUpwind: return b + "Gauss upwind"
        case .secondOrderUpwind: return b + "Gauss linearUpwind grad(\(field))"
        case .central: return b + "Gauss linear"
        case .boundedCentral: return b + (vector ? "Gauss limitedLinearV 1" : "Gauss limitedLinear 1")
        case .quick: return b + (vector ? "Gauss QUICKV" : "Gauss QUICK")
        case .muscl: return b + "Gauss MUSCL"
        }
    }

    /// Worst face non-orthogonality [°], computed once.
    lazy var maxNonOrthogonality: Double = MeshQuality.report(m).maxNonOrthogonality

    /// Limiter on the explicit non-orthogonal correction. Tetrahedral meshes routinely reach
    /// 60–70°, where the full correction makes SIMPLE diverge after a few hundred iterations.
    var nonOrthoLimiter: Double? {
        if let l = s.methods.nonOrthogonalLimit { return l >= 1 ? nil : l }
        if maxNonOrthogonality > 80 { return 0.33 }
        if maxNonOrthogonality > 60 { return 0.5 }
        return nil
    }

    /// Non-orthogonal correctors: the user's, at least one on strongly non-orthogonal meshes.
    var nonOrthogonalCorrectors: Int {
        if let n = o.nNonOrthogonalCorrectors { return n }
        return max(s.methods.nonOrthogonalCorrectors, maxNonOrthogonality > 60 ? 1 : 0)
    }

    func writeSystem() throws {
        let sc = o.schemes
        let transient = app.isTransient
        let ddt = !sc.ddt.isEmpty ? sc.ddt : (!transient ? "steadyState" : (app == .rhoCentralFoam || s.methods.transient == .firstOrderImplicit ? "Euler" : "backward"))
        // OpenFOAM's least-squares gradient is ill-conditioned in near-wall tetrahedra with two
        // boundary faces (checkMesh "cells with small determinant"), where it seeds a slowly
        // growing instability; Green-Gauss is used on meshes with tetrahedra.
        let tetMesh = (m.cellShapeHistogram()["tetrahedra"] ?? 0) > 0
        let gradBase = s.methods.gradient == .leastSquares && !tetMesh ? "leastSquares" : "Gauss linear"
        let grad = sc.grad.isEmpty ? gradBase : sc.grad
        let gradU = !sc.gradU.isEmpty ? sc.gradU : (s.methods.limitMomentum ? "cellLimited \(gradBase) 1" : gradBase)
        let lim = nonOrthoLimiter
        let lap = !sc.laplacian.isEmpty ? sc.laplacian : (lim.map { "Gauss linear limited corrected \(FoamNum.s($0))" } ?? "Gauss linear corrected")
        let sn = !sc.snGrad.isEmpty ? sc.snGrad : (lim.map { "limited corrected \(FoamNum.s($0))" } ?? "corrected")
        let interp = sc.interpolation.isEmpty ? "linear" : sc.interpolation
        let divU = !sc.divU.isEmpty ? sc.divU : conv(s.methods.momentum, field: "U", vector: true)
        var div = "    default         Gauss linear;\n    div(phi,U)      \(divU);\n"
        for f in turbulenceFieldNames {
            div += "    div(phi,\(f))".padding(toLength: 20, withPad: " ", startingAt: 0) + (sc.divTurbulence.isEmpty ? conv(s.methods.turbulence, field: f) : sc.divTurbulence) + ";\n"
        }
        if let e = energyField {
            div += "    div(phi,\(e))".padding(toLength: 20, withPad: " ", startingAt: 0) + (sc.divEnergy.isEmpty ? conv(s.methods.energy, field: e) : sc.divEnergy) + ";\n"
        }
        if boussinesq {
            div += "    div((nuEff*dev2(T(grad(U))))) Gauss linear;\n"
        } else if thermal {
            div += "    div(phi,K)          \(transient ? "Gauss linear" : "bounded Gauss linear");\n"
            if radiating && o.radiation.model == .fvDOM { div += "    div(Ji,Ii_h)        bounded Gauss upwind;\n" }
            div += "    div(phi,Ekp)        \(transient ? "Gauss linear" : "bounded Gauss linear");\n"
            div += "    div(phid,p)         Gauss upwind;\n"
            div += "    div(((rho*nuEff)*dev2(T(grad(U))))) Gauss linear;\n"
        } else {
            div += "    div((nuEff*dev2(T(grad(U))))) Gauss linear;\n"
        }
        if o.postProcessing.functions.contains("age") { div += "    div(phi,age)    bounded Gauss upwind;\n" }
        for n in scalarNames {
            div += "    div(phi,\(n))".padding(toLength: 20, withPad: " ", startingAt: 0) + (sc.divScalars.isEmpty ? conv(s.methods.scalars, field: n) : sc.divScalars) + ";\n"
        }
        // On tetrahedral meshes, scalars convected with linearUpwind get a cell-limited gradient:
        // unlimited, it extrapolates face values past the neighbouring extrema and the energy
        // equation runs away. Hex meshes keep the unlimited (more accurate) gradient.
        var gradLines = "    default         \(grad);\n    grad(U)         \(gradU);\n"
        if sc.grad.isEmpty && tetMesh {
            var limited = Set<String>()
            for f in turbulenceFieldNames + (energyField.map { [$0] } ?? []) + scalarNames
            where div.contains("linearUpwind grad(\(f))") && !limited.contains(f) {
                limited.insert(f)
                gradLines += "    grad(\(f))".padding(toLength: 20, withPad: " ", startingAt: 0) + "cellLimited \(gradBase) 1;\n"
            }
        }
        var fvSchemes = FoamFile.header("dictionary", "fvSchemes", location: "system")
        fvSchemes += """
        ddtSchemes
        {
            default         \(ddt);
        }

        gradSchemes
        {
        \(gradLines)}

        divSchemes
        {
        \(div)}

        laplacianSchemes
        {
            default         \(lap);
        }

        interpolationSchemes
        {
            default         \(interp);

        """
        if app == .rhoCentralFoam {
            fvSchemes += "    reconstruct(rho) vanLeer;\n    reconstruct(U)  vanLeerV;\n    reconstruct(T)  vanLeer;\n"
        }
        fvSchemes += """
        }

        snGradSchemes
        {
            default         \(sn);
        }

        wallDist
        {
            method          \(sc.wallDistance.isEmpty ? "meshWave" : sc.wallDistance);
            correctWalls    true;
        }

        """
        if app == .rhoCentralFoam { fvSchemes += "fluxScheme      \(s.methods.flux == .ausm ? "Tadmor" : "Kurganov");\n" }
        try put("system/fvSchemes", fvSchemes)
        try writeFvSolution()
        try writeControlDict()
        try writeDecomposeParDict()
    }

    func solverEntry(_ name: String, _ l: FoamLinearSolver, final: Bool = false) -> String {
        var t = "    \(name)\n    {\n        solver          \(l.solver);\n"
        switch l.solver {
        case "GAMG":
            t += "        smoother        \(l.smoother);\n        nCellsInCoarsestLevel \(l.nCellsInCoarsestLevel);\n"
            t += "        nPreSweeps      \(l.nPreSweeps);\n        nPostSweeps     \(l.nPostSweeps);\n        mergeLevels     \(max(1, l.mergeLevels));\n        cacheAgglomeration \(l.cacheAgglomeration ? "true" : "false");\n"
        case "smoothSolver":
            t += "        smoother        \(l.smoother);\n        nSweeps         \(max(1, l.nSweeps));\n"
        case "diagonal":
            return "    \(name)\n    {\n        solver          diagonal;\n    }\n"
        default:
            t += "        preconditioner  \(l.preconditioner);\n"
        }
        if l.minIter > 0 { t += "        minIter         \(l.minIter);\n" }
        t += "        tolerance       \(FoamNum.s(l.tolerance));\n        relTol          \(final ? "0" : FoamNum.s(l.relTol));\n        maxIter         \(l.maxIter);\n    }\n"
        return t
    }

    func writeFvSolution() throws {
        let pName = usesPrgh ? "p_rgh" : "p"
        var t = FoamFile.header("dictionary", "fvSolution", location: "system") + "solvers\n{\n"
        if app == .rhoCentralFoam {
            t += "    \"(rho|rhoU|rhoE)\"\n    {\n        solver          diagonal;\n    }\n"
            t += solverEntry("U", o.velocitySolver) + solverEntry("e", o.energySolver)
            for f in turbulenceFieldNames { t += solverEntry(f, o.turbulenceSolver) }
        } else {
            t += solverEntry(pName, o.pressureSolver) + solverEntry("\(pName)Final", o.pressureSolver, final: true)
            if thermal { t += "    \"rho.*\"\n    {\n        solver          diagonal;\n    }\n" }
            if report.runsPotentialFoam { t += solverEntry("Phi", o.pressureSolver) }
            t += solverEntry("U", o.velocitySolver) + solverEntry("UFinal", o.velocitySolver, final: true)
            if o.adaptiveRefinement.enabled && app.isTransient { t += solverEntry("\"pcorr.*\"", o.pressureSolver, final: true) }
            if !turbulenceFieldNames.isEmpty {
                let group = "\"(\(turbulenceFieldNames.joined(separator: "|")))\""
                let groupF = "\"(\(turbulenceFieldNames.joined(separator: "|")))Final\""
                t += solverEntry(group, o.turbulenceSolver) + solverEntry(groupF, o.turbulenceSolver, final: true)
            }
            if let e = energyField { t += solverEntry(e, o.energySolver) + solverEntry("\(e)Final", o.energySolver, final: true) }
            for n in scalarNames { t += solverEntry(n, o.energySolver) + solverEntry("\(n)Final", o.energySolver, final: true) }
            if o.postProcessing.functions.contains("age") { t += solverEntry("age", o.turbulenceSolver, final: true) }
            if radiating {
                if o.radiation.model == .P1 { t += solverEntry("G", FoamLinearSolver(solver: "PCG", preconditioner: "DIC", tolerance: 1e-5, relTol: 0.1)) }
                else { t += "    \"Ii.*\"\n    {\n        solver          GAMG;\n        smoother        symGaussSeidel;\n        tolerance       1e-4;\n        relTol          0;\n        maxIter         5;\n        nPostSweeps     1;\n    }\n" }
            }
        }
        t += "}\n\n"

        let nonOrth = nonOrthogonalCorrectors
        // Only simpleFoam/pimpleFoam/rhoSimpleFoam implement SIMPLEC ("consistent").
        let supportsConsistent = [.simpleFoam, .pimpleFoam, .rhoSimpleFoam, .rhoPimpleFoam].contains(app)
        let wantsSIMPLEC = s.methods.coupling == .simplec
        let consistent = supportsConsistent && (o.consistent ?? wantsSIMPLEC)
        let pRefLevel = (thermal ? pop : 0) + (thermal ? o.pressureReferenceValue : o.pressureReferenceValue / rho)
        let pRefWhere = o.pressureReferencePoint.flatMap { $0.count == 3 ? "    pRefPoint       \(FoamNum.vec($0));\n" : nil } ?? "    pRefCell        0;\n"
        let pRef = hasFixedPressure ? "" : pRefWhere + "    pRefValue       \(FoamNum.s(pRefLevel));\n"
        var resid = ""
        if o.residualP > 0 { resid += "        \(pName) \(FoamNum.s(o.residualP));\n" }
        if o.residualU > 0 { resid += "        U \(FoamNum.s(o.residualU));\n" }
        if o.residualTurbulence > 0, !turbulenceFieldNames.isEmpty { resid += "        \"(\(turbulenceFieldNames.joined(separator: "|")))\" \(FoamNum.s(o.residualTurbulence));\n" }
        if o.residualEnergy > 0, let e = energyField { resid += "        \(e) \(FoamNum.s(o.residualEnergy));\n" }
        switch app {
        case .simpleFoam, .buoyantSimpleFoam, .buoyantBoussinesqSimpleFoam, .rhoSimpleFoam, .chtMultiRegionSimpleFoam:
            t += "SIMPLE\n{\n    nNonOrthogonalCorrectors \(nonOrth);\n    consistent      \(consistent ? "yes" : "no");\n" + pRef
            if app == .rhoSimpleFoam { t += "    transonic       no;\n    pMinFactor      0.1;\n    pMaxFactor      2;\n" }
            t += "    residualControl\n    {\n\(resid)    }\n}\n\n"
        case .pisoFoam, .icoFoam:
            t += "PISO\n{\n    nCorrectors     \(o.nCorrectors);\n    nNonOrthogonalCorrectors \(nonOrth);\n" + pRef + "}\n\n"
        case .potentialFoam:
            break
        case .rhoCentralFoam:
            break
        default:
            t += "PIMPLE\n{\n    momentumPredictor \(o.momentumPredictor ? "yes" : "no");\n    nOuterCorrectors \(o.nOuterCorrectors);\n    nCorrectors     \(o.nCorrectors);\n    nNonOrthogonalCorrectors \(nonOrth);\n    consistent      \(consistent ? "yes" : "no");\n    turbOnFinalIterOnly \(o.turbOnFinalIterOnly ? "yes" : "no");\n" + (o.adaptiveRefinement.enabled ? "    correctPhi      yes;\n" : "") + pRef
            if app == .rhoPimpleFoam { t += "    transonic       no;\n    pMinFactor      0.1;\n    pMaxFactor      2;\n" }
            if o.outerResidual > 0 {
                t += "    outerCorrectorResidualControl\n    {\n        U { tolerance \(FoamNum.s(o.outerResidual)); relTol 0; }\n        \(pName) { tolerance \(FoamNum.s(o.outerResidual)); relTol 0; }\n    }\n"
            }
            t += "}\n\n"
        }
        if report.runsPotentialFoam || app == .potentialFoam {
            t += "potentialFlow\n{\n    nNonOrthogonalCorrectors \(max(nonOrth, 3));\n" + pRef + "}\n\n"
        }

        // Relaxation: steady apps use the Controls page (or overrides); transient apps only
        // relax inside outer iterations and never on the final one.
        let urf = s.controls.urf
        // SIMPLEC requested where only SIMPLE exists: OpenFOAM's buoyant-tutorial factors.
        let simplecFallback = wantsSIMPLEC && !supportsConsistent
        let relaxP = o.relaxationP ?? (consistent ? 1.0 : (simplecFallback ? 0.7 : urf.pressure))
        let relaxU = o.relaxationU ?? (consistent ? max(urf.momentum, 0.9) : (simplecFallback ? 0.3 : urf.momentum))
        let relaxT = o.relaxationTurbulence ?? urf.turbulentKineticEnergy
        // steady thermophysical solvers need the energy equation relaxed (OpenFOAM tutorials: 0.3-0.7)
        let relaxE = o.relaxationEnergy ?? (simplecFallback ? min(urf.energy, 0.5) : (thermal && !app.isTransient ? min(urf.energy, 0.7) : urf.energy))
        if !app.isTransient && app != .potentialFoam {
            t += "relaxationFactors\n{\n    fields\n    {\n        \(pName) \(FoamNum.s(relaxP));\n\(thermal ? "        rho 1;\n" : "")    }\n    equations\n    {\n        U               \(FoamNum.s(relaxU));\n"
            if !turbulenceFieldNames.isEmpty { t += "        \"(\(turbulenceFieldNames.joined(separator: "|")))\" \(FoamNum.s(relaxT));\n" }
            if let e = energyField { t += "        \(e) \(FoamNum.s(relaxE));\n" }
            for n in scalarNames { t += "        \(n) \(FoamNum.s(urf.scalars));\n" }
            t += "    }\n}\n"
        } else if app.isTransient && o.nOuterCorrectors > 1 {
            t += "relaxationFactors\n{\n    fields\n    {\n        \(pName) \(FoamNum.s(relaxP));\n        \"\(pName)Final\" 1;\n    }\n    equations\n    {\n        \".*\" \(FoamNum.s(relaxU));\n        \".*Final\" 1;\n    }\n}\n"
        }
        try put("system/fvSolution", t)
    }

    // MARK: controlDict

    var reportFunctions: String {
        get {
            var t = ""
            let walls = patches.filter { $0.kind == .wall }.map(\.name)
            func patchList(_ zones: [String]) -> String {
                let names = zones.isEmpty ? walls : zones.map(MeshWriters.foamName)
                return "(" + names.joined(separator: " ") + ")"
            }
            let rhoEntry = thermal ? "rho             rho;\n        rhoInf          \(FoamNum.s(s.reference.density));" : "rho             rhoInf;\n        rhoInf          \(FoamNum.s(rho));"
            let ref = s.reference
            for r in s.reports {
                let obj = MeshWriters.foamName(r.name)
                let dir = r.direction.count == 3 ? normalized(Vec3(r.direction[0], r.direction[1], r.direction[2])) : Vec3(1, 0, 0)
                let cofr = r.momentCentre.count == 3 ? Vec3(r.momentCentre[0], r.momentCentre[1], r.momentCentre[2]) : .zero
                switch r.kind {
                case .dragCoefficient, .liftCoefficient, .momentCoefficient:
                    // Orthonormal drag/lift/pitch frame containing the report direction.
                    var drag = Vec3(1, 0, 0), lift = Vec3(0, 1, 0)
                    switch r.kind {
                    case .dragCoefficient:
                        drag = dir
                        lift = abs(dir.y) < 0.9 ? normalized(Vec3(0, 1, 0) - dot(Vec3(0, 1, 0), dir) * dir) : normalized(Vec3(0, 0, 1) - dot(Vec3(0, 0, 1), dir) * dir)
                    case .liftCoefficient:
                        lift = dir
                        drag = abs(dir.x) < 0.9 ? normalized(Vec3(1, 0, 0) - dot(Vec3(1, 0, 0), dir) * dir) : normalized(Vec3(0, 0, 1) - dot(Vec3(0, 0, 1), dir) * dir)
                    default:
                        let pitch = dir
                        drag = abs(pitch.x) < 0.9 ? normalized(Vec3(1, 0, 0) - dot(Vec3(1, 0, 0), pitch) * pitch) : normalized(Vec3(0, 1, 0) - dot(Vec3(0, 1, 0), pitch) * pitch)
                        lift = normalized(cross(pitch, drag))
                    }
                    let pitch = normalized(cross(drag, lift))
                    t += """
                        \(obj)
                        {
                            type            forceCoeffs;
                            libs            (forces);
                            writeControl    timeStep;
                            writeInterval   1;
                            log             true;
                            patches         \(patchList(r.zones));
                            \(rhoEntry)
                            CofR            \(FoamNum.vec(cofr));
                            dragDir         \(FoamNum.vec(drag));
                            liftDir         \(FoamNum.vec(lift));
                            pitchAxis       \(FoamNum.vec(pitch));
                            magUInf         \(FoamNum.s(ref.velocity));
                            lRef            \(FoamNum.s(ref.length));
                            Aref            \(FoamNum.s(ref.area));
                        }

                    """
                    // Curlew normalises with the reference density; kinematic cases come out per unit density.
                    let scale = thermal ? 1 : rho / max(ref.density, 1e-300)
                    let q = r.kind == .dragCoefficient ? "Cd" : (r.kind == .liftCoefficient ? "Cl" : "CmPitch")
                    report.liveReports.append(FoamLiveReport(report: r.name, key: "\(obj)/\(q)", direction: nil, scale: scale, offset: 0))
                case .force:
                    t += """
                        \(obj)
                        {
                            type            forces;
                            libs            (forces);
                            writeControl    timeStep;
                            writeInterval   1;
                            log             true;
                            patches         \(patchList(r.zones));
                            \(rhoEntry)
                            CofR            \(FoamNum.vec(cofr));
                        }

                    """
                    report.liveReports.append(FoamLiveReport(report: r.name, key: "\(obj)/force", direction: dir, scale: 1, offset: 0))
                case .areaWeightedAverage, .integral, .massWeightedAverage, .massFlowRate:
                    guard r.zones.count == 1, let (fname, comp, scale, offset) = foamField(r.kind == .massFlowRate ? "mass-flow" : r.field) else { continue }
                    let op: String
                    switch r.kind {
                    case .areaWeightedAverage: op = "areaAverage"
                    case .integral: op = "areaIntegrate"
                    case .massWeightedAverage: op = "weightedAverage"
                    default: op = "sum"
                    }
                    t += """
                        \(obj)
                        {
                            type            surfaceFieldValue;
                            libs            (fieldFunctionObjects);
                            writeControl    timeStep;
                            writeInterval   1;
                            log             true;
                            writeFields     false;
                            regionType      patch;
                            name            \(MeshWriters.foamName(r.zones[0]));
                            operation       \(op);
                    \(op == "weightedAverage" ? "        weightField     phi;\n" : "")        fields          (\(fname));
                        }

                    """
                    let area = r.kind == .integral ? m.boundaryZones.first { $0.name == r.zones[0] }.map { z in z.faceRange.reduce(0.0) { $0 + m.faceAreaMag[$1] } } ?? 0 : 1
                    report.liveReports.append(FoamLiveReport(report: r.name, key: "\(obj)/\(op)(\(fname))", direction: comp,
                                                             scale: scale, offset: offset * (r.kind == .integral ? area : 1)))
                case .volumeAverage, .volumeMaximum, .volumeMinimum:
                    guard r.zones.count <= 1, let (fname, comp, scale, offset) = foamField(r.field), comp == nil else { continue }
                    let op = r.kind == .volumeAverage ? "volAverage" : (r.kind == .volumeMaximum ? "max" : "min")
                    let region = r.zones.isEmpty ? "        regionType      all;\n" : "        regionType      cellZone;\n        name            \(MeshWriters.foamName(r.zones[0]));\n"
                    t += """
                        \(obj)
                        {
                            type            volFieldValue;
                            libs            (fieldFunctionObjects);
                            writeControl    timeStep;
                            writeInterval   1;
                            log             true;
                            writeFields     false;
                    \(region)        operation       \(op);
                            fields          (\(fname));
                        }

                    """
                    report.liveReports.append(FoamLiveReport(report: r.name, key: "\(obj)/\(op)(\(fname))", direction: nil, scale: scale, offset: offset))
                default:
                    continue
                }
            }
            return t
        }
    }

    /// Curlew field name → (OpenFOAM field, vector component direction, scale, offset) so that
    /// Curlew value = scale * foam + offset.
    func foamField(_ f: String) -> (String, Vec3?, Double, Double)? {
        switch f {
        case "pressure", "static-pressure": return ("p", nil, thermal ? 1 : rho, thermal ? -pop : 0)
        case "mass-flow": return ("phi", nil, thermal ? 1 : rho, 0)
        case "temperature", "static-temperature": return solvesT ? ("T", nil, 1, 0) : nil
        case "turbulent-kinetic-energy", "k": return turbulenceFieldNames.contains("k") ? ("k", nil, 1, 0) : nil
        case "specific-dissipation-rate", "omega": return turbulenceFieldNames.contains("omega") ? ("omega", nil, 1, 0) : nil
        case "turbulent-dissipation-rate", "epsilon": return turbulenceFieldNames.contains("epsilon") ? ("epsilon", nil, 1, 0) : nil
        case "x-velocity": return ("U", Vec3(1, 0, 0), 1, 0)
        case "y-velocity": return ("U", Vec3(0, 1, 0), 1, 0)
        case "z-velocity": return ("U", Vec3(0, 0, 1), 1, 0)
        default: return nil
        }
    }

    func writeControlDict() throws {
        let transient = app.isTransient
        let r = s.run
        // A steady setup on a transient application (density-based → rhoCentralFoam, or a
        // user choice) runs the iteration count as pseudo-time steps.
        let pseudoSteady = transient && s.general.time == .steady
        let central = app == .rhoCentralFoam
        // rhoCentralFoam is explicit: it always runs at a Courant limit (Curlew's density-based CFL).
        let adjustable = transient && (o.adjustTimeStep || central)
        let maxCo = central && !o.adjustTimeStep ? min(s.methods.courantNumber, 0.2) : o.maxCo
        var dt = o.deltaT ?? (transient ? r.timeStepSize : 1)
        if central && o.deltaT == nil {
            // Explicit solver: the first step already has to respect the acoustic CFL limit.
            var hmin = Double.infinity
            for c in 0..<m.nCells {
                var amax = 0.0
                for k in m.cellFaceRange(c) { amax = max(amax, m.faceAreaMag[Int(m.cellFaces[k])]) }
                if amax > 0 { hmin = min(hmin, m.cellVolumes[c] / amax) }
            }
            let gamma = mat.specificHeat / max(mat.specificHeat - mat.gasConstant, 1e-12)
            let Tmax = initial?.T.max() ?? (s.initialization.temperature.constantValue ?? 300)
            let umax = initial?.u.map { norm($0) }.max() ?? norm(initialVelocity)
            let wave = umax + sqrt(gamma * mat.gasConstant * max(Tmax, 1))
            if hmin.isFinite && wave > 0 { dt = pseudoSteady ? maxCo * hmin / wave : min(dt, maxCo * hmin / wave) }
        }
        let span = o.endTime ?? (pseudoSteady ? Double(r.iterations) * dt
                                 : (transient ? Double(r.numberOfTimeSteps) * r.timeStepSize : Double(r.iterations)))
        let endTime = startTime + span
        let steps = transient ? max(1, Int((span / max(dt, 1e-300)).rounded())) : max(1, Int(span.rounded()))
        let every = o.writeInterval > 0 ? o.writeInterval : (r.autosaveInterval > 0 ? r.autosaveInterval : steps)
        let maxDeltaT = central && !o.adjustTimeStep ? (pseudoSteady ? 1.0 : r.timeStepSize) : o.maxDeltaT
        let firstDt = dt
        let walls = patches.filter { $0.kind == .wall }.map(\.name)
        var functions = ""
        if o.wallShearStress && !walls.isEmpty && app.supportsTurbulence {
            functions += """
                wallShearStress
                {
                    type            wallShearStress;
                    libs            (fieldFunctionObjects);
                    patches         (\(walls.joined(separator: " ")));
                    writeControl    writeTime;
                    log             false;
                }

            """
        }
        if o.yPlus && !walls.isEmpty && turb.family != .laminar {
            functions += """
                yPlus
                {
                    type            yPlus;
                    libs            (fieldFunctionObjects);
                    writeControl    writeTime;
                }

            """
        }
        if o.fieldMinMax {
            functions += """
                minMax
                {
                    type            fieldMinMax;
                    libs            (fieldFunctionObjects);
                    fields          (U \(usesPrgh ? "p_rgh" : "p")\(solvesT ? " T" : ""));
                    writeControl    timeStep;
                    writeInterval   1;
                    log             true;
                }

            """
        }
        if o.vorticity {
            functions += "    vorticity\n    {\n        type            vorticity;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n    }\n\n"
        }
        if o.qCriterion {
            functions += "    Q\n    {\n        type            Q;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n    }\n\n"
        }
        if !o.probes.isEmpty {
            let pts = o.probes.filter { $0.count == 3 }.map { FoamNum.vec($0) }.joined(separator: "\n            ")
            functions += """
                probes
                {
                    type            probes;
                    libs            (sampling);
                    writeControl    timeStep;
                    writeInterval   1;
                    fields          (U \(usesPrgh ? "p_rgh" : "p")\(solvesT ? " T" : ""));
                    probeLocations
                    (
                        \(pts)
                    );
                }

            """
        }
        let fa = o.fieldAverage
        if transient && (fa.enabled ?? r.dataSampling) {
            let names = fa.fields.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Writer.word(String($0)) }
            let win = fa.window > 0 ? " window \(FoamNum.s(fa.window));" : ""
            let entries = (names.isEmpty ? ["U", "p"] : names).map { "            \($0) { mean on; prime2Mean \(fa.prime2Mean ? "on" : "off"); base time;\(win) }" }
            functions += """
                fieldAverage
                {
                    type            fieldAverage;
                    libs            (fieldFunctionObjects);
                    writeControl    writeTime;
            \(fa.startTime > 0 ? "        timeStart       \(FoamNum.s(fa.startTime));\n" : "")\
                    fields
                    (
            \(entries.joined(separator: "\n"))
                    );
                }

            """
        }
        functions += runtimeExpressionFunctions
        if o.postProcessing.functions.contains("age") {
            // age solves a transport equation on the flux, which exists only while the solver runs
            functions += "    age\n    {\n        type            age;\n        libs            (fieldFunctionObjects);\n        executeControl  writeTime;\n        writeControl    writeTime;\n    }\n\n"
        }
        for (i, sc) in s.models.passiveScalars.enumerated() {
            let name = MeshWriters.foamName(sc.name)
            let alphaD = sc.diffusivity / max(nu, 1e-300)
            functions += """
                scalarTransport_\(i)
                {
                    type            scalarTransport;
                    libs            (solverFunctionObjects);
                    field           \(name);
                    alphaD          \(FoamNum.s(alphaD));
                    alphaDt         \(FoamNum.s(1 / max(sc.turbulentSchmidt, 1e-12)));
                    resetOnStartUp  false;
                    \(thermal ? "phi             phi;\n        rho             rho;" : "")
                    writeControl    writeTime;
                }

            """
        }
        functions += reportFunctions
        functions += extraFunctionObjects(transient: transient)
        if !o.customFunctions.isEmpty { functions += o.customFunctions + "\n" }

        var t = FoamFile.header("dictionary", "controlDict", location: "system")
        t += """
        application     \(app.rawValue);

        startFrom       \(o.startFrom == "startTime" ? "startTime" : "latestTime");
        startTime       \(FoamNum.time(startTime));
        stopAt          \(["endTime", "writeNow", "noWriteNow", "nextWrite"].contains(o.stopAt) ? o.stopAt : "endTime");
        endTime         \(FoamNum.time(endTime));
        deltaT          \(FoamNum.s(firstDt));

        writeControl    \(writeControlName(adjustable: adjustable));
        writeInterval   \(writeIntervalText(adjustable: adjustable, every: every, dt: dt));
        purgeWrite      \(o.purgeWrite);
        writeFormat     \(o.writeFormat == "ascii" ? "ascii" : "binary");
        writePrecision  \(o.writePrecision);
        writeCompression \(o.writeCompression ? "on" : "off");
        timeFormat      general;
        timePrecision   \(max(6, o.timePrecision));
        runTimeModifiable \(o.runTimeModifiable ? "true" : "false");

        """
        if transient {
            t += "adjustTimeStep  \(adjustable ? "yes" : "no");\nmaxCo           \(FoamNum.s(maxCo));\nmaxDeltaT       \(FoamNum.s(maxDeltaT));\n\n"
        }
        if let r = region {
            // function objects of a multi-region case name their region
            functions = functions.replacingOccurrences(of: "\n        type            ", with: "\n        region          \(r);\n        type            ")
            functions += extraFunctions
        }
        t += "functions\n{\n" + functions + "}\n"
        try put("system/controlDict", t)
    }

    /// exprField function objects evaluated while solving (expression fields marked "during run",
    /// and the indicator of adaptive refinement when it is an expression).
    var runtimeExpressionFunctions: String {
        var list = o.postProcessing.expressionFields.filter { $0.duringRun && $0.isSafe }
        if o.adaptiveRefinement.enabled && o.adaptiveRefinement.isExpression && app.isTransient {
            list.insert(FoamExpressionField(name: "refinementIndicator", expression: o.adaptiveRefinement.field), at: 0)
        }
        return list.compactMap { e -> String? in
            guard let n = Writer.word(e.name) else { return nil }
            let indicator = n == "refinementIndicator"
            return "    \(n)\n    {\n        type            exprField;\n        libs            (fieldFunctionObjects);\n        field           \(n);\n        expression      \"\(e.expression)\";\n        action          new;\n        autowrite       \(indicator ? "false" : "true");\n        store           true;\n        executeControl  timeStep;\n        writeControl    \(indicator ? "none" : "writeTime");\n    }\n\n"
        }.joined()
    }

    func writeControlName(adjustable: Bool) -> String {
        switch o.writeControl {
        case .automatic: return adjustable ? "adjustable" : "timeStep"
        default: return o.writeControl.rawValue
        }
    }
    func writeIntervalText(adjustable: Bool, every: Int, dt: Double) -> String {
        switch o.writeControl {
        case .automatic: return adjustable ? FoamNum.s(Double(every) * dt) : "\(every)"
        case .timeStep: return "\(every)"
        default: return FoamNum.s(max(o.writeEvery, 1e-12))
        }
    }

    /// Optional function objects from the OpenFOAM page.
    func extraFunctionObjects(transient: Bool) -> String {
        var f = ""
        func fo(_ name: String, _ body: String) { f += "    \(name)\n    {\n\(body)    }\n\n" }
        let pName = usesPrgh ? "p_rgh" : "p"
        if o.courantNumber { fo("CourantNo", "        type            CourantNo;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n") }
        if o.machNumber && thermal { fo("MachNo", "        type            MachNo;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n") }
        if o.pressureCoefficient {
            let U = max(s.reference.velocity, 1e-12)
            fo("pressureCoefficient", """
                    type            pressure;
                    libs            (fieldFunctionObjects);
                    mode            staticCoeff;
                    result          Cp;
                    \(thermal ? "" : "rho             rhoInf;\n        rhoInf          \(FoamNum.s(1.0));\n")\
                    pInf            0;
                    UInf            (\(FoamNum.s(U)) 0 0);
                    writeControl    writeTime;

            """)
        }
        if o.wallHeatFlux && thermal { fo("wallHeatFlux", "        type            wallHeatFlux;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n") }
        if o.turbulenceFields && turb.family != .laminar {
            fo("turbulenceFields", "        type            turbulenceFields;\n        libs            (fieldFunctionObjects);\n        fields          (k epsilon omega nut R);\n        writeControl    writeTime;\n")
        }
        if o.lambda2 { fo("Lambda2", "        type            Lambda2;\n        libs            (fieldFunctionObjects);\n        writeControl    writeTime;\n") }
        if o.residualsFile {
            fo("solverResiduals", "        type            solverInfo;\n        libs            (utilityFunctionObjects);\n        fields          (U \(pName)\(energyField.map { " " + $0 } ?? "")\(turbulenceFieldNames.isEmpty ? "" : " " + turbulenceFieldNames.joined(separator: " ")));\n        writeResidualFields no;\n        writeControl    timeStep;\n")
        }
        let planes = o.cuttingPlanes.filter { $0.point.count == 3 && $0.normal.count == 3 && !$0.name.isEmpty }
        if !planes.isEmpty {
            var surf = ""
            for pl in planes {
                let n = MeshWriters.foamName(pl.name)
                surf += "            \(n)\n            {\n                type            cuttingPlane;\n                planeType       pointAndNormal;\n                pointAndNormalDict { point \(FoamNum.vec(pl.point)); normal \(FoamNum.vec(pl.normal)); }\n                interpolate     true;\n            }\n"
            }
            fo("cuttingPlanes", """
                    type            surfaces;
                    libs            (sampling);
                    writeControl    writeTime;
                    surfaceFormat   vtk;
                    fields          (U \(pName)\(solvesT ? " T" : ""));
                    interpolationScheme cellPoint;
                    surfaces
                    {
            \(surf)        }

            """)
        }
        if !o.runTimeStopReport.isEmpty, let live = report.liveReports.first(where: { $0.report == o.runTimeStopReport }),
           let slash = live.key.firstIndex(of: "/") {
            let obj = String(live.key[..<slash]), field = String(live.key[live.key.index(after: slash)...])
            fo("runTimeStop", """
                    type            runTimeControl;
                    libs            (utilityFunctionObjects);
                    conditions
                    {
                        reportStable
                        {
                            type            average;
                            functionObject  \(obj);
                            fields          (\(field));
                            tolerance       \(FoamNum.s(o.runTimeStopTolerance));
                            window          \(max(2, o.runTimeStopWindow));
                            windowType      exact;
                        }
                    }

            """)
        }
        return f
    }

    func writeDecomposeParDict() throws {
        let n = max(1, o.cores)
        let bb = MeshQuality.report(m).bounds
        var split = Self.factor(n, size: bb.max - bb.min)
        if let d = o.decompositionSplit, d.count == 3, d.allSatisfy({ $0 > 0 }) {
            if d[0] * d[1] * d[2] == n { split = (d[0], d[1], d[2]) }
            else { report.warnings.append("Decomposition \(d[0])×\(d[1])×\(d[2]) ≠ \(n) cores; split chosen automatically.") }
        }
        let order = ["xyz", "xzy", "yxz", "yzx", "zxy", "zyx"].contains(o.decompositionOrder) ? o.decompositionOrder : "xyz"
        var t = FoamFile.header("dictionary", "decomposeParDict", location: "system")
        t += "numberOfSubdomains \(n);\n\nmethod          \(o.decomposition);\n\n"
        t += "coeffs\n{\n    n               (\(split.0) \(split.1) \(split.2));\n    order           \(order);\n    delta           0.001;\n}\n"
        try put("system/decomposeParDict", t)
    }

    /// Split `n` subdomains over three axes, longest first.
    static func factor(_ n: Int, size: Vec3) -> (Int, Int, Int) {
        var c = [1, 1, 1]
        var rem = n, f = 2
        while rem > 1 {
            while rem % f != 0 { f += 1 }
            let l = [size.x / Double(c[0]), size.y / Double(c[1]), size.z / Double(c[2])]
            let i = l.firstIndex(of: l.max()!)!
            c[i] *= f
            rem /= f
        }
        return (c[0], c[1], c[2])
    }

    // MARK: Extras

    func writeExtras() throws {
        for (path, text) in o.extraFiles.sorted(by: { $0.key < $1.key }) where !path.isEmpty && !path.contains("..") {
            try put(path, text)
        }
    }

    func writeScripts() throws {
        let cores = max(1, o.cores)
        let solve = cores > 1 ? "runParallel $(getApplication)" : "runApplication $(getApplication)"
        var allrun = """
        #!/bin/sh
        # Generated by Curlew. Source an OpenFOAM environment first.
        cd "${0%/*}" || exit
        . ${WM_PROJECT_DIR:?}/bin/tools/RunFunctions

        """
        if !o.baffles.isEmpty { allrun += "runApplication createBaffles -overwrite\n" }
        if o.checkMesh { allrun += "runApplication checkMesh -constant\(o.preProcessing.fullMeshCheck ? " -allGeometry -allTopology" : "")\n" }
        let pre = o.preProcessing
        if !pre.mapFieldsSource.isEmpty { allrun += "runApplication mapFields \(FoamShell.quote(pre.mapFieldsSource))\(pre.mapFieldsConsistent ? " -consistent" : "") -sourceTime latestTime\n" }
        if !pre.setFieldsRegions.isEmpty { allrun += "runApplication setFields\n" }
        if let y = pre.boundaryLayerThickness { allrun += "runApplication applyBoundaryLayer -ybl \(FoamNum.s(y))\n" }
        if cores > 1 { allrun += "runApplication decomposePar -force\n" }
        if report.runsPotentialFoam { allrun += (cores > 1 ? "runParallel" : "runApplication") + " potentialFoam -writephi\n" }
        // custom stages: OpenFOAM applications only, every word quoted (never shell-interpreted)
        func customLine(_ c: FoamCustomStage) -> String {
            let w = c.words
            guard let app = w.first else { return "" }
            return "( " + FoamShell.requireApplication(app).replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "do;", with: "do") + " ) && runApplication " + w.map(FoamShell.quote).joined(separator: " ") + "\n"
        }
        for c in o.customStages where c.phase == .beforeSolve { allrun += customLine(c) }
        allrun += solve + "\n"
        if cores > 1 { allrun += "runApplication reconstructPar -latestTime\n" }
        for c in o.customStages where c.phase == .afterSolve { allrun += customLine(c) }
        let post = o.postProcessing
        if !post.isEmpty && post.afterSolve {
            if post.runsOpenFOAMFunctions {
                allrun += "runApplication -s post \(app.rawValue) -postProcess -latestTime -dict system/curlewPostProcess\n"
            }
            if post.exportVTK { allrun += "runApplication foamToVTK -latestTime\n" }
            if post.exportEnsight { allrun += "runApplication foamToEnsight -latestTime\n" }
            if post.scripts.contains(where: { $0.afterSolve }) { allrun += "# Python post-processing scripts (curlew-post/) are run by Curlew after the solve.\n" }
        }
        allrun += "touch case.foam\n"
        try put("Allrun", allrun)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Allrun").path)
        let allclean = """
        #!/bin/sh
        cd "${0%/*}" || exit
        . ${WM_PROJECT_DIR:?}/bin/tools/CleanFunctions
        cleanTimeDirectories
        rm -rf processor* log.* postProcessing

        """
        try put("Allclean", allclean)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Allclean").path)
    }
}

// MARK: - Formatting

enum FoamNum {
    static func s(_ v: Double) -> String { String(format: "%.10g", v.isFinite ? v : 0) }
    static func vec(_ v: Vec3) -> String { "(\(s(v.x)) \(s(v.y)) \(s(v.z)))" }
    static func vec(_ a: [Double]) -> String { vec(Vec3(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0)) }
    /// Time directory name the way OpenFOAM's `timeFormat general` prints it.
    static func time(_ t: Double) -> String {
        if t == 0 { return "0" }
        if t == t.rounded() && abs(t) < 1e15 { return String(Int64(t)) }
        return String(format: "%.10g", t)
    }
}

public enum FoamFile {
    public static func header(_ cls: String, _ object: String, location: String) -> String {
        """
        /*--------------------------------*- C++ -*----------------------------------*\\
          Written by Curlew
        \\*---------------------------------------------------------------------------*/
        FoamFile
        {
            version     2.0;
            format      ascii;
            class       \(cls);
            location    "\(location)";
            object      \(object);
        }
        // * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //


        """
    }
}
