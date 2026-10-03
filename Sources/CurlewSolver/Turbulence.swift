import Foundation
import CurlewMesh

extension PressureBasedSolver {
    func computeWallDistance() throws {}
    func initTurbulentViscosity() {}
    func updateWallFunctions() { updateLaminarWalls() }
    func wallConductivity(_ wi: Int, cell: Int) -> Double { state.conductivity[cell] }
    func solveTurbulence() -> [String: Double] { [:] }
}
