import Foundation
import CurlewSolver

/// Results written by OpenFOAM post-processing (line samples from `sets` function objects).
public enum FoamPostResults {
    public struct LineSample: Sendable, Equatable {
        public var name: String
        /// Column names; the first is the distance along the line.
        public var columns: [String]
        public var rows: [[Double]]
        public var time: String
    }

    /// Every line sample under postProcessing/, at its latest time. Several CSV files of one
    /// sample (scalars and vectors) are merged on the distance column.
    public static func lineSamples(in caseDir: URL) throws -> [LineSample] {
        let fm = FileManager.default
        let root = caseDir.appendingPathComponent("postProcessing")
        guard let objects = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [LineSample] = []
        for obj in objects.sorted() {
            let od = root.appendingPathComponent(obj)
            let times = ((try? fm.contentsOfDirectory(atPath: od.path)) ?? []).filter { Double($0) != nil }
            guard let latest = times.max(by: { Double($0)! < Double($1)! }) else { continue }
            let td = od.appendingPathComponent(latest)
            let csvs = ((try? fm.contentsOfDirectory(atPath: td.path)) ?? []).filter { $0.hasSuffix(".csv") }.sorted()
            guard !csvs.isEmpty else { continue }
            var columns: [String] = []
            var rows: [[Double]] = []
            for f in csvs {
                guard let text = try? String(contentsOf: td.appendingPathComponent(f), encoding: .utf8) else { continue }
                var lines = text.split(whereSeparator: \.isNewline).map(String.init)
                guard !lines.isEmpty else { continue }
                let header = lines.removeFirst().trimmingCharacters(in: CharacterSet(charactersIn: "# ")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let data = lines.compactMap { l -> [Double]? in
                    let v = l.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    return v.count == header.count ? v : nil
                }
                if columns.isEmpty { columns = header; rows = data }
                else if data.count == rows.count {
                    // merge, skipping the repeated distance column
                    columns += header.dropFirst()
                    for i in rows.indices { rows[i] += data[i].dropFirst() }
                }
            }
            if !rows.isEmpty { out.append(LineSample(name: obj, columns: columns, rows: rows, time: latest)) }
        }
        return out
    }
}

extension FoamSolve {
    /// Run the post-processing of `setup` on an existing case (latest time): writes
    /// system/curlewPostProcess, runs the function objects through the solver and the exports,
    /// and returns the line samples. Returns nil on success, otherwise the reason it stopped.
    public static func postProcess(caseDirectory dir: URL, setup s: CaseSetup, environment env: FoamEnvironment,
                                   log: @escaping (String) -> Void) throws -> [FoamPostResults.LineSample] {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("system/controlDict").path) else {
            throw FoamSolveError.notRunnable("\(dir.path) is not an OpenFOAM case yet: run or write the case first")
        }
        let app = FoamCaseWriter.resolvedApplication(s)
        guard !app.isMultiRegion else { throw FoamSolveError.notRunnable("post-processing of conjugate (multi-region) cases is not supported yet") }
        let text = FoamCaseWriter.postProcessDictionary(s)
        try text.write(to: dir.appendingPathComponent("system/curlewPostProcess"), atomically: true, encoding: .utf8)
        let report = FoamCaseReport(application: app, turbulence: .laminar, cores: 1, runsPotentialFoam: false,
                                    kinematicPressure: !app.isThermal, density: 1, operatingPressure: 0)
        let stages = FoamRunPlan.postProcessingStages(s.openfoam.postProcessing, application: app)
        guard !stages.isEmpty else { return [] }
        let runner = FoamRunner(environment: env, caseDirectory: dir, report: report)
        let failure = runner.run(stages) { e in
            switch e {
            case .stage(let st): log("— \(st.title)")
            case .stageFinished(let st, let code, let sec): log(String(format: "  %@ %@ (%.1f s)", st.title, code == 0 ? "finished" : "failed (exit \(code))", sec))
            case .line(let l): if l.hasPrefix("--> FOAM FATAL") || l.contains("Writing") && l.contains(".vtk") { log(l) }
            default: break
            }
        }
        if let f = failure { throw FoamSolveError.notRunnable(f) }
        return try FoamPostResults.lineSamples(in: dir)
    }
}
