import Foundation

/// Metal mixed-precision linear-solver backend (filled in later).
public final class GPUAccelerator {
    public static var shared: GPUAccelerator? { nil }
}

extension GPUAccelerator: LinearAccelerator {
    public func shouldHandle(n: Int, method: LinearMethod) -> Bool { false }
    public func solve(_ A: SparseMatrix, x: inout [Double], b: [Double], settings: LinearSolverSettings, amg: AMGHierarchy) -> LinearSolveStats {
        LinearSolveStats(iterations: 0, initialResidual: 0, finalResidual: 0, converged: false)
    }
}
