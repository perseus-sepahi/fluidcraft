import Foundation
import CurlewMesh
import CurlewSolver
import CurlewPost
import AppKit

/// Text command interface (console). Paths follow a Fluent-like menu tree.
extension Workspace {
    static let helpText = """
    Commands
      help                                   this list
      /file/read-mesh <path>                 import a Fluent/Gmsh/OpenFOAM mesh
      /file/read-case <path.curlew>          open a case
      /file/write-case                       save case & data
      /file/export-vtk <path.vtu>            write the solution for ParaView
      /mesh/check                            mesh statistics and quality
      /define/models/viscous <laminar|k-omega-sst|k-epsilon-standard|k-epsilon-realizable|spalart-allmaras>
      /define/models/energy <yes|no>
      /define/boundary/type <zone> <type>    e.g. velocity-inlet, pressure-outlet, wall, symmetry
      /define/boundary/velocity <zone> <m/s> velocity magnitude (normal) at an inlet
      /solve/initialize                      initialize with the current method
      /solve/iterate <n>                     run n iterations (or time steps when transient)
      /solve/set/urf/<pressure|momentum|energy> <value>
      /report/forces [zone...]               pressure + viscous forces on walls
      /report/mass-flow                      mass flow through all open boundaries
      /report/surface-average <field> <zone> area-weighted average
      /display/contour <field>               contours on the default surfaces
      /display/vectors | /display/mesh | /display/pathlines
      /display/save-picture <path.png>       PNG of the graphics window (with legend)
      /surface/plane <name> <x|y|z> <value>  create a cut plane
      /display/set/surfaces <names...>       surfaces used by contours/vectors
      /plot/xy <field> x0 y0 z0 x1 y1 z1     XY plot along a line
      /tutorial <id>                         \(TutorialCatalog.all.map(\.id).joined(separator: ", "))
    """

    func execute(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        log("> " + line, .command)
        var parts = line.split(separator: " ").map(String.init)
        var cmd = parts.removeFirst().lowercased()
        if !cmd.hasPrefix("/") && cmd != "help" { cmd = "/" + cmd }
        func arg(_ i: Int) -> String? { i < parts.count ? parts[i] : nil }
        switch cmd {
        case "help", "/help", "?":
            log(Workspace.helpText)
        case "/file/read-mesh", "/file/import":
            guard let p = arg(0) else { log("usage: /file/read-mesh <path>", .warning); return }
            importMesh(url: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        case "/file/read-case":
            guard let p = arg(0) else { log("usage: /file/read-case <path>", .warning); return }
            openCase(url: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        case "/file/write-case", "/file/write-case-data":
            saveCase(as: false)
        case "/file/export-vtk":
            guard let s = solver, initialized, let p = arg(0) else { log("usage: /file/export-vtk <path.vtu> (after initialization)", .warning); return }
            do { try VTKExport.write(solver: s, to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)); log("Wrote \(p)") } catch { log("\(error)", .error) }
        case "/mesh/check":
            if let q = meshQuality { log(q.text) } else { log("No mesh.", .warning) }
        case "/define/models/viscous":
            if let a = arg(0), let m = ViscousModel(rawValue: a) { setup.models.viscous = m; log("Viscous model: \(m.displayName)") }
            else { log("models: " + ViscousModel.allCases.map(\.rawValue).joined(separator: ", "), .warning) }
        case "/define/models/energy":
            setup.models.energy = ["yes", "on", "true", "1"].contains(arg(0)?.lowercased() ?? "yes")
            log("Energy equation \(setup.models.energy ? "enabled" : "disabled")")
        case "/define/boundary/type":
            guard let z = arg(0), let t = arg(1), let k = ZoneKind(rawValue: t), setup.boundaries[z] != nil else { log("usage: /define/boundary/type <zone> <type>", .warning); return }
            setup.boundaries[z]!.type = k
            log("\(z) is now \(k.displayName)")
        case "/define/boundary/velocity":
            guard let z = arg(0), let v = arg(1).flatMap(Double.init), setup.boundaries[z] != nil else { log("usage: /define/boundary/velocity <zone> <value>", .warning); return }
            setup.boundaries[z]!.velocityMagnitude = .constant(v)
            setup.boundaries[z]!.velocitySpecification = .magnitudeNormal
            log("\(z): velocity magnitude \(v) m/s")
        case "/solve/initialize", "/solve/initialize/initialize-flow", "/solve/initialize/hyb-initialization":
            if cmd.hasSuffix("hyb-initialization") { setup.initialization.method = .hybrid }
            initialize()
        case "/solve/iterate", "/solve/dual-time-iterate":
            if let n = arg(0).flatMap(Int.init) {
                if setup.general.time == .transient { setup.run.numberOfTimeSteps = n } else { setup.run.iterations = n }
            }
            calculate()
        case let c where c.hasPrefix("/solve/set/urf/"):
            let eq = String(c.dropFirst("/solve/set/urf/".count))
            guard let v = arg(0).flatMap(Double.init) else { log("usage: \(c) <value>", .warning); return }
            switch eq {
            case "pressure": setup.controls.urf.pressure = v
            case "momentum": setup.controls.urf.momentum = v
            case "energy": setup.controls.urf.energy = v
            case "k", "turbulent-kinetic-energy": setup.controls.urf.turbulentKineticEnergy = v
            case "omega": setup.controls.urf.specificDissipationRate = v
            default: log("unknown equation \(eq)", .warning); return
            }
            log("URF \(eq) = \(v)")
        case "/report/forces":
            guard let s = solver, initialized else { log("No solution.", .warning); return }
            let zones = parts.isEmpty ? (mesh?.boundaryZones.filter { $0.kind == .wall }.map(\.name) ?? []) : parts
            for z in zones {
                let (F, _) = Reports.forces([z], s)
                log(String(format: "%@  pressure (%.6g, %.6g, %.6g)  viscous (%.6g, %.6g, %.6g) N", z,
                           F.pressure.x, F.pressure.y, F.pressure.z, F.viscous.x, F.viscous.y, F.viscous.z))
            }
        case "/report/mass-flow", "/report/fluxes/mass-flow":
            guard let s = solver, let m = mesh, initialized else { log("No solution.", .warning); return }
            var net = 0.0
            for z in m.boundaryZones where ![.empty, .wall, .symmetry].contains(z.kind) {
                var r = ReportDefinition(name: z.name, kind: .massFlowRate); r.zones = [z.name]
                let v = Reports.evaluate(r, solver: s); net += v
                log(String(format: "%-28@ %16.8g kg/s", z.name as NSString, v))
            }
            log(String(format: "%-28@ %16.8g kg/s", "Net" as NSString, net))
        case "/report/surface-average":
            guard let s = solver, initialized, let f = arg(0), let z = arg(1) else { log("usage: /report/surface-average <field> <zone>", .warning); return }
            var r = ReportDefinition(name: "avg", kind: .areaWeightedAverage); r.field = f; r.zones = [z]
            log(String(format: "Area-weighted average of %@ on %@: %.8g", f, z, Reports.evaluate(r, solver: s)))
        case "/display/contour", "/display/contours":
            if let f = arg(0) { display.field = f }
            display.mode = .contours; graphicsTab = .viewport; refreshDisplay()
        case "/display/vectors":
            display.mode = .vectors; graphicsTab = .viewport; refreshDisplay()
        case "/display/mesh":
            display.mode = .mesh; graphicsTab = .viewport; refreshDisplay()
        case "/display/pathlines":
            display.mode = .pathlines; graphicsTab = .viewport; refreshDisplay()
        case "/display/save-picture":
            guard let p = arg(0) else { log("usage: /display/save-picture <path.png>", .warning); return }
            do { try viewController?.snapshot(to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)); log("Saved \(p)") } catch { log("\(error)", .error) }
        case "/display/set/surfaces":
            display.surfaces = parts
            refreshDisplay()
        case "/display/set/colormap":
            if let c = arg(0).flatMap({ n in Colormap.allCases.first { $0.rawValue.lowercased() == n.lowercased() } }) { display.colormap = c; refreshDisplay() }
        case "/display/set/bands":
            display.bands = arg(0).flatMap(Int.init) ?? 0; refreshDisplay()
        case "/display/view":
            if let v = arg(0), let p = ViewPreset(rawValue: v) { viewController?.apply(p) }
        case "/display/residuals":
            graphicsTab = .residuals
        case "/display/reports":
            graphicsTab = .reports
        case "/display/graphics":
            graphicsTab = .viewport
        case "/surface/plane":
            // /surface/plane name axis value
            guard let n = arg(0), let ax = arg(1), let v = arg(2).flatMap(Double.init), let i = ["x", "y", "z"].firstIndex(of: ax) else { log("usage: /surface/plane <name> <x|y|z> <value>", .warning); return }
            var p = [0.0, 0.0, 0.0]; p[i] = v
            var nrm = [0.0, 0.0, 0.0]; nrm[i] = 1
            namedSurfaces.append(NamedSurface(name: n, definition: .plane(point: p, normal: nrm)))
            log("Created plane \(n)")
        case "/select":
            if let a = arg(0), let item = [OutlineItem.meshGeneration, .meshInfo, .general, .models, .materials, .cellZones, .boundaries, .methods, .controls,
                                            .initialization, .runCalculation, .contours, .vectors, .pathlines, .reports, .validation, .xyPlot].first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "-") == a.lowercased() }) {
                selection = item
            }
        case "/plot/xy":
            // /plot/xy <field> x0 y0 z0 x1 y1 z1
            let nums = parts.dropFirst().compactMap(Double.init)
            guard let f = arg(0), nums.count == 6, let post else { log("usage: /plot/xy <field> x0 y0 z0 x1 y1 z1", .warning); return }
            let pts = post.lineSample(f, from: Vec3(nums[0], nums[1], nums[2]), to: Vec3(nums[3], nums[4], nums[5]), points: 300)
            xyPlot = XYPlotData(title: f, xLabel: "Distance along line (m)", yLabel: f,
                                series: [.init(name: f, points: pts.enumerated().map { XYPoint(id: $0.offset, x: $0.element.0, y: $0.element.1) })])
            graphicsTab = .xy
        case "/quit":
            NSApp.terminate(nil)
        case "/tutorial":
            if let id = arg(0), let t = TutorialCatalog.all.first(where: { $0.id == id }) { loadTutorial(t) }
            else { log("tutorials: " + TutorialCatalog.all.map(\.id).joined(separator: ", "), .warning) }
        default:
            log("Unknown command '\(cmd)'. Type help.", .warning)
        }
    }
}
