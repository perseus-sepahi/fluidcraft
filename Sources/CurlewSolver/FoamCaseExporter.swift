import Foundation
import CurlewMesh

/// Writes an OpenFOAM (ESI v2xxx) incompressible case equivalent to a Curlew setup:
/// polyMesh, 0/ fields, constant/ properties and system/ dictionaries for simpleFoam/pimpleFoam.
public enum FoamCaseExporter {
    public struct Options: Sendable {
        public var iterations = 2000
        public var turbulenceScheme = "bounded Gauss upwind"
        public var momentumScheme = "bounded Gauss linearUpwind grad(U)"
        public init() {}
    }

    static func header(_ cls: String, _ object: String, _ location: String) -> String {
        """
        FoamFile
        {
            version     2.0;
            format      ascii;
            class       \(cls);
            location    "\(location)";
            object      \(object);
        }

        """
    }

    static func v(_ x: Vec3) -> String { String(format: "(%.10g %.10g %.10g)", x.x, x.y, x.z) }

    public static func export(mesh m: Mesh, setup inSetup: CaseSetup, to dir: URL, options: Options = Options()) throws {
        var s = inSetup
        s.adopt(mesh: m)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("0"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("system"), withIntermediateDirectories: true)
        try MeshWriters.writeFoamPolyMesh(m, caseDir: dir)

        guard let zoneName = m.cellZones.first?.name, let matName = s.cellZones[zoneName]?.material,
              let mat = s.material(named: matName) else { throw SolverError("no fluid material") }
        let nu = mat.viscosity / mat.density
        let model = s.models.viscous
        let transient = s.general.time == .transient
        let exprs = try Expr.compileNamed(s.expressions.map { ($0.name, $0.definition) })
        let bcd = try BoundaryData(mesh: m, setup: s, exprs: exprs, time: 0)

        func write(_ path: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        // Fields
        func field(_ name: String, _ cls: String, _ dim: String, initial: String, patch: (BoundaryZone, BoundarySettings, Int) -> String) -> String {
            var t = header(cls, name, "0")
            t += "dimensions      \(dim);\n\ninternalField   uniform \(initial);\n\nboundaryField\n{\n"
            for (zi, z) in m.boundaryZones.enumerated() {
                let bs = s.boundaries[z.name] ?? BoundarySettings(type: z.kind)
                t += "    \(MeshWriters.foamName(z.name))\n    {\n" + patch(z, bs, zi) + "    }\n"
            }
            return t + "}\n"
        }
        func firstFace(_ z: BoundaryZone) -> Int { z.start - m.nInternalFaces }
        let ini = s.initialization
        let u0 = Vec3(ini.velocity[0].constantValue ?? 0, ini.velocity[1].constantValue ?? 0, ini.velocity[2].constantValue ?? 0)

        try write("0/U", field("U", "volVectorField", "[0 1 -1 0 0 0 0]", initial: v(u0)) { z, b, _ in
            switch z.kind {
            case .empty: return "        type            empty;\n"
            case .symmetry: return "        type            symmetryPlane;\n"
            case .wall:
                if b.shearCondition == .specifiedShear { return "        type            slip;\n" }
                let uw = bcd.uSpec[firstFace(z)]
                return norm(uw) > 0 ? "        type            fixedValue;\n        value           uniform \(v(uw));\n" : "        type            noSlip;\n"
            case .velocityInlet, .massFlowInlet:
                return "        type            fixedValue;\n        value           uniform \(v(bcd.uSpec[firstFace(z)]));\n"
            case .pressureOutlet, .outflow:
                return "        type            pressureInletOutletVelocity;\n        value           uniform (0 0 0);\n"
            case .pressureInlet:
                return "        type            pressureInletOutletVelocity;\n        value           uniform (0 0 0);\n"
            default:
                return "        type            zeroGradient;\n"
            }
        })
        try write("0/p", field("p", "volScalarField", "[0 2 -2 0 0 0 0]", initial: "0") { z, b, _ in
            switch z.kind {
            case .empty: return "        type            empty;\n"
            case .symmetry: return "        type            symmetryPlane;\n"
            case .pressureOutlet:
                return "        type            fixedValue;\n        value           uniform \((b.gaugePressure.constantValue ?? 0) / mat.density);\n"
            case .pressureInlet:
                return "        type            totalPressure;\n        p0              uniform \((b.gaugePressure.constantValue ?? 0) / mat.density);\n        value           uniform 0;\n"
            default: return "        type            zeroGradient;\n"
            }
        })
        if model.isTurbulent {
            func turb(_ name: String, _ dim: String, _ value: (Int) -> Double, wallType: String, wallValue: String) throws {
                let avg = (0..<bcd.nB).filter { bcd.kind[$0] == .velocityInlet }.map(value)
                let initialValue = avg.isEmpty ? value(0) : avg.reduce(0, +) / Double(avg.count)
                try write("0/\(name)", field(name, "volScalarField", dim, initial: String(format: "%.10g", initialValue)) { z, _, _ in
                    let bf = firstFace(z)
                    switch z.kind {
                    case .empty: return "        type            empty;\n"
                    case .symmetry: return "        type            symmetryPlane;\n"
                    case .wall: return "        type            \(wallType);\n        value           uniform \(wallValue);\n"
                    case .velocityInlet, .massFlowInlet, .pressureInlet:
                        return "        type            fixedValue;\n        value           uniform \(String(format: "%.10g", value(bf)));\n"
                    default:
                        return "        type            inletOutlet;\n        inletValue      uniform \(String(format: "%.10g", value(bf)));\n        value           uniform \(String(format: "%.10g", value(bf)));\n"
                    }
                })
            }
            switch model {
            case .kOmegaSST:
                try turb("k", "[0 2 -2 0 0 0 0]", { bcd.k.value[$0] }, wallType: "kqRWallFunction", wallValue: "0")
                try turb("omega", "[0 0 -1 0 0 0 0]", { bcd.omega.value[$0] }, wallType: "omegaWallFunction", wallValue: "1")
            case .kEpsilonStandard, .kEpsilonRealizable:
                try turb("k", "[0 2 -2 0 0 0 0]", { bcd.k.value[$0] }, wallType: "kqRWallFunction", wallValue: "0")
                try turb("epsilon", "[0 2 -3 0 0 0 0]", { bcd.epsilon.value[$0] }, wallType: "epsilonWallFunction", wallValue: "1")
            case .spalartAllmaras:
                try turb("nuTilda", "[0 2 -1 0 0 0 0]", { bcd.nuTilda.value[$0] }, wallType: "fixedValue", wallValue: "0")
            default: break
            }
            let nutWall = model == .spalartAllmaras ? "nutUSpaldingWallFunction" : (model == .kOmegaSST ? "nutUSpaldingWallFunction" : "nutkWallFunction")
            try write("0/nut", field("nut", "volScalarField", "[0 2 -1 0 0 0 0]", initial: "0") { z, _, _ in
                switch z.kind {
                case .empty: return "        type            empty;\n"
                case .symmetry: return "        type            symmetryPlane;\n"
                case .wall: return "        type            \(nutWall);\n        value           uniform 0;\n"
                default: return "        type            calculated;\n        value           uniform 0;\n"
                }
            })
        }

        // constant
        try write("constant/transportProperties", header("dictionary", "transportProperties", "constant") +
                  "transportModel  Newtonian;\n\nnu              \(String(format: "%.10g", nu));\n")
        let rasName: String
        switch model {
        case .kOmegaSST: rasName = "kOmegaSST"
        case .kEpsilonStandard: rasName = "kEpsilon"
        case .kEpsilonRealizable: rasName = "realizableKE"
        case .spalartAllmaras: rasName = "SpalartAllmaras"
        default: rasName = ""
        }
        try write("constant/turbulenceProperties", header("dictionary", "turbulenceProperties", "constant") +
                  (model.isTurbulent ? "simulationType  RAS;\n\nRAS\n{\n    RASModel        \(rasName);\n    turbulence      on;\n    printCoeffs     on;\n}\n" : "simulationType  laminar;\n"))

        // system
        let app = transient ? "pimpleFoam" : "simpleFoam"
        let walls = m.boundaryZones.filter { $0.kind == .wall }.map { MeshWriters.foamName($0.name) }
        try write("system/controlDict", header("dictionary", "controlDict", "system") + """
            application     \(app);
            startFrom       latestTime;
            startTime       0;
            stopAt          endTime;
            endTime         \(transient ? Double(s.run.numberOfTimeSteps) * s.run.timeStepSize : Double(options.iterations));
            deltaT          \(transient ? s.run.timeStepSize : 1);
            writeControl    timeStep;
            writeInterval   \(transient ? s.run.numberOfTimeSteps : options.iterations);
            purgeWrite      0;
            writeFormat     ascii;
            writePrecision  10;
            writeCompression off;
            timeFormat      general;
            timePrecision   8;
            runTimeModifiable true;

            functions
            {
                wallShearStress
                {
                    type            wallShearStress;
                    libs            (fieldFunctionObjects);
                    patches         (\(walls.joined(separator: " ")));
                    writeControl    writeTime;
                }
                yPlus
                {
                    type            yPlus;
                    libs            (fieldFunctionObjects);
                    writeControl    writeTime;
                }
            }

            """)
        let turbFields = model.usesOmega ? "k|omega" : (model.usesEpsilon ? "k|epsilon" : (model == .spalartAllmaras ? "nuTilda" : "k"))
        try write("system/fvSchemes", header("dictionary", "fvSchemes", "system") + """
            ddtSchemes      { default \(transient ? "backward" : "steadyState"); }
            gradSchemes     { default Gauss linear; grad(U) cellLimited Gauss linear 1; }
            divSchemes
            {
                default         none;
                div(phi,U)      \(options.momentumScheme);
                div(phi,\(model.usesOmega ? "k" : "k")) \(options.turbulenceScheme);
                div(phi,omega)  \(options.turbulenceScheme);
                div(phi,epsilon) \(options.turbulenceScheme);
                div(phi,nuTilda) \(options.turbulenceScheme);
                div((nuEff*dev2(T(grad(U))))) Gauss linear;
            }
            laplacianSchemes { default Gauss linear corrected; }
            interpolationSchemes { default linear; }
            snGradSchemes   { default corrected; }
            wallDist        { method meshWave; correctWalls true; }

            """)
        let urf = s.controls.urf
        try write("system/fvSolution", header("dictionary", "fvSolution", "system") + """
            solvers
            {
                p
                {
                    solver          GAMG;
                    smoother        GaussSeidel;
                    tolerance       1e-10;
                    relTol          0.05;
                }
                pFinal { $p; relTol 0; }
                "(U|\(turbFields))"
                {
                    solver          smoothSolver;
                    smoother        symGaussSeidel;
                    tolerance       1e-12;
                    relTol          0.1;
                }
                "(U|\(turbFields))Final" { $U; relTol 0; }
            }

            SIMPLE
            {
                nNonOrthogonalCorrectors 0;
                consistent      \(s.methods.coupling == .simplec ? "yes" : "no");
                residualControl { p 1e-6; U 1e-8; "(\(turbFields))" 1e-8; }
            }

            PIMPLE
            {
                nOuterCorrectors 1;
                nCorrectors     2;
                nNonOrthogonalCorrectors 0;
            }

            relaxationFactors
            {
                equations
                {
                    U               \(urf.momentum);
                    ".*"            \(urf.turbulentKineticEnergy);
                }
                fields
                {
                    p               \(s.methods.coupling == .simplec ? 1.0 : urf.pressure);
                }
            }

            """)
    }
}
