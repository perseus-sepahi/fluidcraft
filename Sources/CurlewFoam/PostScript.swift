import Foundation
import CurlewMesh
import CurlewSolver

// MARK: - Python post-processing interface
//
// OpenFOAM computes derived fields, samples and surfaces (function objects, exprField). What it
// has no interface for is free-form analysis of a finished solution: arbitrary NumPy on every
// field, plots, custom reports, combining function-object output. Curlew exports the chosen
// time of the case as NumPy arrays (cells, patch faces, every volume field) and runs the user's
// Python script with the `curlew_post` module, which reads them, sends reports back to Curlew,
// saves figures and can write new fields into the case for OpenFOAM, ParaView and Curlew.

public struct PostScriptReport: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var value: Double
    public var unit: String
}

public struct PostScriptResult: Sendable {
    public var exitCode: Int32
    public var reports: [PostScriptReport] = []
    public var figures: [URL] = []
    /// Fields the script wrote into the time directory.
    public var fields: [String] = []
    public var log: [String] = []
    public var outputDirectory: URL
    public var time: String
    public var seconds: Double = 0
    public var succeeded: Bool { exitCode == 0 }
}

public struct PostScriptError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ d: String) { description = d }
    public var errorDescription: String? { description }
}

/// Exports a time directory of an OpenFOAM case as NumPy arrays plus `manifest.json`.
public enum PostScriptExport {
    /// - Parameters:
    ///   - caseDirectory: an OpenFOAM case (single region).
    ///   - time: time directory name; nil = the latest.
    ///   - setup: the Curlew setup when the case came from Curlew (pressure units, density).
    /// - Returns: the data directory and the exported time.
    @discardableResult
    public static func export(caseDirectory dir: URL, time: String? = nil, setup: CaseSetup? = nil, to dataDir: URL) throws -> (URL, String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path) else {
            throw PostScriptError("\(dir.path) is not an OpenFOAM case (no system/controlDict)")
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("constant/regionProperties").path) {
            throw PostScriptError("multi-region (conjugate) cases are not supported by the Python interface yet")
        }
        let times = FoamTimes.list(dir)
        guard let t = time.map({ name in times.first { $0.name == name } }) ?? times.last.map({ Optional($0) }), let tt = t else {
            throw PostScriptError(time.map { "no time directory \($0) in \(dir.path)" } ?? "no time directories in \(dir.path): run the case first")
        }
        let tdir = dir.appendingPathComponent(tt.name)
        // a refined mesh lives in the time directory
        let meshURL = fm.fileExists(atPath: tdir.appendingPathComponent("polyMesh/faces").path) || fm.fileExists(atPath: tdir.appendingPathComponent("polyMesh/faces.gz").path)
            ? tdir.appendingPathComponent("polyMesh") : dir
        let mesh = try FoamMeshReader.read(url: meshURL, preserveOrder: true)
        let boundaryTypes = Self.boundaryTypes(meshURL == dir ? dir.appendingPathComponent("constant/polyMesh/boundary") : meshURL.appendingPathComponent("boundary"))

        try? fm.removeItem(at: dataDir)
        for sub in ["geom", "fields", "patches"] { try fm.createDirectory(at: dataDir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        func npy(_ rel: String, _ v: [Double], _ shape: [Int]) throws { try NPY.write(dataDir.appendingPathComponent(rel), values: v, shape: shape) }

        let nC = mesh.nCells
        try npy("geom/C.npy", mesh.cellCentres.flatMap { [$0.x, $0.y, $0.z] }, [nC, 3])
        try npy("geom/V.npy", mesh.cellVolumes, [nC])
        var patches: [[String: Any]] = []
        for (i, z) in mesh.boundaryZones.enumerated() {
            let r = z.faceRange
            try npy("geom/p\(i)_Cf.npy", r.flatMap { [mesh.faceCentres[$0].x, mesh.faceCentres[$0].y, mesh.faceCentres[$0].z] }, [z.count, 3])
            try npy("geom/p\(i)_Sf.npy", r.flatMap { [mesh.faceAreas[$0].x, mesh.faceAreas[$0].y, mesh.faceAreas[$0].z] }, [z.count, 3])
            try npy("geom/p\(i)_cells.npy", r.map { Double(mesh.owner[$0]) }, [z.count])
            patches.append(["name": z.name, "type": boundaryTypes[z.name] ?? z.kind.rawValue, "nFaces": z.count, "index": i])
        }

        var fields: [String: Any] = [:]
        let names = ((try? fm.contentsOfDirectory(atPath: tdir.path)) ?? []).sorted()
        for raw in names {
            let name = raw.hasSuffix(".gz") ? String(raw.dropLast(3)) : raw
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: tdir.appendingPathComponent(raw).path, isDirectory: &isDir), !isDir.boolValue,
                  !name.hasPrefix("."), fields[name] == nil else { continue }
            guard let f = try? FoamFieldReader.read(url: tdir.appendingPathComponent(name)) else { continue }
            let comps: Int
            switch f.className {
            case "volScalarField": comps = 1
            case "volVectorField": comps = 3
            case "volSymmTensorField": comps = 6
            case "volTensorField": comps = 9
            default: continue
            }
            guard let internalData = f.internalField, let internalValues = expand(internalData, count: nC, comps: comps) else { continue }
            let safe = fileSafe(name)
            try npy("fields/\(safe).npy", internalValues, comps == 1 ? [nC] : [nC, comps])
            var pfiles: [String: String] = [:]
            for (i, z) in mesh.boundaryZones.enumerated() {
                var vals: [Double]
                if let pv = f.patchValues[z.name], let e = expand(pv, count: z.count, comps: comps) { vals = e }
                else {
                    // no value written (zeroGradient, constraint types): the adjacent cell values
                    vals = []; vals.reserveCapacity(z.count * comps)
                    for face in z.faceRange { let c = Int(mesh.owner[face]); vals.append(contentsOf: internalValues[(c * comps)..<(c * comps + comps)]) }
                }
                let rel = "patches/\(safe)_p\(i).npy"
                try npy(rel, vals, comps == 1 ? [z.count] : [z.count, comps])
                pfiles[z.name] = rel
            }
            fields[name] = ["class": f.className, "components": comps, "file": "fields/\(safe).npy", "patches": pfiles]
        }

        var manifest: [String: Any] = [
            "case": dir.path, "time": tt.name, "timeValue": tt.value, "times": times.map(\.name),
            "nCells": nC, "patches": patches, "fields": fields,
            "cells": ["centres": "geom/C.npy", "volumes": "geom/V.npy"],
        ]
        let thermalCase = fm.fileExists(atPath: dir.appendingPathComponent("constant/thermophysicalProperties").path)
        manifest["kinematicPressure"] = !thermalCase
        if let s = setup {
            let app = FoamCaseWriter.resolvedApplication(s)
            manifest["kinematicPressure"] = !app.isThermal
            manifest["density"] = FoamCaseWriter.fluidMaterial(s)?.density ?? s.reference.density
            manifest["operatingPressure"] = s.general.operatingPressure
            manifest["application"] = app.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dataDir.appendingPathComponent("manifest.json"))
        return (dataDir, tt.name)
    }

    static func expand(_ d: FoamFieldData, count n: Int, comps: Int) -> [Double]? {
        switch d {
        case .uniform(let v):
            guard v.count == comps else { return nil }
            var out: [Double] = []; out.reserveCapacity(n * comps)
            for _ in 0..<n { out.append(contentsOf: v) }
            return out
        case .list(let v, let c):
            return c == comps && v.count == n * comps ? v : nil
        }
    }

    static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    /// Patch name → OpenFOAM patch type from a polyMesh/boundary file.
    static func boundaryTypes(_ url: URL) -> [String: String] {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"([A-Za-z0-9_.:\-]+)\s*\{[^{}]*?\btype\s+([A-Za-z0-9_:]+)\s*;"#)
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            if let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t) { out[String(t[a])] = String(t[b]) }
        }
        return out
    }
}

/// Minimal NumPy `.npy` (format 1.0, little-endian float64) writer.
enum NPY {
    static func write(_ url: URL, values: [Double], shape: [Int]) throws {
        let shapeText = shape.count == 1 ? "(\(shape[0]),)" : "(" + shape.map(String.init).joined(separator: ", ") + ")"
        var header = "{'descr': '<f8', 'fortran_order': False, 'shape': \(shapeText), }"
        let unpadded = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - unpadded % 64) % 64) + "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let len = UInt16(header.utf8.count)
        d.append(contentsOf: [UInt8(len & 0xff), UInt8(len >> 8)])
        d.append(Data(header.utf8))
        values.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }     // arm64/x86_64 are little-endian
        try d.write(to: url)
    }
}

/// One run of a post-processing script; `cancel()` stops it.
public final class PostScriptRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        p?.terminate()
    }

    /// Exports the case at `time`, writes the `curlew_post` module and the script into
    /// `<case>/curlew-post/`, and runs `python` (never through a shell). Blocking.
    public func run(_ script: FoamPostScript, caseDirectory dir: URL, time: String? = nil, setup: CaseSetup? = nil,
                    python: String = PINNJob.defaultPython, timeout: TimeInterval = 3600,
                    log: @escaping (String) -> Void = { _ in }) throws -> PostScriptResult {
        let t0 = Date()
        let fm = FileManager.default
        guard !script.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PostScriptError("script \(script.name) is empty") }
        guard fm.isExecutableFile(atPath: python) else { throw PostScriptError("no Python at \(python) (Settings › Machine Learning sets the interpreter)") }
        let root = dir.appendingPathComponent("curlew-post")
        let lib = root.appendingPathComponent("lib"), scripts = root.appendingPathComponent("scripts")
        let base = (script.fileName as NSString).deletingPathExtension
        let out = root.appendingPathComponent("out/\(base)")
        for d in [lib, scripts] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        log("Exporting the solution for Python…")
        let (data, t) = try PostScriptExport.export(caseDirectory: dir, time: time, setup: setup, to: root.appendingPathComponent("data"))
        try PostScriptModule.source.write(to: lib.appendingPathComponent("curlew_post.py"), atomically: true, encoding: .utf8)
        let scriptURL = scripts.appendingPathComponent(script.fileName)
        try script.code.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        // -I: isolated (no PYTHONPATH, user site or script directory on sys.path); the module
        // directory is added explicitly and the script runs as __main__
        p.arguments = ["-I", "-u", "-c", "import sys, runpy; sys.path.insert(0, sys.argv[1]); sys.argv = [sys.argv[2]]; runpy.run_path(sys.argv[0], run_name='__main__')",
                       lib.path, scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + (env["PATH"].map { ":" + $0 } ?? "")
        env["CURLEW_POST_DATA"] = data.path
        env["CURLEW_POST_OUT"] = out.path
        env["CURLEW_CASE"] = dir.path
        env["MPLBACKEND"] = "Agg"
        env["MPLCONFIGDIR"] = root.appendingPathComponent(".matplotlib").path
        p.environment = env
        p.currentDirectoryURL = out
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice

        var result = PostScriptResult(exitCode: -1, outputDirectory: out, time: t)
        let rlock = NSLock()
        var pending = ""
        func handle(_ line: String) {
            if line.hasPrefix("CURLEW_REPORT "), let d = line.dropFirst(14).data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let n = j["name"] as? String, let v = j["value"] as? Double {
                result.reports.removeAll { $0.name == n }
                result.reports.append(PostScriptReport(name: n, value: v, unit: j["unit"] as? String ?? ""))
                log(String(format: "%@ = %.6g %@", n, v, j["unit"] as? String ?? ""))
            } else if line.hasPrefix("CURLEW_FIGURE "), let d = line.dropFirst(14).data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let path = j["path"] as? String {
                let u = URL(fileURLWithPath: path)
                if u.path.hasPrefix(out.path) && !result.figures.contains(u) { result.figures.append(u) }
                log("Figure \(u.lastPathComponent)")
            } else if line.hasPrefix("CURLEW_FIELD "), let d = line.dropFirst(13).data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let n = j["name"] as? String {
                if !result.fields.contains(n) { result.fields.append(n) }
                log("Wrote field \(n) to time \(t)")
            } else {
                result.log.append(line)
                log(line)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            rlock.lock(); defer { rlock.unlock() }
            pending += String(decoding: d, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl]); pending = String(pending[pending.index(after: nl)...])
                handle(line)
            }
        }
        lock.lock()
        if cancelled { lock.unlock(); throw PostScriptError("cancelled") }
        process = p
        lock.unlock()
        log("Running \(script.fileName) with \(python)")
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); log("Stopped after \(Int(timeout)) s.") }
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.05)
        pipe.fileHandleForReading.readabilityHandler = nil
        rlock.lock()
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { pending += String(decoding: rest, as: UTF8.self) }
        for line in pending.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty { handle(String(line)) }
        pending = ""
        result.exitCode = p.terminationStatus
        // figures saved without curlew_post.savefig
        for f in ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
        where ["png", "jpg", "jpeg", "svg", "pdf"].contains(f.pathExtension.lowercased()) && !result.figures.contains(f) {
            result.figures.append(f)
        }
        result.seconds = Date().timeIntervalSince(t0)
        rlock.unlock()
        if result.exitCode != 0 {
            let tail = result.log.suffix(8).joined(separator: "\n")
            if tail.contains("No module named 'numpy'") {
                result.log.append("NumPy is not installed for \(python): Settings › Machine Learning › Set Up PyTorch Environment installs it (or pip install numpy).")
            }
        }
        return result
    }

    /// Runs every script marked "after the solve" on a finished case.
    public static func runAfterSolve(setup: CaseSetup, caseDirectory dir: URL, log: @escaping (String) -> Void) -> [PostScriptResult] {
        var out: [PostScriptResult] = []
        for sc in setup.openfoam.postProcessing.scripts where sc.afterSolve && !sc.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("— Python script \(sc.name)")
            do {
                let r = try PostScriptRun().run(sc, caseDirectory: dir, setup: setup, log: { log("  " + $0) })
                log(r.succeeded ? String(format: "  %@ finished (%.1f s)", sc.name as NSString, r.seconds) : "  \(sc.name) failed (exit \(r.exitCode))")
                out.append(r)
            } catch {
                log("  \(sc.name): \(error)")
            }
        }
        return out
    }
}

// MARK: - Script templates

public enum PostScriptTemplates {
    public static let all: [(title: String, script: FoamPostScript)] = [
        ("Patch summary (area, mean pressure, flow)", FoamPostScript(name: "patch_summary", code: patchSummary)),
        ("Pressure drop between two patches", FoamPostScript(name: "pressure_drop", code: pressureDrop)),
        ("Velocity along a line (plot)", FoamPostScript(name: "line_plot", code: linePlot)),
        ("New field: total pressure", FoamPostScript(name: "total_pressure", code: totalPressure)),
        ("Residual history (plot)", FoamPostScript(name: "residuals", code: residualPlot)),
        ("Field statistics (mean, RMS, percentiles)", FoamPostScript(name: "field_stats", code: fieldStats)),
    ]

    static let patchSummary = #"""
import numpy as np
import curlew_post as cp

case = cp.load()
print(f"time {case.time}: {case.n_cells} cells, fields {', '.join(case.fields)}")
for name, patch in case.patches.items():
    if patch.type in ("empty", "wedge"):
        continue
    line = f"{name:20s} {patch.type:14s} area {patch.area:.4g} m²"
    if "p" in case:
        p_mean = patch.average(case.pressure_pa(patch))
        line += f"  mean p {p_mean:.5g} Pa"
        cp.report(f"{name} mean pressure", p_mean, "Pa")
    if "U" in case and patch.type not in ("wall", "symmetry", "symmetryPlane"):
        q = patch.flux("U")
        line += f"  volume flow {q:.5g} m³/s"
        cp.report(f"{name} volume flow", q, "m³/s")
    print(line)
"""#

    static let pressureDrop = #"""
import curlew_post as cp

# Change these to the inlet and outlet of your case.
INLET, OUTLET = "inlet", "outlet"

case = cp.load()
p_in = case.patches[INLET].average(case.pressure_pa(case.patches[INLET]))
p_out = case.patches[OUTLET].average(case.pressure_pa(case.patches[OUTLET]))
cp.report("pressure drop", p_in - p_out, "Pa")
q = case.patches[INLET].flux("U")
cp.report("volume flow", -q, "m³/s")
if abs(q) > 0:
    cp.report("hydraulic power", (p_in - p_out) * abs(q), "W")
"""#

    static let linePlot = #"""
import numpy as np
import matplotlib.pyplot as plt
import curlew_post as cp

case = cp.load()
lo, hi = case.centres.min(axis=0), case.centres.max(axis=0)
mid = 0.5 * (lo + hi)
# a line through the middle of the domain along x; change start and end as needed
start, end = np.array([lo[0], mid[1], mid[2]]), np.array([hi[0], mid[1], mid[2]])
s, u = case.line(start, end, n=200, field="U")
speed = np.linalg.norm(u, axis=1)
plt.figure(figsize=(6, 3.5))
plt.plot(s, speed, lw=1.5)
plt.xlabel("distance along the line (m)")
plt.ylabel("|U| (m/s)")
plt.title(f"Velocity along the centreline, t = {case.time}")
plt.grid(alpha=0.3)
cp.savefig("centreline_velocity")
cp.report("maximum speed on the line", speed.max(), "m/s")
"""#

    static let totalPressure = #"""
import numpy as np
import curlew_post as cp

case = cp.load()
rho = case.density or 1.0
p = case.pressure_pa()
U = case["U"]
p0 = p + 0.5 * rho * np.sum(U * U, axis=1)
case.write_field("totalPressurePa", p0)       # appears in the time directory, ParaView and Curlew
cp.report("max total pressure", p0.max(), "Pa")
cp.report("volume-averaged total pressure", case.volume_average(p0), "Pa")
"""#

    static let residualPlot = #"""
import numpy as np
import matplotlib.pyplot as plt
import curlew_post as cp

case = cp.load()
data = case.function_object("solverResiduals")
if not data:
    print("No solverResiduals output (OpenFOAM page › More Function Objects › Residuals file).")
else:
    x = data.get("Time")
    plt.figure(figsize=(6, 4))
    for name, col in data.items():
        if name.endswith("_initial") and np.all(np.isfinite(col)) and np.any(col > 0):
            plt.semilogy(x, col, label=name.replace("_initial", ""))
    plt.xlabel("iteration / time")
    plt.ylabel("initial residual")
    plt.legend()
    plt.grid(alpha=0.3, which="both")
    cp.savefig("residuals")
"""#

    static let fieldStats = #"""
import numpy as np
import curlew_post as cp

FIELD = "U"     # any field of the case

case = cp.load()
f = case[FIELD]
v = case.volumes
x = np.linalg.norm(f, axis=1) if f.ndim == 2 else f
mean = np.sum(x * v) / v.sum()
rms = np.sqrt(np.sum((x - mean) ** 2 * v) / v.sum())
print(f"{FIELD}: volume mean {mean:.5g}, RMS deviation {rms:.5g}, min {x.min():.5g}, max {x.max():.5g}")
for q in (5, 50, 95):
    print(f"  {q}th percentile {np.percentile(x, q):.5g}")
cp.report(f"{FIELD} volume mean", mean)
cp.report(f"{FIELD} RMS deviation", rms)
"""#
}
