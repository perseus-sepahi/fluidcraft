import Testing
import Foundation
@testable import CurlewMesh
@testable import CurlewSolver
@testable import CurlewFoam

/// CAD exports from SolidWorks / SolidCraft, file units and the region to simulate.
@Suite struct CADImportTests {
    func stepFile(originating: String, unit: String) throws -> String {
        let url = URL(fileURLWithPath: "/tmp/curlew-unit-\(UUID().uuidString.prefix(6)).step")
        let text = """
        ISO-10303-21;
        HEADER;
        FILE_NAME('part.step','2026-11-05',('a'),('b'),\(originating));
        ENDSEC;
        DATA;
        #5=(LENGTH_UNIT()NAMED_UNIT(*)\(unit));
        ENDSEC;
        END-ISO-10303-21;
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func declaredUnits() throws {
        let sw = try stepFile(originating: "'SwSTEP 2.0','SolidWorks 2025',''", unit: "SI_UNIT(.MILLI.,.METRE.)")
        let sc = try stepFile(originating: "'SolidCraft','SolidCraft',''", unit: "SI_UNIT(.MILLI.,.METRE.)")
        let m = try stepFile(originating: "'Onshape','Onshape',''", unit: "SI_UNIT($,.METRE.)")
        // Gmsh / bare OpenCASCADE always writes MILLI, whatever the numbers are: not trusted
        let occ = try stepFile(originating: "'Open CASCADE STEP processor 7.8','Open CASCADE 7.8','Unknown'", unit: "SI_UNIT(.MILLI.,.METRE.)")
        defer { for p in [sw, sc, m, occ] { try? FileManager.default.removeItem(atPath: p) } }
        #expect(CADConversion.declaredUnit(sw) == .millimetre)
        #expect(CADConversion.declaredUnit(sc) == .millimetre)
        #expect(CADConversion.declaredUnit(m) == .metre)
        #expect(CADConversion.declaredUnit(occ) == nil)
        #expect(CADFormat.detect(URL(fileURLWithPath: "x.sc")) == .solidcraft && CADFormat.solidcraft.isBRep)
        #expect(CADFormat.detect(URL(fileURLWithPath: "x.SLDPRT")) == .native)
    }

    @Test func regionToSimulate() throws {
        var spec = CADAnalysisSpec()
        spec.flowAxis = 0
        #expect(spec.padding(groundAxis: 2) == [3, 8, 3, 3, 3, 3])
        spec.domainMargins = [2, 6, 1.5, 4, 3]
        spec.onGround = true
        #expect(spec.padding(groundAxis: 2) == [2, 6, 1.5, 1.5, 0, 3])
        // flow along y, ground below along z
        spec.flowAxis = 1
        #expect(spec.padding(groundAxis: 2) == [1.5, 1.5, 2, 6, 0, 3])
        // the Gmsh script names the floor and refines the box
        var ms = MeshingSettings(template: .cad(path: "/tmp/x.step", external: true, flowAxis: 0, padding: [2, 6, 1, 1, 0, 3]))
        ms.groundAxis = 2
        ms.refinementBoxes = [RefinementBox(min: [0, -1, 0], max: [2, 1, 1], size: 0.01)]
        let geo = try GmshDriver.script(ms).geo
        #expect(geo.contains("Physical Surface(\"ground\")") && geo.contains("Field[10] = Box;") && geo.contains("Background Field = 30;"))
        #expect(geo.contains("eps = 1e-5*Max("))
        // older specs without the new keys still decode
        let old = try JSONDecoder().decode(CADAnalysisSpec.self, from: Data(#"{"path":"a.step","kind":"externalAerodynamics","speed":3}"#.utf8))
        #expect(old.speed == 3 && old.domainMargins == nil && !old.onGround && old.unitFromFile)
    }

    /// A SolidCraft design (.sc) becomes exact STEP through SolidCraft's own tool.
    @Test(.enabled(if: SolidCraftBridge.isAvailable)) func solidCraftDesign() throws {
        let dir = URL(fileURLWithPath: "/tmp/curlew-sc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = #"[{"command": "solid.box", "params": {"length": 50, "width": 20, "height": 10, "body_name": "b"}}]"#
        try script.write(to: dir.appendingPathComponent("p.json"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = SolidCraftBridge.locate()!
        p.arguments = ["run", dir.appendingPathComponent("p.json").path, "--quiet", "--save", dir.appendingPathComponent("part.sc").path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let step = try CADConversion.prepare(dir.appendingPathComponent("part.sc").path, workDir: dir.appendingPathComponent("work"))
        #expect(step.hasSuffix(".step") && FileManager.default.fileExists(atPath: step))
        #expect(CADConversion.declaredUnit(step) == .millimetre)
    }
}
