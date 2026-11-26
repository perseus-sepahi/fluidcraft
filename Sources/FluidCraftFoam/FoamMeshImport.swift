import Foundation
import FluidCraftMesh

/// Mesh files converted by OpenFOAM's own utilities: `fluentMeshToFoam` (falling back to
/// `fluent3DMeshToFoam` for polyhedral 3D meshes) and `gmshToFoam`. FluidCraft's readers are kept
/// only for what those converters cannot read: binary Fluent files, binary or 2D Gmsh files,
/// and every file when OpenFOAM is not installed.
public enum FoamMeshImport {
    public struct Imported: Sendable {
        public var mesh: Mesh
        /// What converted the file ("fluentMeshToFoam", or why FluidCraft's reader was used).
        public var converter: String
    }

    /// Read `url` (Fluent, Gmsh, OpenFOAM case or FluidCraft mesh). `depth2D` is the thickness
    /// given to 2D meshes, which OpenFOAM extrudes into one cell layer.
    public static func read(url: URL, depth2D: Double = 1, environment: FoamEnvironment? = nil,
                            log: ((String) -> Void)? = nil) throws -> Imported {
        guard let fmt = MeshFormat.detect(url) else { throw MeshError.unsupported("unknown mesh file type '\(url.pathExtension)'") }
        switch fmt {
        case .openfoam, .fluidcraft:
            return Imported(mesh: try MeshIO.read(url: url, depth2D: depth2D), converter: "FluidCraft")
        case .fluent:
            return try fluent(url, depth2D: depth2D, environment: environment, log: log)
        case .gmsh:
            return try gmsh(url, depth2D: depth2D, environment: environment, log: log)
        }
    }

    /// Reader for Gmsh output inside FluidCraft (`GmshDriver.generate(reader:)`).
    public static func gmshReader(environment: FoamEnvironment? = nil) -> (URL, Double) throws -> Mesh {
        { url, depth in try gmsh(url, depth2D: depth, environment: environment, log: nil).mesh }
    }

    // MARK: Fluent

    static func fluent(_ url: URL, depth2D: Double, environment: FoamEnvironment?, log: ((String) -> Void)?) throws -> Imported {
        let info = try MeshFileProbe.fluent(url)
        if info.hdf5 {
            throw MeshError.unsupported("Fluent HDF5 files (.cas.h5/.msh.h5) are not readable by OpenFOAM's converters or FluidCraft; write the mesh from Fluent as an ASCII .msh (File › Export › Mesh, or /file/write-mesh with binary files off)")
        }
        if info.binary {
            return Imported(mesh: try FluentMeshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Fluent reader (binary file; OpenFOAM's fluentMeshToFoam reads ASCII only)")
        }
        guard let env = try environmentOrNil(environment) else {
            return Imported(mesh: try FluentMeshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Fluent reader (OpenFOAM is not installed)")
        }
        let dir = try FoamMeshTools.scratchCase("fluent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try link(url, into: dir, as: "input." + (url.pathExtension.isEmpty ? "msh" : url.pathExtension))
        var used = "fluentMeshToFoam"
        if info.dimension == 2 {
            _ = try FoamMeshTools.run([FoamMeshTools.stage("fluentMeshToFoam", ["-writeZones", "-2D", FoamNum.s(depth2D), input])],
                                      in: dir, environment: env, log: log)
        } else {
            do {
                _ = try FoamMeshTools.run([FoamMeshTools.stage("fluentMeshToFoam", ["-writeZones", input])], in: dir, environment: env, log: log)
            } catch {
                // polyhedral cells and other shapes fluentMeshToFoam cannot build
                log?("fluentMeshToFoam failed; trying fluent3DMeshToFoam")
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("constant/polyMesh"))
                _ = try FoamMeshTools.run([FoamMeshTools.stage("fluent3DMeshToFoam", [input])], in: dir, environment: env, log: log)
                used = "fluent3DMeshToFoam"
            }
        }
        let m = try FoamMeshReader.read(url: dir)
        // Fluent's boundary types (velocity-inlet, pressure-outlet, …) and solid cell zones
        for (i, z) in m.boundaryZones.enumerated() {
            if let t = info.zoneTypes[z.name] {
                m.updateBoundaryZone(i, name: z.name, kind: FluentMeshReader.zoneKind(bc: -1, typeName: t))
            }
        }
        for (i, z) in m.cellZones.enumerated() where info.zoneTypes[z.name] == "solid" {
            m.updateCellZone(i, name: z.name, kind: .solid)
        }
        return Imported(mesh: m, converter: used)
    }

    // MARK: Gmsh

    static func gmsh(_ url: URL, depth2D: Double, environment: FoamEnvironment?, log: ((String) -> Void)?) throws -> Imported {
        let info = try MeshFileProbe.gmsh(url)
        if info.binary {
            return Imported(mesh: try GmshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Gmsh reader (binary file; OpenFOAM's gmshToFoam reads ASCII only)")
        }
        if info.volumes == 0 {
            return Imported(mesh: try GmshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Gmsh reader (2D mesh, extruded one cell thick; gmshToFoam converts 3D meshes only)")
        }
        if info.sharedPhysicalTags {
            return Imported(mesh: try GmshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Gmsh reader (a physical tag is used in two dimensions, which gmshToFoam would mislabel)")
        }
        guard let env = try environmentOrNil(environment) else {
            return Imported(mesh: try GmshReader.read(url: url, depth2D: depth2D),
                            converter: "FluidCraft's Gmsh reader (OpenFOAM is not installed)")
        }
        let dir = try FoamMeshTools.scratchCase("gmsh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try link(url, into: dir, as: "input.msh")
        do {
            _ = try FoamMeshTools.run([FoamMeshTools.stage("gmshToFoam", [input])], in: dir, environment: env, log: log)
        } catch {
            // a v2 file does not say whether it holds volume elements: a 2D one fails here
            let parsed = try GmshReader.read(url: url, depth2D: depth2D)
            guard parsed.isTwoDimensional else { throw error }
            return Imported(mesh: parsed, converter: "FluidCraft's Gmsh reader (2D mesh, extruded one cell thick; gmshToFoam converts 3D meshes only)")
        }
        let m = try FoamMeshReader.read(url: dir)
        // gmshToFoam puts faces in no physical group into `defaultFaces`; name it as FluidCraft's reader does
        for (i, z) in m.boundaryZones.enumerated() where z.name == "defaultFaces" {
            m.updateBoundaryZone(i, name: "default-wall", kind: .wall)
        }
        for (i, z) in m.cellZones.enumerated() where z.name.lowercased().contains("solid") {
            m.updateCellZone(i, name: z.name, kind: .solid)
        }
        return Imported(mesh: m, converter: "gmshToFoam")
    }

    // MARK: Helpers

    /// The OpenFOAM environment, or nil when none is installed (other errors are thrown).
    static func environmentOrNil(_ given: FoamEnvironment?) throws -> FoamEnvironment? {
        if let given { return given }
        guard !FoamDiscovery.discover().isEmpty else { return nil }
        return try FoamMeshTools.environment()
    }

    /// The input under a plain name inside the scratch case, so odd file names (spaces,
    /// leading dashes) never reach the converter's command line.
    static func link(_ url: URL, into dir: URL, as name: String) throws -> String {
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url.resolvingSymlinksInPath())
        return name
    }
}
