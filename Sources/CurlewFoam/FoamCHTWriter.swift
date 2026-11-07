import Foundation
import CurlewMesh
import CurlewSolver

/// Conjugate heat transfer for OpenFOAM: the Curlew mesh is split into one fluid region (all
/// fluid cell zones) and one region per solid cell zone; regions meet at mappedWall patch pairs
/// with `compressible::turbulentTemperatureCoupledBaffleMixed` temperature coupling, which is
/// the layout `splitMeshRegions -cellZones` produces for chtMultiRegion(Simple)Foam.
enum FoamCHTWriter {

    /// Region name of every cell zone of `m`: fluid zones of the same material share a region
    /// (air, water…), each solid zone is its own region.
    static func regionNames(_ m: Mesh, _ s: CaseSetup) throws -> (regionOfZone: [String], fluids: [String], solids: [String]) {
        var used = Set<String>()
        func word(_ n: String) -> String {
            var w = String(n.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if w.isEmpty || w.first!.isNumber { w = "region_" + w }
            var u = w, k = 1
            while used.contains(u) { k += 1; u = "\(w)\(k)" }
            used.insert(u)
            return u
        }
        let isSolid = m.cellZones.map { (s.cellZones[$0.name]?.kind ?? $0.kind) == .solid }
        var fluidOfMaterial: [String: String] = [:]
        var fluids: [String] = [], solids: [String] = []
        let fluidMaterials = Set(m.cellZones.enumerated().filter { !isSolid[$0.offset] }.map { s.cellZones[$0.element.name]?.material ?? "air" })
        let regionOfZone = m.cellZones.enumerated().map { i, z -> String in
            if !isSolid[i] {
                let mat = s.cellZones[z.name]?.material ?? "air"
                if let r = fluidOfMaterial[mat] { return r }
                let r = word(fluidMaterials.count == 1 ? "fluid" : mat)
                fluidOfMaterial[mat] = r; fluids.append(r)
                return r
            }
            let r = word(z.name)
            solids.append(r)
            return r
        }
        return (regionOfZone, fluids, solids)
    }

    static func regionState(_ st: FlowState, _ r: MeshRegion) -> FlowState {
        let out = FlowState(nCells: r.mesh.nCells, nBoundary: r.mesh.nBoundaryFaces, nFaces: r.mesh.nFaces)
        let map = r.cellMap.map(Int.init)
        out.u = map.map { st.u[$0] }; out.p = map.map { st.p[$0] }; out.T = map.map { st.T[$0] }
        out.k = map.map { st.k[$0] }; out.omega = map.map { st.omega[$0] }; out.epsilon = map.map { st.epsilon[$0] }
        out.nuTilda = map.map { st.nuTilda[$0] }; out.muT = map.map { st.muT[$0] }; out.rho = map.map { st.rho[$0] }
        out.scalars = st.scalars.map { a in map.map { a[$0] } }
        return out
    }

    static func mappedPatches(_ r: MeshRegion) -> [String: String] {
        var e: [String: String] = [:]
        for (p, nb) in r.interfaces {
            e[p] = "type            mappedWall;\ninGroups        1(wall);\nsampleMode      nearestPatchFace;\nsampleRegion    \(nb.region);\nsamplePatch     \(nb.patch);"
        }
        return e
    }

    static func write(mesh m: Mesh, setup s: CaseSetup, app: FoamApplication, to dir: URL, initial: FlowState?,
                      writeMesh: Bool, writeFields: Bool, startTime: Double) throws -> FoamCaseReport {
        let (regionOfZone, fluidNames, solidNames) = try regionNames(m, s)
        let regions = try MeshRegions.split(m, regionOfZone: regionOfZone)
        let o = s.openfoam
        let steady = !app.isTransient
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("system"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("constant"), withIntermediateDirectories: true)
        var report = FoamCaseReport(application: app, turbulence: .laminar, cores: max(1, o.cores), runsPotentialFoam: false,
                                    kinematicPressure: false, density: FoamCaseWriter.fluidMaterial(s)?.density ?? 1,
                                    operatingPressure: s.general.operatingPressure)
        report.regions = fluidNames + solidNames
        let timeDir = FoamNum.time(startTime)

        func put(_ path: String, _ text: String) throws {
            var body = text
            if let extra = o.dictionaryAppends[path], !extra.isEmpty { body += "\n// Appended from Curlew (OpenFOAM settings)\n" + extra + "\n" }
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            report.files.append(path)
        }

        // Live reports on solid zones (volume statistics of T) are function objects of that region.
        var solidFunctions = ""
        let zoneRegion = Dictionary(uniqueKeysWithValues: m.cellZones.enumerated().map { ($0.element.name, regionOfZone[$0.offset]) })
        for r in s.reports where [.volumeAverage, .volumeMaximum, .volumeMinimum].contains(r.kind) && r.zones.count == 1 {
            guard let reg = zoneRegion[r.zones[0]], solidNames.contains(reg), r.field == "temperature" || r.field == "static-temperature" else { continue }
            let op = r.kind == .volumeAverage ? "volAverage" : (r.kind == .volumeMaximum ? "max" : "min")
            let obj = MeshWriters.foamName(r.name)
            solidFunctions += """
                \(obj)
                {
                    region          \(reg);
                    type            volFieldValue;
                    libs            (fieldFunctionObjects);
                    writeControl    timeStep;
                    writeInterval   1;
                    log             true;
                    writeFields     false;
                    regionType      all;
                    operation       \(op);
                    fields          (T);
                }

            """
            report.liveReports.append(FoamLiveReport(report: r.name, key: "\(obj)/\(op)(T)", direction: nil, scale: 1, offset: 0))
        }

        // Fluid regions: the single-region writer in region mode (the first one also writes
        // the global controlDict and decomposeParDict; later ones write into their region).
        var wroteControl = false
        for r in regions where fluidNames.contains(r.name) {
            var rs = s
            rs.adopt(mesh: r.mesh)
            let patchNames = Set(r.mesh.boundaryZones.map(\.name)), zoneNames = Set(r.mesh.cellZones.map(\.name))
            rs.reports = s.reports.filter { rep in
                switch rep.kind {
                case .volumeAverage, .volumeMaximum, .volumeMinimum: return rep.zones.allSatisfy { zoneNames.contains($0) }
                default: return rep.zones.allSatisfy { patchNames.contains($0) }
                }
            }
            let w = Writer(mesh: r.mesh, setup: rs, dir: dir, initial: initial.map { regionState($0, r) }, startTime: startTime,
                           region: r.name, interfaces: r.interfaces, app: app)
            w.writesFields = writeFields
            w.extraFunctions = wroteControl ? "" : solidFunctions
            w.writesGlobalFiles = !wroteControl
            wroteControl = true
            try w.prepare()
            if writeMesh {
                var kinds: [String: ZoneKind] = [:]
                for z in r.mesh.boundaryZones { kinds[z.name] = rs.boundaries[z.name]?.type ?? z.kind }
                try MeshWriters.writeFoamPolyMesh(r.mesh, caseDir: dir, kindOverride: kinds, region: r.name, patchEntries: mappedPatches(r))
            }
            try w.writeAll()
            report.turbulence = w.report.turbulence
            report.liveReports = w.report.liveReports + report.liveReports
            report.warnings += w.report.warnings
            report.files += w.report.files
        }

        // Solid regions.
        for r in regions where !fluidNames.contains(r.name) {
            var rs = s
            rs.adopt(mesh: r.mesh)
            if writeMesh {
                try MeshWriters.writeFoamPolyMesh(r.mesh, caseDir: dir, region: r.name, patchEntries: mappedPatches(r))
            }
            try writeSolid(r, setup: rs, dir: dir, timeDir: timeDir, writeFields: writeFields,
                           initialT: initial.map { st in r.cellMap.map { st.T[Int($0)] } }, steady: steady, fluidRegions: fluidNames, put: put)
        }

        // Global files.
        try put("constant/regionProperties", FoamFile.header("dictionary", "regionProperties", location: "constant")
                + "regions\n(\n    fluid       (\(fluidNames.joined(separator: " ")))\n    solid       (\(solidNames.joined(separator: " ")))\n);\n")
        try put("system/fvSchemes", FoamFile.header("dictionary", "fvSchemes", location: "system")
                + "ddtSchemes {}\ngradSchemes {}\ndivSchemes {}\nlaplacianSchemes {}\ninterpolationSchemes {}\nsnGradSchemes {}\n")
        try put("system/fvSolution", FoamFile.header("dictionary", "fvSolution", location: "system")
                + "PIMPLE\n{\n    nOuterCorrectors \(steady ? 1 : max(1, o.nOuterCorrectors));\n}\n")
        if fluidNames.isEmpty {
            // pure conduction: run control without a fluid writer
            let span = o.endTime ?? (steady ? Double(s.run.iterations) : Double(s.run.numberOfTimeSteps) * s.run.timeStepSize)
            let dt = o.deltaT ?? (steady ? 1 : s.run.timeStepSize)
            try put("system/controlDict", FoamFile.header("dictionary", "controlDict", location: "system") + """
            application     \(app.rawValue);
            startFrom       latestTime;
            startTime       \(timeDir);
            stopAt          endTime;
            endTime         \(FoamNum.time(startTime + span));
            deltaT          \(FoamNum.s(dt));
            writeControl    timeStep;
            writeInterval   \(o.writeInterval > 0 ? o.writeInterval : max(1, Int((span / dt).rounded())));
            writeFormat     \(o.writeFormat == "ascii" ? "ascii" : "binary");
            writePrecision  \(o.writePrecision);
            timeFormat      general;
            timePrecision   10;
            runTimeModifiable true;

            functions
            {
            \(solidFunctions)}

            """)
            try put("system/decomposeParDict", FoamFile.header("dictionary", "decomposeParDict", location: "system")
                    + "numberOfSubdomains \(max(1, o.cores));\nmethod          \(o.decomposition);\ncoeffs { n (\(max(1, o.cores)) 1 1); }\n")
        }
        if !fm.fileExists(atPath: dir.appendingPathComponent("constant/g").path) {
            try put("constant/g", FoamFile.header("uniformDimensionedVectorField", "g", location: "constant")
                    + "dimensions      [0 1 -2 0 0 0 0];\nvalue           (0 0 0);\n")
        }
        // decomposePar -allRegions reads each region's own decomposeParDict
        if let dp = try? String(contentsOf: dir.appendingPathComponent("system/decomposeParDict"), encoding: .utf8) {
            for r in report.regions { try put("system/\(r)/decomposeParDict", dp) }
        }
        for (path, text) in o.extraFiles.sorted(by: { $0.key < $1.key }) where !path.isEmpty && !path.contains("..") { try put(path, text) }
        let cores = max(1, o.cores)
        var allrun = """
        #!/bin/sh
        # Generated by Curlew (conjugate heat transfer). Source an OpenFOAM environment first.
        cd "${0%/*}" || exit
        . ${WM_PROJECT_DIR:?}/bin/tools/RunFunctions

        """
        if o.checkMesh { allrun += "for r in \(report.regions.joined(separator: " ")); do runApplication -s $r checkMesh -region $r -constant; done\n" }
        if cores > 1 { allrun += "runApplication decomposePar -allRegions -force\nrunParallel $(getApplication)\nrunApplication reconstructPar -allRegions -latestTime\n" }
        else { allrun += "runApplication $(getApplication)\n" }
        allrun += "touch case.foam\n"
        try put("Allrun", allrun)
        try put("Allclean", "#!/bin/sh\ncd \"${0%/*}\" || exit\n. ${WM_PROJECT_DIR:?}/bin/tools/CleanFunctions\ncleanTimeDirectories\nrm -rf processor* log.* postProcessing\n")
        for f in ["Allrun", "Allclean"] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path) }
        return report
    }

    // MARK: Solid region

    static func writeSolid(_ r: MeshRegion, setup s: CaseSetup, dir: URL, timeDir: String, writeFields: Bool,
                           initialT: [Double]?, steady: Bool, fluidRegions: [String], put: (String, String) throws -> Void) throws {
        let zone = r.mesh.cellZones.first!.name
        let cz = s.cellZones[zone] ?? CellZoneSettings()
        guard let mat = s.material(named: cz.material) else { throw SolverError("solid zone '\(zone)' uses unknown material '\(cz.material)'") }
        let exprs = try Expr.compileNamed(s.expressions.map { ($0.name, $0.definition) })
        let bcd = try BoundaryData(mesh: r.mesh, setup: s, exprs: exprs, time: 0)
        let name = r.name
        let pop = s.general.operatingPressure
        let T0 = s.initialization.temperature.constantValue ?? 300
        let nI = r.mesh.nInternalFaces
        func values(_ z: BoundaryZone, _ f: (Int) -> Double) -> String {
            let v = (0..<z.count).map { f(z.start - nI + $0) }
            if v.allSatisfy({ abs($0 - v[0]) <= 1e-12 * max(1, abs(v[0])) }) { return "uniform \(FoamNum.s(v[0]))" }
            return "nonuniform List<scalar> \(v.count)\n(\n" + v.map(FoamNum.s).joined(separator: "\n") + "\n)"
        }
        // Orthotropic solids: the coupled and external conditions must use the normal component
        // of the conductivity tensor (n·aniAlpha·n). With plain solidThermo they take a scalar
        // conductivity, the interface flux no longer matches the conduction inside the solid,
        // and energy is not conserved (a 100 W cold plate delivered 171 W to the water).
        let km = mat.anisotropicConductivity?.count == 3 ? "directionalSolidThermo;\n        alphaAni        aniAlpha" : "solidThermo"
        if writeFields {
            var t = FoamFile.header("volScalarField", "T", location: "\(timeDir)/\(name)") + "dimensions      [0 0 0 1 0 0 0];\n\n"
            if let iT = initialT, let f = iT.first, !iT.allSatisfy({ $0 == f }) {
                t += "internalField   nonuniform List<scalar> \(iT.count)\n(\n" + iT.map(FoamNum.s).joined(separator: "\n") + "\n)\n;\n\n"
            } else {
                t += "internalField   uniform \(FoamNum.s(initialT?.first ?? T0));\n\n"
            }
            t += "boundaryField\n{\n"
            var p = FoamFile.header("volScalarField", "p", location: "\(timeDir)/\(name)")
                + "dimensions      [1 -1 -2 0 0 0 0];\n\ninternalField   uniform \(FoamNum.s(pop));\n\nboundaryField\n{\n"
            for z in r.mesh.boundaryZones {
                let b = s.boundaries[z.name] ?? BoundarySettings(type: z.kind)
                let pn = MeshWriters.foamName(z.name)
                var body: String
                if let raw = s.openfoam.patchOverrides.first(where: { ($0.patch == z.name || $0.patch == pn) && $0.field == "T" })?.text {
                    body = raw.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n"
                } else if let nb = r.interfaces[z.name] {
                    // radiation absorbed at the wall arrives from a radiating fluid neighbour
                    let qrNbr = s.openfoam.radiation.model != .none && fluidRegions.contains(nb.region) ? "qr" : "none"
                    body = "        type            compressible::turbulentTemperatureRadCoupledMixed;\n        Tnbr            T;\n        qrNbr           \(qrNbr);\n        qr              none;\n        kappaMethod     \(km);\n        value           uniform \(FoamNum.s(T0));\n"
                } else if z.kind == .empty {
                    body = "        type            empty;\n"
                } else if b.type == .symmetry {
                    body = "        type            symmetry;\n"
                } else {
                    switch b.thermalCondition {
                    case .temperature: body = "        type            fixedValue;\n        value           \(values(z) { bcd.thermal.value[$0] });\n"
                    case .adiabatic: body = "        type            zeroGradient;\n"
                    case .heatFlux:
                        body = "        type            externalWallHeatFluxTemperature;\n        mode            flux;\n        q               \(values(z) { bcd.thermal.coeff[$0] });\n        kappaMethod     \(km);\n        value           uniform \(FoamNum.s(T0));\n"
                    case .convection:
                        body = "        type            externalWallHeatFluxTemperature;\n        mode            coefficient;\n        h               \(values(z) { bcd.thermal.coeff[$0] });\n        Ta              \(values(z) { bcd.thermal.value[$0] });\n        kappaMethod     \(km);\n        value           uniform \(FoamNum.s(T0));\n"
                    }
                    if b.type != .wall { body = "        type            zeroGradient;\n" }
                }
                t += "    \(pn)\n    {\n" + body + "    }\n"
                let pb = z.kind == .empty ? "        type            empty;\n" : (b.type == .symmetry ? "        type            symmetry;\n"
                                                                                  : "        type            calculated;\n        value           uniform \(FoamNum.s(pop));\n")
                p += "    \(pn)\n    {\n" + pb + "    }\n"
            }
            try put("\(timeDir)/\(name)/T", t + "}\n")
            try put("\(timeDir)/\(name)/p", p + "}\n")
        }
        let aniso = mat.anisotropicConductivity?.count == 3 ? mat.anisotropicConductivity : nil
        let kappa = aniso.map { "(\($0.map(FoamNum.s).joined(separator: " ")))" } ?? FoamNum.s(mat.thermalConductivity)
        let frame = aniso == nil ? "" : "\ncoordinateSystem\n{\n    type    cartesian;\n    origin  (0 0 0);\n    rotation { type axes; e1 (1 0 0); e2 (0 1 0); }\n}\n"
        try put("constant/\(name)/thermophysicalProperties", FoamFile.header("dictionary", "thermophysicalProperties", location: "constant/\(name)") + """
        thermoType
        {
            type            heSolidThermo;
            mixture         pureMixture;
            transport       \(aniso == nil ? "constIso" : "constAnIso");
            thermo          hConst;
            equationOfState rhoConst;
            specie          specie;
            energy          sensibleEnthalpy;
        }

        \(frame)
        mixture
        {
            specie          { molWeight \(FoamNum.s(mat.molecularWeight)); }
            transport       { kappa \(kappa); }
            thermodynamics  { Hf 0; Cp \(FoamNum.s(mat.specificHeat)); }
            equationOfState { rho \(FoamNum.s(mat.density)); }
        }

        """)
        // volumetric heat source
        if cz.energySource != .constant(0) {
            let src: String
            switch cz.energySource {
            case .constant(let q): src = "h (\(FoamNum.s(q)) 0);"
            case .expression(let e):
                let ex = try Expr(e, named: exprs)
                src = "h { explicit { type exprField; expression \"\(ex.openFOAM())\"; } implicit 0; }"
            }
            try put("constant/\(name)/fvOptions", FoamFile.header("dictionary", "fvOptions", location: "constant/\(name)") + """
            heatSource
            {
                type            scalarSemiImplicitSource;
                selectionMode   all;
                volumeMode      specific;
                sources { \(src) }
            }

            """)
        }
        let o = s.openfoam
        let nonOrth = o.nNonOrthogonalCorrectors ?? s.methods.nonOrthogonalCorrectors
        try put("system/\(name)/fvSchemes", FoamFile.header("dictionary", "fvSchemes", location: "system/\(name)") + """
        ddtSchemes { default \(steady ? "steadyState" : (s.methods.transient == .firstOrderImplicit ? "Euler" : "backward")); }
        gradSchemes { default Gauss linear; }
        divSchemes { default none; }
        laplacianSchemes { default Gauss linear corrected; }
        interpolationSchemes { default linear; }
        snGradSchemes { default corrected; }

        """)
        let l = o.energySolver
        try put("system/\(name)/fvSolution", FoamFile.header("dictionary", "fvSolution", location: "system/\(name)") + """
        solvers
        {
            h
            {
                solver          PCG;
                preconditioner  DIC;
                tolerance       \(FoamNum.s(min(l.tolerance, 1e-8)));
                relTol          \(FoamNum.s(l.relTol));
            }
            hFinal
            {
                $h;
                relTol          0;
            }
        }

        \(steady ? "SIMPLE" : "PIMPLE")
        {
            nNonOrthogonalCorrectors \(nonOrth);
        }

        relaxationFactors
        {
            equations { h \(FoamNum.s(o.relaxationEnergy ?? 1)); }
        }

        """)
    }
}
