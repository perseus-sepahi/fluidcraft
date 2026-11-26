import Foundation

// MARK: - Installation

/// An OpenFOAM installation on this machine and how to bring it to life in a shell.
///
/// Three layouts exist in practice on macOS, and the runner has to know which it is dealing
/// with because they are activated differently:
///
/// - **volumeBundle** — the openfoam.com `.app` that ships a disk image. The image has to be
///   *mounted* first (the app's own `volume` helper does it) and then `etc/bashrc` sourced
///   from the mounted volume. It auto-ejects, so "was mounted last week" means nothing.
/// - **sourcedTree** — a plain directory with `etc/bashrc` (Homebrew, a source build,
///   `~/OpenFOAM/OpenFOAM-vXXXX`): source the bashrc.
/// - **directTree** — a bundle whose `bashrc` cannot locate itself (the SimFlow build, whose
///   path contains spaces and whose bashrc resolves to `/Applications`); instead the launcher
///   exports `WM_PROJECT_DIR`, `PATH` and the Open MPI prefix by hand, and so do we.
public struct FoamInstallation: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case volumeBundle, sourcedTree, directTree
    }

    public var kind: Kind
    public var name: String
    /// "v2606", "v2506", "11" … as best it can be read off the path or the bashrc.
    public var version: String?
    /// The `.app` for a bundle, otherwise the tree root containing `etc/` and `bin/`.
    public var location: URL

    public var id: String { location.path }

    public init(kind: Kind, name: String, version: String?, location: URL) {
        self.kind = kind
        self.name = name
        self.version = version
        self.location = location
    }

    /// Distribution flavour: the ESI (openfoam.com) `vYYMM` naming versus the Foundation's
    /// integer releases. The case writer targets ESI, so this is worth showing in the picker.
    public var isESI: Bool { version?.hasPrefix("v") ?? true }
}

// MARK: - Resolved environment

/// An installation made ready to run: the volume is mounted, and the shell prelude and
/// environment variables that activate it are known.
public struct FoamEnvironment: Sendable, Hashable {
    public var installation: FoamInstallation
    /// Directory that holds `etc/bashrc` (the mounted volume for a bundle).
    public var root: URL
    /// Shell text run before every command, e.g. `. "/Volumes/OpenFOAM-v2606/etc/bashrc"`.
    public var prelude: String
    /// Extra variables for the direct layout (empty when the bashrc does the work).
    public var variables: [String: String]

    /// `bash -c` script that activates the environment, enters `caseDirectory` and execs
    /// `command`. `exec` matters: it makes the OpenFOAM binary *be* the child process, so
    /// terminating the child terminates the solver rather than an idle shell in front of it.
    public func script(caseDirectory: URL, command: String, arguments: [String], requiredApplication: String? = nil) -> String {
        var lines: [String] = []
        if !prelude.isEmpty { lines.append(prelude) }
        lines.append("cd \(FoamShell.quote(caseDirectory.path)) || exit 98")
        if let app = requiredApplication { lines.append(FoamShell.requireApplication(app)) }
        let argv = ([command] + arguments).map(FoamShell.quote).joined(separator: " ")
        lines.append("exec \(argv)")
        return lines.joined(separator: "\n")
    }

    /// Environment handed to the child: the parent's, with the direct-layout variables laid
    /// over it. `PATH` is prepended rather than replaced so `mpirun` from the bundle wins but
    /// `/usr/bin` tools are still reachable.
    public func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in variables {
            if k == "PATH", let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = v + ":" + existing
            } else {
                env[k] = v
            }
        }
        // Non-interactive shells on macOS may not export a locale; OpenFOAM's parsers want C.
        if env["LC_ALL"] == nil { env["LC_ALL"] = "C" }
        return env
    }
}

// MARK: - Shell quoting

enum FoamShell {
    /// Single-quote a string for `bash -c`, the one quoting scheme with no escape surprises.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell lines that exit 96 unless `name` is a plain program name that resolves to a file
    /// in one of the installation's application directories. Shell functions, aliases, paths
    /// and general tools (sh, rm, python …) are refused, so a stage from a case file can only
    /// start an OpenFOAM application.
    static func requireApplication(_ name: String) -> String {
        let plain = !name.isEmpty && name.first!.isLetter && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        guard plain else { return "echo \(quote("FluidCraft: \(name) is not an OpenFOAM application name")) >&2; exit 96" }
        return """
        fluidcraft_app=$(type -P -- \(quote(name))) || exit 96
        fluidcraft_ok=0
        for fluidcraft_d in "$FOAM_APPBIN" "$FOAM_SITE_APPBIN" "$FOAM_USER_APPBIN"; do
            [ -n "$fluidcraft_d" ] && [ "${fluidcraft_app%/*}" = "$fluidcraft_d" ] && fluidcraft_ok=1
        done
        [ "$fluidcraft_ok" = 1 ] || { echo "FluidCraft: $fluidcraft_app is not in FOAM_APPBIN; custom stages run OpenFOAM applications only" >&2; exit 96; }
        """
    }
}

// MARK: - Errors

public enum FoamSolveError: Error, CustomStringConvertible, Sendable {
    case noInstallation
    case mountFailed(String)
    case notRunnable(String)
    case missingCase(String)
    case missingMesh(String)
    case stageFailed(stage: String, exitCode: Int32, hint: String)
    case cancelled
    case io(String)

    public var description: String {
        switch self {
        case .noInstallation: return "No OpenFOAM installation is selected."
        case .mountFailed(let s): return "Could not mount the OpenFOAM disk image: \(s)"
        case .notRunnable(let s): return "OpenFOAM environment is not usable: \(s)"
        case .missingCase(let s): return "Case directory problem: \(s)"
        case .missingMesh(let s): return "No mesh to solve on: \(s)"
        case .stageFailed(let stage, let code, let hint):
            return "\(stage) failed (exit \(code)). \(hint)"
        case .cancelled: return "Run cancelled."
        case .io(let s): return s
        }
    }
}

// MARK: - Discovery

public enum FoamDiscovery {

    /// Every installation that can be found in the usual places, best first.
    public static func discover(fileManager fm: FileManager = .default) -> [FoamInstallation] {
        var found: [FoamInstallation] = []

        // 1. App bundles in /Applications — the common case on a Mac.
        for appsDir in [URL(fileURLWithPath: "/Applications"),
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            guard let items = try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) else { continue }
            for app in items where app.pathExtension == "app"
                && app.lastPathComponent.localizedCaseInsensitiveContains("openfoam") {
                if let inst = installation(inAppBundle: app, fileManager: fm) { found.append(inst) }
            }
        }

        // 2. Whatever the user's shell already knows about.
        if let dir = ProcessInfo.processInfo.environment["WM_PROJECT_DIR"] {
            if let inst = installation(atTree: URL(fileURLWithPath: dir), fileManager: fm) { found.append(inst) }
        }

        // 3. Conventional directories.
        var candidates: [URL] = []
        for pattern in ["/opt", "/usr/lib/openfoam", "/opt/homebrew/opt", "/usr/local/opt", "/Volumes"] {
            let base = URL(fileURLWithPath: pattern)
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            candidates += items.filter { $0.lastPathComponent.localizedCaseInsensitiveContains("openfoam") }
        }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("OpenFOAM")
        if let items = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            candidates += items.filter { $0.lastPathComponent.hasPrefix("OpenFOAM-") }
        }
        for c in candidates {
            if let inst = installation(atTree: c, fileManager: fm) { found.append(inst) }
        }

        // A mounted volume and the bundle that mounts it describe the same install; keep the
        // bundle, which knows how to re-mount after an eject. Bundles sort first, so the loose
        // tree with the same version is the one that gets dropped.
        var bundleVersions = Set<String>()
        var unique: [FoamInstallation] = []
        for inst in found.sorted(by: rank) {
            let key = (inst.version ?? inst.name).lowercased()
            if inst.kind == .sourcedTree, bundleVersions.contains(key) { continue }
            if unique.contains(inst) { continue }
            if inst.kind != .sourcedTree { bundleVersions.insert(key) }
            unique.append(inst)
        }
        return unique
    }

    /// Newest ESI release first; for the same version, bundles before loose trees.
    private static func rank(_ a: FoamInstallation, _ b: FoamInstallation) -> Bool {
        let va = versionNumber(a.version), vb = versionNumber(b.version)
        if va != vb { return va > vb }
        return kindOrder(a.kind) < kindOrder(b.kind)
    }

    private static func kindOrder(_ k: FoamInstallation.Kind) -> Int {
        switch k {
        case .volumeBundle: return 0
        case .directTree: return 1
        case .sourcedTree: return 2
        }
    }

    static func versionNumber(_ v: String?) -> Int {
        guard let v else { return 0 }
        let digits = v.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    /// Recognise a user-chosen path: an `.app`, a tree with `etc/bashrc`, or a bashrc itself.
    public static func installation(at url: URL, fileManager fm: FileManager = .default) -> FoamInstallation? {
        if url.pathExtension == "app" { return installation(inAppBundle: url, fileManager: fm) }
        if url.lastPathComponent == "bashrc" {
            return installation(atTree: url.deletingLastPathComponent().deletingLastPathComponent(), fileManager: fm)
        }
        return installation(atTree: url, fileManager: fm)
    }

    static func installation(inAppBundle app: URL, fileManager fm: FileManager) -> FoamInstallation? {
        let res = app.appendingPathComponent("Contents/Resources")
        let name = app.deletingPathExtension().lastPathComponent
        let version = versionToken(in: name)
        if fm.fileExists(atPath: res.appendingPathComponent("volume").path) {
            return FoamInstallation(kind: .volumeBundle, name: name, version: version, location: app)
        }
        if fm.fileExists(atPath: res.appendingPathComponent("bin/blockMesh").path) {
            return FoamInstallation(kind: .directTree, name: name, version: version, location: res)
        }
        return nil
    }

    static func installation(atTree root: URL, fileManager fm: FileManager) -> FoamInstallation? {
        let bashrc = root.appendingPathComponent("etc/bashrc")
        let name = root.lastPathComponent
        if fm.fileExists(atPath: bashrc.path) {
            // A tree whose bashrc can find itself has `platforms/`; one that cannot (SimFlow)
            // has a flat `bin/` next to `etc/`. Prefer sourcing, fall back to direct.
            if fm.fileExists(atPath: root.appendingPathComponent("platforms").path) {
                return FoamInstallation(kind: .sourcedTree, name: name,
                                        version: versionToken(in: name) ?? versionToken(inBashrc: bashrc),
                                        location: root)
            }
            if fm.fileExists(atPath: root.appendingPathComponent("bin/blockMesh").path) {
                return FoamInstallation(kind: .directTree, name: name, version: versionToken(in: name), location: root)
            }
        }
        return nil
    }

    /// "OpenFOAM-v2606" -> "v2606", "OpenFOAM 2506 (by SimFlow)" -> "v2506", "openfoam11" -> "11".
    static func versionToken(in name: String) -> String? {
        if let m = esiVersion.firstMatch(name) { return "v" + m[1] }
        if let m = yearMonth.firstMatch(name) { return "v" + m[1] }
        if let m = shortVersion.firstMatch(name) { return m[1] }
        return nil
    }

    private static let esiVersion = FoamRegex(#"v(\d{4})"#)
    private static let yearMonth = FoamRegex(#"(?<!\d)(\d{4})(?!\d)"#)
    private static let shortVersion = FoamRegex(#"(?<!\d)(\d{1,2})(?!\d)"#)

    static func versionToken(inBashrc url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("WM_PROJECT_VERSION=") {
            if let eq = line.firstIndex(of: "=") {
                let v = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !v.isEmpty, !v.contains("$") { return String(v) }
            }
        }
        return nil
    }
}

// MARK: - Activation

extension FoamInstallation {

    /// Make the installation runnable: mount the image if needed and work out the prelude.
    /// Blocking (a mount can take a few seconds); call off the main thread.
    static let mountLock = NSLock()
    nonisolated(unsafe) static var mountPoints: [String: URL] = [:]

    public func resolve() throws -> FoamEnvironment {
        let fm = FileManager.default
        switch kind {
        case .volumeBundle:
            // One mount at a time: the bundle's helper fails when several runs (parallel jobs,
            // tests) call it at once. A mount point that still holds etc/bashrc is reused.
            FoamInstallation.mountLock.lock()
            defer { FoamInstallation.mountLock.unlock() }
            if let cached = FoamInstallation.mountPoints[location.path],
               fm.fileExists(atPath: cached.appendingPathComponent("etc/bashrc").path) {
                // the helper keeps the image mounted while it is in use; touch it so it stays up
                _ = FoamProcessRunner.run(executable: location.appendingPathComponent("Contents/Resources/volume"), arguments: ["-quiet", "mount"], timeout: 90)
                return FoamEnvironment(installation: self, root: cached,
                                       prelude: ". \(FoamShell.quote(cached.appendingPathComponent("etc/bashrc").path)) >/dev/null 2>&1 || exit 97",
                                       variables: [:])
            }
            let helper = location.appendingPathComponent("Contents/Resources/volume")
            let mount = FoamProcessRunner.run(executable: helper, arguments: ["-quiet", "mount"], timeout: 90)
            guard mount.exitCode == 0 else {
                throw FoamSolveError.mountFailed(mount.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var rootPath = ""
            for attempt in 0..<3 where rootPath.isEmpty {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
                let prefix = FoamProcessRunner.run(executable: helper, arguments: ["-show-prefix"], timeout: 30)
                if prefix.exitCode == 0 { rootPath = prefix.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if rootPath.isEmpty {
                // the image mounts at /Volumes/<bundle name> (e.g. OpenFOAM-v2606)
                let guess = "/Volumes/" + location.deletingPathExtension().lastPathComponent
                if fm.fileExists(atPath: guess + "/etc/bashrc") { rootPath = guess }
            }
            guard !rootPath.isEmpty else {
                throw FoamSolveError.mountFailed("the volume helper did not report a mount point")
            }
            let root = URL(fileURLWithPath: rootPath)
            let bashrc = root.appendingPathComponent("etc/bashrc")
            guard fm.fileExists(atPath: bashrc.path) else {
                throw FoamSolveError.notRunnable("\(bashrc.path) does not exist after mounting")
            }
            FoamInstallation.mountPoints[location.path] = root
            return FoamEnvironment(installation: self, root: root,
                                   prelude: ". \(FoamShell.quote(bashrc.path)) >/dev/null 2>&1 || exit 97",
                                   variables: [:])

        case .sourcedTree:
            let bashrc = location.appendingPathComponent("etc/bashrc")
            guard fm.fileExists(atPath: bashrc.path) else {
                throw FoamSolveError.notRunnable("\(bashrc.path) does not exist")
            }
            return FoamEnvironment(installation: self, root: location,
                                   prelude: ". \(FoamShell.quote(bashrc.path)) >/dev/null 2>&1 || exit 97",
                                   variables: [:])

        case .directTree:
            var vars: [String: String] = [
                "WM_PROJECT_DIR": location.path,
                "PATH": location.appendingPathComponent("bin").path,
                "FOAM_APPBIN": location.appendingPathComponent("bin").path,
                "FOAM_LIBBIN": location.appendingPathComponent("lib").path,
            ]
            if let v = version { vars["WM_PROJECT_VERSION"] = v }
            let mpi = location.appendingPathComponent("openmpi")
            if fm.fileExists(atPath: mpi.path) {
                vars["PATH"] = location.appendingPathComponent("bin").path + ":" + mpi.appendingPathComponent("bin").path
                vars["OPAL_PREFIX"] = mpi.path
                vars["PRTE_PREFIX"] = mpi.path
            }
            return FoamEnvironment(installation: self, root: location, prelude: "", variables: vars)
        }
    }
}

// MARK: - Probe

/// What a quick health check of an environment found.
public struct FoamProbe: Sendable, Equatable {
    public var ok: Bool
    public var version: String?
    public var hasMPI: Bool
    public var message: String

    public init(ok: Bool, version: String?, hasMPI: Bool, message: String) {
        self.ok = ok
        self.version = version
        self.hasMPI = hasMPI
        self.message = message
    }
}

extension FoamEnvironment {
    /// Run a trivial command through the environment to prove it works and read the
    /// version and MPI availability. Blocking; call off the main thread.
    public func probe() -> FoamProbe {
        let script = (prelude.isEmpty ? "" : prelude + "\n")
            + "echo \"VERSION=${WM_PROJECT_VERSION:-unknown}\"\n"
            + "command -v mpirun >/dev/null 2>&1 && echo MPI=yes || echo MPI=no\n"
            + "command -v blockMesh >/dev/null 2>&1 && echo TOOLS=yes || echo TOOLS=no\n"
        let r = FoamProcessRunner.run(executable: URL(fileURLWithPath: "/bin/bash"),
                                      arguments: ["-c", script],
                                      environment: processEnvironment(), timeout: 60)
        var version: String?
        var mpi = false
        var tools = false
        for line in r.output.split(separator: "\n") {
            if line.hasPrefix("VERSION=") { version = String(line.dropFirst(8)) }
            if line == "MPI=yes" { mpi = true }
            if line == "TOOLS=yes" { tools = true }
        }
        if r.exitCode == 97 {
            return FoamProbe(ok: false, version: nil, hasMPI: false,
                             message: "etc/bashrc could not be sourced.")
        }
        guard r.exitCode == 0, tools else {
            return FoamProbe(ok: false, version: version, hasMPI: mpi,
                             message: "blockMesh is not on the PATH after activating the environment.")
        }
        return FoamProbe(ok: true, version: version == "unknown" ? installation.version : version,
                         hasMPI: mpi,
                         message: "OpenFOAM \(version ?? installation.version ?? "?")"
                                + (mpi ? " · mpirun available" : " · no mpirun (serial only)"))
    }
}
