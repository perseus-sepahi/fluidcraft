import Foundation
import CurlewMesh
import CurlewSolver

/// VTK XML unstructured grid (.vtu) export of the volume mesh and cell data,
/// using VTK_POLYHEDRON cells so any Curlew mesh opens in ParaView unchanged.
public enum VTKExport {
    public static func write(solver s: PressureBasedSolver, fields: [String]? = nil, to url: URL) throws {
        let m = s.mesh
        var out = Data()
        func w(_ str: String) { out.append(str.data(using: .utf8)!) }
        // Appended raw binary blocks
        var blocks: [Data] = []
        var offset = 0
        func addBlock<T>(_ a: [T]) -> Int {
            var d = Data()
            var n = UInt64(a.count * MemoryLayout<T>.stride)
            withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
            a.withUnsafeBytes { d.append(contentsOf: $0) }
            let o = offset
            offset += d.count
            blocks.append(d)
            return o
        }
        // geometry
        var pts = [Double](); pts.reserveCapacity(m.nPoints * 3)
        for p in m.points { pts += [p.x, p.y, p.z] }
        // connectivity: unique nodes per cell; faces stream: nFaces, (nNodes, ids...)...
        var conn: [Int64] = [], offs: [Int64] = [], types: [UInt8] = []
        var faces: [Int64] = [], faceOffs: [Int64] = []
        for c in 0..<m.nCells {
            var nodes: [Int32] = []
            var fstream: [Int64] = [Int64(m.cellFaceRange(c).count)]
            for k in m.cellFaceRange(c) {
                let f = Int(m.cellFaces[k])
                var ids = m.faceNodeRange(f).map { m.faceNodes[$0] }
                if Int(m.owner[f]) != c { ids.reverse() } // outward for this cell
                fstream.append(Int64(ids.count))
                for id in ids { fstream.append(Int64(id)); if !nodes.contains(id) { nodes.append(id) } }
            }
            conn += nodes.map { Int64($0) }
            offs.append(Int64(conn.count))
            types.append(42)
            faces += fstream
            faceOffs.append(Int64(faces.count))
        }
        let names = fields ?? FieldCatalog.available(for: s).filter { !["orthogonal-quality", "wall-shear-stress", "skin-friction-coefficient", "y-plus", "wall-heat-flux"].contains($0) }
        var cellData: [(String, Int, Int)] = [] // name, components, offset
        let oPts = addBlock(pts)
        let oConn = addBlock(conn), oOffs = addBlock(offs), oTypes = addBlock(types)
        let oFaces = addBlock(faces), oFaceOffs = addBlock(faceOffs)
        cellData.append(("velocity", 3, addBlock(s.state.u.flatMap { [$0.x, $0.y, $0.z] })))
        for n in names {
            if let v = FieldCatalog.cellValues(n, s) { cellData.append((n, 1, addBlock(v))) }
        }
        w("<?xml version=\"1.0\"?>\n<VTKFile type=\"UnstructuredGrid\" version=\"1.0\" byte_order=\"LittleEndian\" header_type=\"UInt64\">\n")
        w("<UnstructuredGrid>\n<Piece NumberOfPoints=\"\(m.nPoints)\" NumberOfCells=\"\(m.nCells)\">\n")
        w("<Points><DataArray type=\"Float64\" NumberOfComponents=\"3\" format=\"appended\" offset=\"\(oPts)\"/></Points>\n")
        w("<Cells>\n<DataArray type=\"Int64\" Name=\"connectivity\" format=\"appended\" offset=\"\(oConn)\"/>\n")
        w("<DataArray type=\"Int64\" Name=\"offsets\" format=\"appended\" offset=\"\(oOffs)\"/>\n")
        w("<DataArray type=\"UInt8\" Name=\"types\" format=\"appended\" offset=\"\(oTypes)\"/>\n")
        w("<DataArray type=\"Int64\" Name=\"faces\" format=\"appended\" offset=\"\(oFaces)\"/>\n")
        w("<DataArray type=\"Int64\" Name=\"faceoffsets\" format=\"appended\" offset=\"\(oFaceOffs)\"/>\n</Cells>\n")
        w("<CellData Scalars=\"pressure\" Vectors=\"velocity\">\n")
        for (n, comps, o) in cellData {
            w("<DataArray type=\"Float64\" Name=\"\(n)\" NumberOfComponents=\"\(comps)\" format=\"appended\" offset=\"\(o)\"/>\n")
        }
        w("</CellData>\n</Piece>\n</UnstructuredGrid>\n<AppendedData encoding=\"raw\">\n_")
        for b in blocks { out.append(b) }
        w("\n</AppendedData>\n</VTKFile>\n")
        try out.write(to: url)
    }

    /// Display surface as legacy ASCII VTK polydata.
    public static func write(surface s: SurfaceMesh, field: String, to url: URL) throws {
        var t = "# vtk DataFile Version 3.0\nCurlew surface \(s.name)\nASCII\nDATASET POLYDATA\nPOINTS \(s.positions.count) float\n"
        for p in s.positions { t += "\(p.x) \(p.y) \(p.z)\n" }
        let nt = s.triangles.count / 3
        t += "POLYGONS \(nt) \(nt * 4)\n"
        for i in 0..<nt { t += "3 \(s.triangles[3 * i]) \(s.triangles[3 * i + 1]) \(s.triangles[3 * i + 2])\n" }
        t += "POINT_DATA \(s.positions.count)\nSCALARS \(field) float 1\nLOOKUP_TABLE default\n"
        for v in s.values { t += "\(v)\n" }
        try t.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Cell data as CSV (x, y, z, fields...).
    public static func writeCSV(solver s: PressureBasedSolver, fields: [String], to url: URL) throws {
        let cols = fields.compactMap { n in FieldCatalog.cellValues(n, s).map { (n, $0) } }
        var t = "x,y,z," + cols.map(\.0).joined(separator: ",") + "\n"
        for c in 0..<s.mesh.nCells {
            let p = s.mesh.cellCentres[c]
            t += "\(p.x),\(p.y),\(p.z)"
            for (_, v) in cols { t += ",\(v[c])" }
            t += "\n"
        }
        try t.write(to: url, atomically: true, encoding: .utf8)
    }
}
