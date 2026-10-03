import Foundation
import CurlewMesh

/// `.curlew` case package: a directory with case.json, mesh.crlmesh and (optionally)
/// data.bin, residuals.json and reports.json. Shared by the app and the CLI.
public enum CasePackage {
    public static func write(to dir: URL, mesh: Mesh, setup: CaseSetup, solver: PressureBasedSolver?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try setup.encoded().write(to: dir.appendingPathComponent("case.json"))
        try MeshIO.writeBinary(mesh).write(to: dir.appendingPathComponent("mesh.crlmesh"))
        if let s = solver {
            try SolutionArchive.write(s).write(to: dir.appendingPathComponent("data.bin"))
            try JSONEncoder().encode(s.residuals).write(to: dir.appendingPathComponent("residuals.json"))
            try JSONEncoder().encode(s.reportHistory).write(to: dir.appendingPathComponent("reports.json"))
        } else {
            try? fm.removeItem(at: dir.appendingPathComponent("data.bin"))
        }
    }

    public struct Loaded {
        public var mesh: Mesh
        public var setup: CaseSetup
        public var hasData: Bool
    }

    public static func read(_ dir: URL) throws -> Loaded {
        let setup = try CaseSetup.decodeLenient(Data(contentsOf: dir.appendingPathComponent("case.json")))
        let mesh = try MeshIO.readBinary(Data(contentsOf: dir.appendingPathComponent("mesh.crlmesh")))
        let hasData = FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.bin").path)
        return Loaded(mesh: mesh, setup: setup, hasData: hasData)
    }

    /// Restore data (fields and histories) into a solver built for the package's mesh.
    public static func restore(_ dir: URL, into solver: PressureBasedSolver) throws {
        try SolutionArchive.read(Data(contentsOf: dir.appendingPathComponent("data.bin")), into: solver)
        let r = (try? JSONDecoder().decode(ResidualHistory.self, from: Data(contentsOf: dir.appendingPathComponent("residuals.json")))) ?? ResidualHistory()
        let rep = (try? JSONDecoder().decode(ReportHistory.self, from: Data(contentsOf: dir.appendingPathComponent("reports.json")))) ?? ReportHistory()
        solver.restoreHistory(residuals: r, reports: rep)
    }
}
