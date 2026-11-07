import Foundation
import CurlewMesh
import CurlewSolver

/// Physics-informed neural network (PINN) settings: the network, training and physics used to
/// learn a steady incompressible flow (and temperature) field on the case's geometry.
public struct PINNSettings: Codable, Sendable, Equatable {
    public enum Activation: String, Codable, CaseIterable, Sendable { case tanh, silu, gelu, sin }
    public enum Device: String, Codable, CaseIterable, Sendable { case auto, cpu, mps, cuda }
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Equations and boundary conditions only: no solution needed.
        case physics
        /// Equations + boundary conditions + samples of the current (OpenFOAM) solution.
        case hybrid
        /// Fit the current solution only: a fast neural surrogate of it.
        case data

        public var displayName: String {
            switch self {
            case .physics: return "Physics only (PDE + boundary conditions)"
            case .hybrid: return "Hybrid (physics + current solution as data)"
            case .data: return "Surrogate (fit the current solution)"
            }
        }
    }

    public var mode: Mode = .physics
    // network
    public var hiddenLayers = 6
    public var neurons = 64
    public var activation: Activation = .tanh
    /// Random Fourier features of the inputs (0 = off) and their scale.
    public var fourierFeatures = 0
    public var fourierScale = 1.0
    // training
    public var adamEpochs = 10000
    public var learningRate = 1e-3
    /// Learning-rate factor applied every 1000 epochs.
    public var learningRateDecay = 0.8
    public var lbfgsIterations = 2000
    public var interiorBatch = 4096
    public var boundaryBatch = 2048
    public var dataPoints = 4096
    public var weightPDE = 1.0
    public var weightBC = 10.0
    public var weightData = 10.0
    // physics
    /// Solve the energy equation too (when the case has one).
    public var energy = true
    public var device: Device = .auto
    public var seed = 0
    public var logEvery = 100

    public init() {}
}

public struct PINNError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Writes a PINN problem for a case (points, boundary conditions, settings, the PyTorch training
/// script), runs it with a Python interpreter and reads the prediction back as a solution.
public final class PINNJob: @unchecked Sendable {
    public let mesh: Mesh
    public let setup: CaseSetup
    public let settings: PINNSettings
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(mesh: Mesh, setup: CaseSetup, settings: PINNSettings) {
        self.mesh = mesh; self.setup = setup; self.settings = settings
    }

    /// Python used to train: `CURLEW_PYTHON`, then Curlew's preference `curlew.python`, then
    /// the usual install locations. Never read from case files.
    public static var defaultPython: String {
        if let e = ProcessInfo.processInfo.environment["CURLEW_PYTHON"], !e.isEmpty { return e }
        if let p = UserDefaults.standard.string(forKey: "curlew.python"), !p.isEmpty { return p }
        let venv = environmentDirectory.appendingPathComponent("bin/python").path
        if FileManager.default.isExecutableFile(atPath: venv) { return venv }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/python3"
    }

    /// Virtual environment Curlew can create for training (PyTorch + NumPy).
    public static var environmentDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CurlewFoam/pinn-env")
    }

    /// Result of checking an interpreter for PyTorch.
    public struct EnvironmentStatus: Sendable, Equatable {
        public var ok: Bool
        public var python: String
        public var text: String
    }

    /// Run a short program with `python` (no shell); returns (exit code, combined output).
    static func runPython(_ python: String, _ args: [String], timeout: TimeInterval = 120, log: ((String) -> Void)? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // apps started from Finder get a minimal PATH; pip and venv want the usual tools
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var out = ""
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            let t = String(decoding: d, as: UTF8.self)
            lock.lock(); out += t; lock.unlock()
            if let log { for l in t.split(separator: "\n") where !l.isEmpty { log(String(l)) } }
        }
        do { try p.run() } catch { return (-1, "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); lock.lock(); out += "\n(timed out after \(Int(timeout)) s)"; lock.unlock() }
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); defer { lock.unlock() }
        return (p.terminationStatus, out)
    }

    /// Does `python` import PyTorch and NumPy? Reports versions and the GPU backend.
    public static func checkEnvironment(python: String) -> EnvironmentStatus {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            return EnvironmentStatus(ok: false, python: python, text: "No Python at \(python).")
        }
        let code = "import sys\ntry:\n import torch, numpy\n print('Python %s, PyTorch %s, NumPy %s, Apple GPU (MPS) %s' % (sys.version.split()[0], torch.__version__, numpy.__version__, 'yes' if torch.backends.mps.is_available() else 'no'))\nexcept Exception as e:\n print('Python %s: %s' % (sys.version.split()[0], e)); sys.exit(4)\n"
        let (status, out) = runPython(python, ["-c", code], timeout: 120)
        let line = out.split(separator: "\n").last.map(String.init) ?? out
        return EnvironmentStatus(ok: status == 0, python: python, text: line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A python3 to build the environment from: 3.10 or newer (what PyTorch supports).
    public static func basePython() -> String? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            let (st, out) = runPython(c, ["-c", "import sys; print(sys.version_info[0]*100+sys.version_info[1])"], timeout: 60)
            if st == 0, let v = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 310 { return c }
        }
        return nil
    }

    /// Create (or repair) `directory` as a virtual environment and install PyTorch and NumPy
    /// (downloads several hundred MB from the Python Package Index), then check the import.
    /// Blocking; returns the environment's interpreter. Only run when the user asks for it.
    public static func createEnvironment(base: String? = nil, directory: URL = environmentDirectory,
                                         log: @escaping (String) -> Void) throws -> String {
        guard let base = base ?? basePython() else {
            throw PINNError("No Python 3.10 or newer found. Install one (e.g. `brew install python`, or python.org) and try again.")
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        func step(_ title: String, _ exe: String, _ args: [String], timeout: TimeInterval) throws {
            log("— \(title)")
            let (status, out) = runPython(exe, args, timeout: timeout, log: log)
            guard status == 0 else {
                let tail = out.split(separator: "\n").suffix(12).joined(separator: "\n")
                throw PINNError("\(title) failed (exit \(status)):\n\(tail)")
            }
        }
        let py = directory.appendingPathComponent("bin/python").path
        // a missing or broken environment (no interpreter, or no pip) is rebuilt from scratch
        let healthy = FileManager.default.isExecutableFile(atPath: py) && runPython(py, ["-m", "pip", "--version"], timeout: 60).0 == 0
        if !healthy {
            try step("Create the environment with \(base)", base, ["-m", "venv", "--clear", directory.path], timeout: 300)
        }
        try step("Update pip", py, ["-m", "pip", "install", "--upgrade", "pip"], timeout: 600)
        try step("Install PyTorch and NumPy", py, ["-m", "pip", "install", "--upgrade", "torch", "numpy"], timeout: 3600)
        let check = checkEnvironment(python: py)
        log(check.text)
        guard check.ok else { throw PINNError("PyTorch was installed but does not import: \(check.text)") }
        return py
    }

    public static func defaultDirectory(for setup: CaseSetup) -> URL {
        let t = String((setup.title.isEmpty ? "case" : setup.title).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CurlewFoam/pinn-\(t)")
    }

    public struct Summary: Sendable {
        public var interiorPoints: Int
        public var boundaryPoints: Int
        public var dataPoints: Int
        public var dimensions: Int
        public var reynolds: Double
        public var energy: Bool
        public var text: String {
            String(format: "PINN problem: %d interior points, %d boundary points, %d data points, %dD, Re = %.4g on the domain half-size%@",
                   interiorPoints, boundaryPoints, dataPoints, dimensions, reynolds, energy ? ", with energy" : "")
        }
    }

    /// Write config.json, points.csv, boundary.csv, data.csv (hybrid/surrogate) and train.py.
    /// `solution` supplies the data points (required for hybrid and surrogate modes).
    @discardableResult
    public func prepare(in dir: URL, solution: PressureBasedSolver?) throws -> Summary {
        let m = mesh, s = setup
        if s.cellZones.values.contains(where: { $0.kind == .solid }) {
            throw PINNError("The PINN module solves fluid regions only; this case has solid zones (conjugate heat transfer). Use the OpenFOAM solution, or its surrogate after removing the solids.")
        }
        if settings.mode != .physics && solution == nil {
            throw PINNError("\(settings.mode.displayName) needs a solution: calculate the case first (OpenFOAM), or use physics-only mode.")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // reference scales: centre and half-size of the domain, reference velocity and properties
        let (lo, hi) = (m.bounds.min, m.bounds.max)
        let centre = 0.5 * (lo + hi)
        let axes = (0..<3).filter { $0 != m.twoDimensionalAxis }
        let L = max(axes.map { 0.5 * (hi[$0] - lo[$0]) }.max() ?? 1, 1e-12)
        let fluidZone = s.cellZones.values.first { $0.kind == .fluid }
        guard let mat = s.material(named: fluidZone?.material ?? "air") ?? MaterialLibrary.lookup("air") else { throw PINNError("no fluid material") }
        let starter = try PressureBasedSolver(mesh: m, setup: s)
        let bc = starter.bc
        var Uref = s.reference.velocity
        let inletSpeed = (0..<bc.nB).filter { bc.kind[$0] == .velocityInlet || bc.kind[$0] == .farField }.map { norm(bc.uSpec[$0]) }.max() ?? 0
        let wallSpeed = (0..<bc.nB).filter { bc.kind[$0] == .wall }.map { norm(bc.uSpec[$0]) }.max() ?? 0
        if inletSpeed > 0 { Uref = inletSpeed } else if wallSpeed > 0 { Uref = wallSpeed }
        Uref = max(Uref, 1e-9)
        let Re = mat.density * Uref * L / max(mat.viscosity, 1e-30)
        let energy = settings.energy && s.models.energy
        let Pr = mat.viscosity * mat.specificHeat / max(mat.thermalConductivity, 1e-30)
        var Tmin = s.initialization.temperature.constantValue ?? 300, Tmax = Tmin
        for bf in 0..<bc.nB where bc.thermal.kind[bf] == .fixedValue { Tmin = min(Tmin, bc.thermal.value[bf]); Tmax = max(Tmax, bc.thermal.value[bf]) }
        var dT = max(Tmax - Tmin, 1)
        // heat-flux walls set the temperature scale q L / k when no temperatures differ
        let qmax = (0..<bc.nB).filter { bc.thermal.kind[$0] == .fixedFlux }.map { abs(bc.thermal.coeff[$0]) }.max() ?? 0
        if Tmax - Tmin < 1e-9, qmax > 0 { dT = qmax * L / max(mat.thermalConductivity, 1e-30) }

        func fmt(_ v: Double) -> String { String(format: "%.9g", v) }
        // interior points: every fluid cell centre (training samples batches of them)
        var pts = "x,y,z\n"
        var nInt = 0
        for c in 0..<m.nCells {
            let p = m.cellCentres[c]
            pts += "\(fmt(p.x)),\(fmt(p.y)),\(fmt(p.z))\n"; nInt += 1
        }
        try pts.write(to: dir.appendingPathComponent("points.csv"), atomically: true, encoding: .utf8)
        // boundary points: face centres, outward normals, the condition and its values
        // type: 0 velocity (inlet, far field), 1 pressure (outlets, pressure inlets), 2 no-slip wall
        // (velocity given), 3 slip/symmetry (u·n = 0), 4 zero-gradient (outflow)
        // ttype: 0 none, 1 fixed T, 2 adiabatic, 3 heat flux q [W/m²] (into the fluid), 4 convection h, T∞
        var bcs = "x,y,z,nx,ny,nz,type,u,v,w,p,ttype,T,q,h\n"
        var nB = 0
        let nI = m.nInternalFaces
        for bf in 0..<bc.nB {
            let f = nI + bf
            let type: Int
            switch bc.kind[bf] {
            case .empty: continue
            case .velocityInlet, .farField: type = 0
            case .pressureInlet, .pressureOutlet: type = 1
            case .wall: type = 2
            case .slipWall, .symmetry: type = 3
            case .outflow: type = 4
            }
            let p = m.faceCentres[f], n = m.faceAreas[f] / max(m.faceAreaMag[f], 1e-300), u = bc.uSpec[bf]
            var tt = 0, T = 0.0, q = 0.0, h = 0.0
            if energy {
                switch bc.thermal.kind[bf] {
                case .fixedValue: tt = 1; T = bc.thermal.value[bf]
                case .zeroGradient, .none: tt = (type == 2 || type == 3 || type == 4 || type == 1) ? 2 : 0
                case .fixedFlux: tt = 3; q = bc.thermal.coeff[bf]
                case .robin: tt = 4; h = bc.thermal.coeff[bf]; T = bc.thermal.value[bf]
                }
            }
            bcs += [p.x, p.y, p.z, n.x, n.y, n.z].map(fmt).joined(separator: ",") + ",\(type)," + [u.x, u.y, u.z, bc.pSpec[bf]].map(fmt).joined(separator: ",")
                + ",\(tt)," + [T, q, h].map(fmt).joined(separator: ",") + "\n"
            nB += 1
        }
        guard nB > 0 else { throw PINNError("the case has no boundary conditions to train against") }
        try bcs.write(to: dir.appendingPathComponent("boundary.csv"), atomically: true, encoding: .utf8)
        // data points from the current solution (uniform random sample of cells)
        var nData = 0
        let dataURL = dir.appendingPathComponent("data.csv")
        if settings.mode != .physics, let sol = solution {
            var rng = SplitMix(seed: UInt64(max(0, settings.seed)) &+ 12345)
            let want = min(m.nCells, max(1, settings.dataPoints))
            var cells = Array(0..<m.nCells)
            for i in 0..<want { let j = i + Int(rng.next() % UInt64(cells.count - i)); cells.swapAt(i, j) }
            var d = "x,y,z,u,v,w,p,T\n"
            for c in cells.prefix(want) {
                let p = m.cellCentres[c], u = sol.state.u[c]
                d += [p.x, p.y, p.z, u.x, u.y, u.z, sol.state.p[c], sol.state.T[c]].map(fmt).joined(separator: ",") + "\n"
            }
            try d.write(to: dataURL, atomically: true, encoding: .utf8)
            nData = want
        } else {
            try? FileManager.default.removeItem(at: dataURL)
        }
        // settings (JSON only: the script reads numbers and names, nothing is executed)
        let cfg: [String: Any] = [
            "axes": axes, "centre": [centre.x, centre.y, centre.z], "L": L, "U": Uref,
            "rho": mat.density, "mu": mat.viscosity, "k": mat.thermalConductivity, "cp": mat.specificHeat,
            "Re": Re, "Pr": Pr, "T0": Tmin, "dT": dT, "energy": energy, "mode": settings.mode.rawValue,
            "hidden_layers": max(1, settings.hiddenLayers), "neurons": max(4, settings.neurons), "activation": settings.activation.rawValue,
            "fourier_features": max(0, settings.fourierFeatures), "fourier_scale": settings.fourierScale,
            "adam_epochs": max(0, settings.adamEpochs), "lr": settings.learningRate, "lr_decay": settings.learningRateDecay,
            "lbfgs_iterations": max(0, settings.lbfgsIterations),
            "interior_batch": max(16, settings.interiorBatch), "boundary_batch": max(16, settings.boundaryBatch),
            "w_pde": settings.weightPDE, "w_bc": settings.weightBC, "w_data": settings.weightData,
            "device": settings.device.rawValue, "seed": settings.seed, "log_every": max(1, settings.logEvery),
        ]
        let json = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("config.json"))
        try PINNJob.script.write(to: dir.appendingPathComponent("train.py"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("prediction.csv"))
        return Summary(interiorPoints: nInt, boundaryPoints: nB, dataPoints: nData, dimensions: axes.count, reynolds: Re, energy: energy)
    }

    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        p?.terminate()
    }

    /// Train (blocking). `progress` gets (epoch, total loss) from the script's progress lines.
    public func run(python: String, in dir: URL, log: @escaping (String) -> Void,
                    progress: @escaping (Int, Double) -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw PINNError("Python not found at \(python). Set it in Settings › Machine learning (or CURLEW_PYTHON).")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", dir.appendingPathComponent("train.py").path, dir.path]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let logHandle = FileManager.default.createFile(atPath: dir.appendingPathComponent("log.train").path, contents: nil)
            ? try? FileHandle(forWritingTo: dir.appendingPathComponent("log.train")) : nil
        var buffer = Data()
        var missingTorch = false
        let logEvery = settings.logEvery
        let done = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; done.signal(); return }
            logHandle?.write(d)
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                if line.hasPrefix("CURLEW-PROGRESS ") {
                    let w = line.split(separator: " ")
                    if w.count >= 3, let e = Int(w[1]), let l = Double(w[2]) { progress(e, l) }
                }
                if line.contains("CURLEW-NO-TORCH") { missingTorch = true }
                if !line.hasPrefix("CURLEW-PROGRESS ") || (Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0) % (logEvery * 10) == 0 {
                    log(line)
                }
            }
        }
        lock.lock()
        if cancelled { lock.unlock(); throw PINNError("cancelled") }
        process = p
        lock.unlock()
        try p.run()
        p.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        try? logHandle?.close()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw PINNError("cancelled") }
        if missingTorch {
            throw PINNError("PyTorch and NumPy are not installed for \(python). Use Settings › Machine Learning › Set Up PyTorch Environment, or in a terminal: python3 -m venv \(PINNJob.environmentDirectory.path) && \(PINNJob.environmentDirectory.path)/bin/pip install torch numpy — then choose \(PINNJob.environmentDirectory.path)/bin/python as the Python.")
        }
        guard p.terminationStatus == 0 else { throw PINNError("training failed (exit \(p.terminationStatus)); see \(dir.appendingPathComponent("log.train").path)") }
    }

    /// Read prediction.csv (u, v, w, p, T per cell, in mesh order) into a Curlew solution.
    public static func load(from dir: URL, mesh: Mesh, setup: CaseSetup) throws -> PressureBasedSolver {
        let text = try String(contentsOf: dir.appendingPathComponent("prediction.csv"), encoding: .utf8)
        var u: [Vec3] = [], p: [Double] = [], T: [Double] = []
        u.reserveCapacity(mesh.nCells); p.reserveCapacity(mesh.nCells); T.reserveCapacity(mesh.nCells)
        for line in text.split(separator: "\n").dropFirst() {
            let v = line.split(separator: ",").compactMap { Double($0) }
            guard v.count >= 5 else { continue }
            u.append(Vec3(v[0], v[1], v[2])); p.append(v[3]); T.append(v.count > 4 ? v[4] : 300)
        }
        guard u.count == mesh.nCells else { throw PINNError("prediction.csv has \(u.count) rows for \(mesh.nCells) cells") }
        let solver = try PressureBasedSolver(mesh: mesh, setup: setup)
        solver.log = { _ in }
        try solver.initialize()
        var e = ExternalSolution(u: u, p: p)
        if setup.models.energy { e.T = T }
        try solver.load(external: e)
        return solver
    }

    // MARK: Training script

    /// Steady incompressible Navier–Stokes (and convection–diffusion of temperature) in
    /// non-dimensional form, x* = (x - c)/L, u* = u/U, p* = p/(ρU²), T* = (T - T0)/ΔT:
    ///   ∇·u = 0,  (u·∇)u + ∇p − ∇²u/Re = 0,  u·∇T − ∇²T/(Re Pr) = 0.
    static let script = #"""
    # Physics-informed neural network written by Curlew. Reads config.json, points.csv,
    # boundary.csv and data.csv from the folder given as the first argument; writes
    # prediction.csv (u, v, w, p, T at every cell centre) and model.pt.
    import json, math, os, sys, time
    try:
        import numpy as np
        import torch
    except ImportError as e:
        print("CURLEW-NO-TORCH: %s (install PyTorch and NumPy for %s)" % (e, sys.executable), flush=True)
        sys.exit(3)

    work = sys.argv[1] if len(sys.argv) > 1 else "."
    cfg = json.load(open(os.path.join(work, "config.json")))
    torch.manual_seed(int(cfg["seed"])); np.random.seed(int(cfg["seed"]))

    def pick_device(name):
        if name == "cuda" or (name == "auto" and torch.cuda.is_available()):
            return torch.device("cuda")
        if name == "mps" or (name == "auto" and getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()):
            return torch.device("mps")
        return torch.device("cpu")
    dev = pick_device(cfg["device"])
    dtype = torch.float32
    print("device:", dev, flush=True)

    axes = cfg["axes"]; dim = len(axes)
    c0 = np.array(cfg["centre"]); L = cfg["L"]; U = cfg["U"]; rho = cfg["rho"]
    Re = cfg["Re"]; Pr = cfg["Pr"]; T0 = cfg["T0"]; dT = cfg["dT"]; k_th = cfg["k"]
    energy = bool(cfg["energy"]); mode = cfg["mode"]

    def load(name):
        path = os.path.join(work, name)
        if not os.path.exists(path):
            return None
        a = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
        return a

    P = load("points.csv"); B = load("boundary.csv"); D = load("data.csv")
    def nd_x(xyz):
        return ((xyz - c0) / L)[:, axes]
    Xi = torch.tensor(nd_x(P[:, 0:3]), dtype=dtype, device=dev)
    Xb = torch.tensor(nd_x(B[:, 0:3]), dtype=dtype, device=dev)
    Nb = torch.tensor(B[:, 3:6][:, axes], dtype=dtype, device=dev)
    btype = torch.tensor(B[:, 6], dtype=torch.long, device=dev)
    Ub = torch.tensor(B[:, 7:10][:, axes] / U, dtype=dtype, device=dev)
    Pb = torch.tensor(B[:, 10] / (rho * U * U), dtype=dtype, device=dev)
    ttype = torch.tensor(B[:, 11], dtype=torch.long, device=dev)
    Tb = torch.tensor((B[:, 12] - T0) / dT, dtype=dtype, device=dev)
    qb = torch.tensor(B[:, 13] * L / (k_th * dT), dtype=dtype, device=dev)      # -dT*/dn* = q*
    hb = torch.tensor(B[:, 14] * L / k_th, dtype=dtype, device=dev)             # Biot number
    if D is not None and mode != "physics":
        Xd = torch.tensor(nd_x(D[:, 0:3]), dtype=dtype, device=dev)
        Ud = torch.tensor(D[:, 3:6][:, axes] / U, dtype=dtype, device=dev)
        Pd = torch.tensor(D[:, 6] / (rho * U * U), dtype=dtype, device=dev)
        Td = torch.tensor((D[:, 7] - T0) / dT, dtype=dtype, device=dev)
    else:
        Xd = None

    class Sine(torch.nn.Module):
        def forward(self, x):
            return torch.sin(x)
    acts = {"tanh": torch.nn.Tanh, "silu": torch.nn.SiLU, "gelu": torch.nn.GELU, "sin": Sine}
    nout = dim + 1 + (1 if energy else 0)

    class Net(torch.nn.Module):
        def __init__(self):
            super().__init__()
            nf = int(cfg["fourier_features"])
            self.register_buffer("B", torch.randn(dim, nf) * float(cfg["fourier_scale"]) if nf > 0 else torch.zeros(dim, 0))
            nin = dim + 2 * nf
            layers = []
            for i in range(int(cfg["hidden_layers"])):
                layers += [torch.nn.Linear(nin if i == 0 else int(cfg["neurons"]), int(cfg["neurons"])), acts[cfg["activation"]]()]
            layers.append(torch.nn.Linear(int(cfg["neurons"]), nout))
            self.net = torch.nn.Sequential(*layers)
        def forward(self, x):
            if self.B.shape[1] > 0:
                xb = 2 * math.pi * x @ self.B
                x = torch.cat([x, torch.sin(xb), torch.cos(xb)], dim=1)
            return self.net(x)

    model = Net().to(dev)

    def grad(y, x):
        return torch.autograd.grad(y, x, torch.ones_like(y), create_graph=True)[0]

    def pde_loss(x):
        x = x.clone().requires_grad_(True)
        out = model(x)
        u = [out[:, i:i + 1] for i in range(dim)]
        p = out[:, dim:dim + 1]
        gu = [grad(ui, x) for ui in u]
        gp = grad(p, x)
        cont = sum(gu[i][:, i:i + 1] for i in range(dim))
        res = [cont]
        for i in range(dim):
            conv = sum(u[j] * gu[i][:, j:j + 1] for j in range(dim))
            lap = sum(grad(gu[i][:, j:j + 1], x)[:, j:j + 1] for j in range(dim))
            res.append(conv + gp[:, i:i + 1] - lap / Re)
        if energy:
            T = out[:, dim + 1:dim + 2]
            gT = grad(T, x)
            conv = sum(u[j] * gT[:, j:j + 1] for j in range(dim))
            lap = sum(grad(gT[:, j:j + 1], x)[:, j:j + 1] for j in range(dim))
            res.append(conv - lap / (Re * Pr))
        return sum((r ** 2).mean() for r in res)

    def bc_loss(idx):
        x = Xb[idx].clone().requires_grad_(True)
        out = model(x)
        u = out[:, 0:dim]; p = out[:, dim]
        t = btype[idx]; n = Nb[idx]
        loss = torch.zeros((), device=dev)
        m = (t == 0) | (t == 2)
        if m.any(): loss = loss + ((u[m] - Ub[idx][m]) ** 2).sum(1).mean()
        m = t == 1
        if m.any(): loss = loss + ((p[m] - Pb[idx][m]) ** 2).mean()
        m = t == 3
        if m.any(): loss = loss + ((u[m] * n[m]).sum(1) ** 2).mean()
        if energy:
            T = out[:, dim + 1]
            gT = grad(out[:, dim + 1:dim + 2], x)
            dTdn = (gT * n).sum(1)
            tt = ttype[idx]
            mm = tt == 1
            if mm.any(): loss = loss + ((T[mm] - Tb[idx][mm]) ** 2).mean()
            mm = tt == 2
            if mm.any(): loss = loss + (dTdn[mm] ** 2).mean()
            mm = tt == 3          # q into the fluid: -k dT/dn (n outward) = -q  =>  dT*/dn* = q*
            if mm.any(): loss = loss + ((dTdn[mm] - qb[idx][mm]) ** 2).mean()
            mm = tt == 4          # convection: -dT*/dn* = Bi (T* - T∞*)
            if mm.any(): loss = loss + ((dTdn[mm] + hb[idx][mm] * (T[mm] - Tb[idx][mm])) ** 2).mean()
        return loss

    def data_loss():
        out = model(Xd)
        l = ((out[:, 0:dim] - Ud) ** 2).sum(1).mean() + ((out[:, dim] - Pd) ** 2).mean()
        if energy: l = l + ((out[:, dim + 1] - Td) ** 2).mean()
        return l

    nI, nB = Xi.shape[0], Xb.shape[0]
    bi, bb = min(int(cfg["interior_batch"]), nI), min(int(cfg["boundary_batch"]), nB)
    wp = 0.0 if mode == "data" else float(cfg["w_pde"]); wb = 0.0 if mode == "data" else float(cfg["w_bc"])
    wd = float(cfg["w_data"]) if Xd is not None else 0.0

    def total(ii, ib):
        parts = {}
        loss = torch.zeros((), device=dev)
        if wp > 0: parts["pde"] = pde_loss(Xi[ii]); loss = loss + wp * parts["pde"]
        if wb > 0: parts["bc"] = bc_loss(ib); loss = loss + wb * parts["bc"]
        if wd > 0: parts["data"] = data_loss(); loss = loss + wd * parts["data"]
        return loss, parts

    opt = torch.optim.Adam(model.parameters(), lr=float(cfg["lr"]))
    sched = torch.optim.lr_scheduler.StepLR(opt, step_size=1000, gamma=float(cfg["lr_decay"]))
    t0 = time.time(); every = int(cfg["log_every"]); epoch = 0
    for epoch in range(1, int(cfg["adam_epochs"]) + 1):
        ii = torch.randint(0, nI, (bi,), device=dev); ib = torch.randint(0, nB, (bb,), device=dev)
        opt.zero_grad()
        loss, parts = total(ii, ib)
        loss.backward(); opt.step(); sched.step()
        if epoch % every == 0 or epoch == 1:
            print("CURLEW-PROGRESS %d %.6e %s  (%.0f s)" % (epoch, loss.item(), " ".join("%s=%.3e" % (k, v.item()) for k, v in parts.items()), time.time() - t0), flush=True)

    if int(cfg["lbfgs_iterations"]) > 0:
        ii = torch.randint(0, nI, (min(nI, 4 * bi),), device=dev); ib = torch.randint(0, nB, (min(nB, 4 * bb),), device=dev)
        lb = torch.optim.LBFGS(model.parameters(), lr=1.0, max_iter=int(cfg["lbfgs_iterations"]), history_size=50, line_search_fn="strong_wolfe")
        def closure():
            lb.zero_grad()
            l, _ = total(ii, ib)
            l.backward()
            return l
        l = lb.step(closure)
        print("CURLEW-PROGRESS %d %.6e lbfgs  (%.0f s)" % (epoch + 1, l.item(), time.time() - t0), flush=True)

    # prediction at every cell centre, in mesh order, dimensional
    model.eval()
    rows = []
    with torch.no_grad():
        for s in range(0, nI, 65536):
            out = model(Xi[s:s + 65536]).cpu().numpy()
            uvw = np.zeros((out.shape[0], 3)); uvw[:, axes] = out[:, 0:dim] * U
            p = out[:, dim] * rho * U * U
            T = (out[:, dim + 1] * dT + T0) if energy else np.full(out.shape[0], T0)
            rows.append(np.column_stack([uvw, p, T]))
    np.savetxt(os.path.join(work, "prediction.csv"), np.vstack(rows), delimiter=",", header="u,v,w,p,T", comments="", fmt="%.8g")
    torch.save(model.state_dict(), os.path.join(work, "model.pt"))
    print("CURLEW-DONE prediction.csv written (%.0f s)" % (time.time() - t0), flush=True)
    """#
}

/// Small deterministic generator for sampling data points.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
