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
    name: "FluidCraft",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FluidCraft", targets: ["FluidCraftApp"]),
        .executable(name: "fluidcraft-cli", targets: ["FluidCraftCLI"]),
        .library(name: "FluidCraftSolver", targets: ["FluidCraftSolver"]),
    ],
    targets: [
        // Unstructured polyhedral mesh, geometry, quality, importers and mesh generation.
        .target(name: "FluidCraftMesh", swiftSettings: numeric),
        // Case model, pressure- and density-based finite-volume solvers, physics models.
        .target(name: "FluidCraftSolver", dependencies: ["FluidCraftMesh"], swiftSettings: numeric),
        // Surfaces, contours, vectors, pathlines, plots, reports and data export.
        .target(name: "FluidCraftPost", dependencies: ["FluidCraftMesh", "FluidCraftSolver"], swiftSettings: numeric),
        // OpenFOAM backend: installation discovery, case writer, staged runner, log parsing,
        // result reading and snappyHexMesh CAD meshing.
        .target(name: "FluidCraftFoam", dependencies: ["FluidCraftMesh", "FluidCraftSolver"], swiftSettings: plain),
        .executableTarget(
            name: "FluidCraftApp",
            dependencies: ["FluidCraftMesh", "FluidCraftSolver", "FluidCraftPost", "FluidCraftFoam"],
            swiftSettings: plain
        ),
        .executableTarget(
            name: "FluidCraftCLI",
            dependencies: ["FluidCraftMesh", "FluidCraftSolver", "FluidCraftPost", "FluidCraftFoam"],
            swiftSettings: plain
        ),
        .testTarget(
            name: "FluidCraftTests",
            dependencies: ["FluidCraftMesh", "FluidCraftSolver", "FluidCraftPost", "FluidCraftFoam"],
            resources: [.copy("Fixtures")],
            swiftSettings: plain
        ),
    ]
)
