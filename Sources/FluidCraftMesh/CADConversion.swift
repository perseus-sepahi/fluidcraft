import Foundation

/// Turns CAD files OpenCASCADE cannot open directly into ones it can:
/// - FreeCAD documents (`.FCStd`) are zip archives holding each feature's shape as a BREP;
///   the visible shapes are extracted (and combined when there are several).
/// - Native files of commercial systems (SolidWorks, CATIA, Parasolid, Creo/NX, Inventor,
///   Solid Edge, Rhino, ACIS, JT, IFC) are exported to STEP by an external converter: a
///   command template with `{input}` and `{output}` placeholders, e.g.
///   `/Applications/CAD Exchanger.app/Contents/MacOS/ExchangerConv -i {input} -e {output}`
///   (set in Settings, with `--converter`, or in `FLUIDCRAFT_CAD_CONVERTER`).
public enum CADConversion {
    public static var defaultConverter: String {
        ProcessInfo.processInfo.environment["FLUIDCRAFT_CAD_CONVERTER"] ?? UserDefaults.standard.string(forKey: "fluidcraft.cadConverter") ?? ""
    }

    /// A path Gmsh/OpenCASCADE or FluidCraft's surface readers can open.
    public static func prepare(_ path: String, converter: String = CADConversion.defaultConverter, workDir: URL) throws -> String {
        // absolute: Gmsh and the converters run inside the work directory
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw MeshError.io("\(url.path) does not exist") }
        switch CADFormat.detect(url) {
        case .freecad?: return try extractFreeCAD(url, workDir: workDir)
        case .solidcraft?: return try SolidCraftBridge.toSTEP(url, workDir: workDir)
        // Rhino files: SolidCraft reads them when no other converter is set
        case .native? where url.pathExtension.lowercased() == "3dm" && converter.trimmingCharacters(in: .whitespaces).isEmpty && SolidCraftBridge.isAvailable:
            return try SolidCraftBridge.toSTEP(url, workDir: workDir)
        case .native?: return try convertNative(url, converter: converter, workDir: workDir)
        default: return url.path
        }
    }

    /// The length unit a STEP file declares (its LENGTH_UNIT entity), if it is one FluidCraft knows.
    public static func declaredUnit(_ path: String) -> CADUnit? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let text = String(decoding: h.readData(ofLength: 400_000), as: UTF8.self).uppercased()
        // Files written by the bare OpenCASCADE writer (Gmsh) always say millimetres, whatever
        // the numbers mean: no claim is trusted from them. CAD systems (SolidWorks, SolidCraft,
        // FreeCAD, Onshape…) name themselves as the originating system.
        if let fn = text.range(of: "FILE_NAME(") {
            let header = text[fn.lowerBound...].prefix { $0 != ";" }
            if header.contains("OPEN CASCADE STEP PROCESSOR") && !header.contains("FREECAD") { return nil }
        }
        guard let r = text.range(of: "LENGTH_UNIT") else { return nil }
        // the unit entity, e.g. (LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.)) or a CONVERSION_BASED_UNIT('INCH',…)
        let lineStart = text[..<r.lowerBound].lastIndex(of: "#") ?? r.lowerBound
        let line = text[lineStart...].prefix { $0 != ";" }
        if line.contains("'INCH'") || line.contains("'IN'") { return .inch }
        if line.contains("'FOOT'") || line.contains("'FT'") { return .foot }
        if line.contains("SI_UNIT(.MILLI.,.METRE.)") { return .millimetre }
        if line.contains("SI_UNIT(.CENTI.,.METRE.)") { return .centimetre }
        if line.contains("SI_UNIT($,.METRE.)") { return .metre }
        return nil
    }

    // MARK: FreeCAD

    /// `unzip <options> <archive> <members> [-d dir]`
    static func unzip(_ archive: URL, options: [String], members: [String], to dir: URL? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = options + [archive.path] + members + (dir.map { ["-d", $0.path] } ?? [])
        let pipe = Pipe.closeOnExec()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MeshError.io("could not read \(archive.lastPathComponent) (unzip status \(p.terminationStatus))") }
        return d
    }

    static func extractFreeCAD(_ url: URL, workDir: URL) throws -> String {
        let doc = String(decoding: try unzip(url, options: ["-p"], members: ["Document.xml"]), as: UTF8.self)
        let gui = (try? unzip(url, options: ["-p"], members: ["GuiDocument.xml"])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // object name → shape file
        var shapes: [(String, String)] = []
        let objRE = try NSRegularExpression(pattern: #"<Object name="([^"]+)"[^>]*>(.*?)</Object>"#, options: [.dotMatchesLineSeparators])
        let fileRE = try NSRegularExpression(pattern: #"<Property name="Shape"[^>]*>\s*<Part file="([^"]+)""#, options: [.dotMatchesLineSeparators])
        let ns = doc as NSString
        for m in objRE.matches(in: doc, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)), body = ns.substring(with: m.range(at: 2))
            let bs = body as NSString
            if let f = fileRE.firstMatch(in: body, range: NSRange(location: 0, length: bs.length)) {
                shapes.append((name, bs.substring(with: f.range(at: 1))))
            }
        }
        guard !shapes.isEmpty else { throw MeshError.parse("\(url.lastPathComponent) contains no Part shapes") }
        // visible objects (GuiDocument), else the last shape (the final feature of a body)
        var visible: Set<String> = []
        let vpRE = try NSRegularExpression(pattern: #"<ViewProvider name="([^"]+)"[^>]*>(.*?)</ViewProvider>"#, options: [.dotMatchesLineSeparators])
        let gs = gui as NSString
        for m in vpRE.matches(in: gui, range: NSRange(location: 0, length: gs.length)) {
            let body = gs.substring(with: m.range(at: 2))
            if body.range(of: #"<Property name="Visibility"[^>]*>\s*<Bool value="true""#, options: .regularExpression) != nil {
                visible.insert(gs.substring(with: m.range(at: 1)))
            }
        }
        var chosen = shapes.filter { visible.contains($0.0) }.map(\.1)
        if chosen.isEmpty { chosen = [shapes.last!.1] }
        // archive member names come from the file: plain names only (no paths, quotes,
        // options or control characters) before they reach unzip
        for f in chosen {
            let ok = !f.isEmpty && f.first != "-" && !f.contains("..")
                && f.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
            guard ok else { throw MeshError.parse("\(url.lastPathComponent): unexpected shape entry name '\(GmshDriver.literal(f).prefix(60))'") }
        }
        let dir = workDir.appendingPathComponent("fcstd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try unzip(url, options: ["-o", "-q"], members: chosen, to: dir)
        // Gmsh recognises OpenCASCADE shapes by the .brep extension; fixed names keep anything
        // from the archive out of the Gmsh script below
        let paths = try chosen.enumerated().map { i, f -> String in
            let src = dir.appendingPathComponent(f), dst = dir.appendingPathComponent("shape\(i).brep")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: src, to: dst)
            return dst.path
        }
        if paths.count == 1 { return paths[0] }
        // several bodies: one BREP compound through OpenCASCADE
        guard let exe = GmshDriver.executable else { throw MeshError.io("Gmsh is needed to combine the \(paths.count) shapes of \(url.lastPathComponent)") }
        let out = dir.appendingPathComponent("combined.brep")
        let geo = "SetFactory(\"OpenCASCADE\");\n" + paths.map { "ShapeFromFile(\"\(GmshDriver.literal($0))\");\n" }.joined() + "Save \"\(GmshDriver.literal(out.path))\";\n"
        let g = dir.appendingPathComponent("combine.geo")
        try geo.write(to: g, atomically: true, encoding: .utf8)
        let (status, text) = try GmshDriver.run(exe, [g.path, "-0", "-nopopup"], in: dir, log: nil)
        guard status == 0, FileManager.default.fileExists(atPath: out.path) else { throw MeshError.io("could not combine FreeCAD shapes: \(text.suffix(300))") }
        return out.path
    }

    // MARK: Native formats

    static func convertNative(_ url: URL, converter: String, workDir: URL) throws -> String {
        let template = converter.trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else {
            throw MeshError.unsupported("""
            \(url.lastPathComponent) is a native \(url.pathExtension.uppercased()) file. Its geometry kernel is proprietary, so no open-source \
            reader exists. Export STEP (AP214/AP242) or IGES from the CAD system, or set a converter command in Settings \
            (e.g. CAD Exchanger: `ExchangerConv -i {input} -e {output}`).
            """)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let out = workDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".step")
        try? FileManager.default.removeItem(at: out)
        // No shell: the template is split into words (quotes group words), {input}/{output}
        // are substituted inside each word, and the program is executed directly, so file
        // names can never be interpreted as shell syntax.
        let argv = splitCommand(template).map {
            $0.replacingOccurrences(of: "{input}", with: url.path).replacingOccurrences(of: "{output}", with: out.path)
        }
        guard let program = argv.first else { throw MeshError.io("empty CAD converter command") }
        let p = Process()
        if program.contains("/") {
            p.executableURL = URL(fileURLWithPath: (program as NSString).expandingTildeInPath)
            p.arguments = Array(argv.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // PATH lookup, still no shell
            p.arguments = argv
        }
        let pipe = Pipe.closeOnExec()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw MeshError.io("CAD converter failed (status \(p.terminationStatus)): \(text.suffix(400))")
        }
        return out.path
    }

    /// Split a command line into words: whitespace separates, single or double quotes group,
    /// backslash escapes the next character. No other shell syntax has any meaning.
    public static func splitCommand(_ s: String) -> [String] {
        var words: [String] = [], cur = "", quote: Character? = nil, escape = false, inWord = false
        for ch in s {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "'" || ch == "\"" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" || ch == "\n" { if inWord { words.append(cur); cur = ""; inWord = false }; continue }
            cur.append(ch); inWord = true
        }
        if inWord { words.append(cur) }
        return words
    }
}


/// SolidCraft's headless `solidcraft-cli` (https://github.com/tangency-labs/solidcraft): opens
/// SolidCraft designs (and Rhino files) and writes exact STEP with its own B-rep kernel. Found
/// at fixed install locations or through `FLUIDCRAFT_SOLIDCRAFT_CLI` / `SOLIDCRAFT_CLI`, never from
/// a case file, and run directly without a shell (as in Draftwright's SolidCraft bridge).
public enum SolidCraftBridge {
    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment
        for k in ["FLUIDCRAFT_SOLIDCRAFT_CLI", "SOLIDCRAFT_CLI"] { if let v = env[k], !v.isEmpty { candidates.append(v) } }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["/opt/homebrew/bin/solidcraft-cli", "/usr/local/bin/solidcraft-cli", "\(home)/.cargo/bin/solidcraft-cli",
                       "/Applications/SolidCraft.app/Contents/MacOS/solidcraft-cli", "\(home)/Applications/SolidCraft.app/Contents/MacOS/solidcraft-cli"]
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public static var isAvailable: Bool { locate() != nil }

    /// Write `url` (a .sc design, or a file SolidCraft opens) as STEP into `workDir`; returns its path.
    /// SolidCraft works in millimetres, which the STEP file declares.
    public static func toSTEP(_ url: URL, workDir: URL) throws -> String {
        guard let exe = locate() else {
            throw MeshError.unsupported("\(url.lastPathComponent) is a SolidCraft design: install SolidCraft (its solidcraft-cli is used to write STEP), or export STEP from SolidCraft (File › Export).")
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let out = workDir.appendingPathComponent("solidcraft-model.step")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["run", "--in", url.path, "--quiet", "--out", out.path]
        p.currentDirectoryURL = workDir
        let pipe = Pipe.closeOnExec()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw MeshError.io("SolidCraft could not export \(url.lastPathComponent) as STEP (status \(p.terminationStatus)): \(text.suffix(400))")
        }
        return out.path
    }
}
