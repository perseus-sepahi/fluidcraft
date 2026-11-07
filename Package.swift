// swift-tools-version:6.0
import PackageDescription

// Hot numerical loops are written against unsafe buffers; -Ounchecked drops the
// remaining overflow/precondition checks in release builds of the numeric targets.
let numeric: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]
let plain: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Curlew",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Curlew", targets: ["CurlewApp"]),
        .executable(name: "curlew-cli", targets: ["CurlewCLI"]),
        .library(name: "CurlewSolver", targets: ["CurlewSolver"]),
    ],
    targets: [
        // Unstructured polyhedral mesh, geometry, quality, importers and mesh generation.
        .target(name: "CurlewMesh", swiftSettings: numeric),
        // Sparse matrices, aggregation AMG, Krylov solvers, Metal mixed-precision backend.
        .target(name: "CurlewLinear", swiftSettings: numeric),
        // Case model, pressure- and density-based finite-volume solvers, physics models.
        .target(name: "CurlewSolver", dependencies: ["CurlewMesh", "CurlewLinear"], swiftSettings: numeric),
        // Surfaces, contours, vectors, pathlines, plots, reports and data export.
        .target(name: "CurlewPost", dependencies: ["CurlewMesh", "CurlewSolver"], swiftSettings: numeric),
        // OpenFOAM backend: installation discovery, case writer, staged runner, log parsing,
        // result reading and snappyHexMesh CAD meshing.
        .target(name: "CurlewFoam", dependencies: ["CurlewMesh", "CurlewSolver"], swiftSettings: plain),
        .executableTarget(
            name: "CurlewApp",
            dependencies: ["CurlewMesh", "CurlewLinear", "CurlewSolver", "CurlewPost", "CurlewFoam"],
            swiftSettings: plain
        ),
        .executableTarget(
            name: "CurlewCLI",
            dependencies: ["CurlewMesh", "CurlewLinear", "CurlewSolver", "CurlewPost", "CurlewFoam"],
            swiftSettings: plain
        ),
        .testTarget(
            name: "CurlewTests",
            dependencies: ["CurlewMesh", "CurlewLinear", "CurlewSolver", "CurlewPost", "CurlewFoam"],
            resources: [.copy("Fixtures")],
            swiftSettings: plain
        ),
    ]
)
