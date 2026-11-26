import Foundation
import FluidCraftMesh

/// The programs FluidCraft drives: OpenFOAM solves and meshes, Gmsh meshes, ParaView and Python
/// post-process. This finds each one, reports its version, and installs it with Homebrew when
/// the user asks (Settings › Tools).
public enum ExternalTool: String, CaseIterable, Identifiable, Sendable {
    case openfoam, gmsh, paraview, python, homebrew

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openfoam: return "OpenFOAM"
        case .gmsh: return "Gmsh"
        case .paraview: return "ParaView"
        case .python: return "Python 3"
        case .homebrew: return "Homebrew"
        }
    }

    public var required: Bool { self == .openfoam || self == .gmsh }

    /// What FluidCraft uses it for.
    public var role: String {
        switch self {
        case .openfoam: return "Solves every case; blockMesh, snappyHexMesh, potentialFoam and the Fluent/Gmsh mesh converters. FluidCraft targets the ESI release (openfoam.com, v2406 or newer)."
        case .gmsh: return "Unstructured and CAD meshing (STEP, IGES, STL…), airfoil and cylinder templates."
        case .paraview: return "Full post-processing of the OpenFOAM case (File › Open OpenFOAM Case in ParaView)."
        case .python: return "Python post-processing scripts (NumPy) and PINN training (PyTorch — Machine Learning tab)."
        case .homebrew: return "The package manager FluidCraft uses for one-click installs of the tools above."
        }
    }

    public var website: URL {
        switch self {
        case .openfoam: return URL(string: "https://github.com/gerlero/openfoam-app")!
        case .gmsh: return URL(string: "https://gmsh.info/#Download")!
        case .paraview: return URL(string: "https://www.paraview.org/download/")!
        case .python: return URL(string: "https://www.python.org/downloads/macos/")!
        case .homebrew: return URL(string: "https://brew.sh")!
        }
    }

    /// `brew` arguments that install it (nil: Homebrew installs itself from a Terminal).
    public var brewArguments: [String]? {
        switch self {
        case .openfoam: return ["install", "gerlero/openfoam/openfoam"]
        case .gmsh: return ["install", "gmsh"]
        case .paraview: return ["install", "--cask", "paraview"]
        case .python: return ["install", "python", "numpy"]
        case .homebrew: return nil
        }
    }

    /// The command a user can paste into Terminal instead.
    public var terminalCommand: String {
        if let a = brewArguments { return "brew " + a.joined(separator: " ") }
        return #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    }

    /// Roughly what an install downloads, for the confirmation.
    public var downloadSize: String {
        switch self {
        case .openfoam: return "about 1 GB (an app bundle holding a disk image)"
        case .gmsh: return "about 100 MB with its libraries"
        case .paraview: return "about 600 MB"
        case .python: return "about 100 MB"
        case .homebrew: return "about 100 MB, plus Apple's Command Line Tools if missing"
        }
    }

    // MARK: Detection

    public struct Status: Sendable, Equatable {
        public var found: Bool
        public var location: String?
        public var version: String?
        /// Extra detail (other installations, missing modules).
        public var detail: String?
    }

    /// Look for the tool (runs short version commands; call off the main thread).
    public func detect() -> Status {
        let fm = FileManager.default
        switch self {
        case .openfoam:
            let all = FoamDiscovery.discover()
            guard let first = all.first else { return Status(found: false) }
            let others = all.dropFirst().map { "\($0.name) \($0.version ?? "")".trimmingCharacters(in: .whitespaces) }
            return Status(found: true, location: first.location.path, version: first.version,
                          detail: others.isEmpty ? nil : "Also installed: " + others.joined(separator: ", ") + " (the first is used)")
        case .gmsh:
            guard let exe = GmshDriver.executable else { return Status(found: false) }
            let r = FoamProcessRunner.run(executable: exe, arguments: ["--version"], timeout: 20)
            let v = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.first?.isNumber == true }
            return Status(found: true, location: exe.path, version: v)
        case .paraview:
            guard let app = ExternalTool.paraViewApp else { return Status(found: false) }
            let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            return Status(found: true, location: app.path, version: plist?["CFBundleShortVersionString"] as? String)
        case .python:
            let py = PINNJob.defaultPython
            guard fm.isExecutableFile(atPath: py) else { return Status(found: false) }
            let code = "import sys, importlib.util as u\nprint('%d.%d.%d' % sys.version_info[:3])\nprint(' '.join(m for m in ('numpy', 'torch') if u.find_spec(m)))"
            let r = FoamProcessRunner.run(executable: URL(fileURLWithPath: py), arguments: ["-c", code], timeout: 30)
            let lines = r.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard r.exitCode == 0, let v = lines.first else { return Status(found: false, location: py, detail: "\(py) does not run") }
            let mods = Set((lines.count > 1 ? lines[1] : "").split(separator: " ").map(String.init))
            let detail = "NumPy " + (mods.contains("numpy") ? "✓" : "missing") + ", PyTorch " + (mods.contains("torch") ? "✓" : "missing")
            return Status(found: true, location: py, version: v, detail: detail)
        case .homebrew:
            guard let b = ExternalTool.brew else { return Status(found: false) }
            let r = FoamProcessRunner.run(executable: b, arguments: ["--version"], timeout: 30)
            let v = r.output.split(separator: "\n").first.map { $0.replacingOccurrences(of: "Homebrew ", with: "") }
            return Status(found: true, location: b.path, version: v)
        }
    }

    public static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The newest ParaView app in /Applications or ~/Applications.
    public static var paraViewApp: URL? {
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for d in dirs {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
            if let pv = apps.filter({ $0.lowercased().hasPrefix("paraview") && $0.hasSuffix(".app") }).sorted().last {
                return URL(fileURLWithPath: d).appendingPathComponent(pv)
            }
        }
        return nil
    }

    // MARK: Install

    /// Install with Homebrew, streaming its output to `log`. Blocking; only on the user's request.
    /// Homebrew asks for no password for these (apps go to /Applications, programs to
    /// /opt/homebrew); if it ever needs one, the error says to run the command in Terminal.
    public func install(log: @escaping (String) -> Void) throws {
        guard let args = brewArguments else { throw MeshError.unsupported("Homebrew installs itself from Terminal: \(terminalCommand)") }
        guard let brew = ExternalTool.brew else { throw MeshError.unsupported("Homebrew is not installed (see brew.sh), or install \(name) from \(website.absoluteString)") }
        let p = Process()
        p.executableURL = brew
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let pipe = Pipe.closeOnExec()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var tail: [String] = []
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            for l in String(decoding: d, as: UTF8.self).split(separator: "\n") where !l.isEmpty {
                lock.lock(); tail.append(String(l)); if tail.count > 20 { tail.removeFirst() }; lock.unlock()
                log(String(l))
            }
        }
        try p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)
        guard p.terminationStatus == 0 else {
            lock.lock(); let t = tail.suffix(6).joined(separator: "\n"); lock.unlock()
            let password = t.lowercased().contains("password") || t.contains("sudo")
            throw MeshError.io("brew \(args.joined(separator: " ")) failed (exit \(p.terminationStatus))." +
                               (password ? " It needs your password: run “\(terminalCommand)” in Terminal." : "") + "\n" + t)
        }
    }
}
