import Foundation
import FluidCraftMesh
import FluidCraftSolver

/// Add / rename / remove operations that keep every reference in the case consistent.
extension Workspace {
    static func uniqueName(_ prefix: String, existing: [String]) -> String {
        var i = 1
        while existing.contains("\(prefix)-\(i)") { i += 1 }
        return "\(prefix)-\(i)"
    }

    var meshEditingBlocked: Bool {
        if isRunning { log("Stop the calculation before changing the mesh or zones.", .warning) }
        return isRunning
    }

    // MARK: User-defined scalars

    func addScalar() {
        let n = Workspace.uniqueName("scalar", existing: setup.models.passiveScalars.map(\.name))
        setup.models.passiveScalars.append(PassiveScalar(name: n))
        log("Added user-defined scalar \(n)")
    }

    func removeScalar(named n: String) {
        setup.models.passiveScalars.removeAll { $0.name == n }
        for k in Array(setup.boundaries.keys) { setup.boundaries[k]?.scalars[n] = nil }
        setup.initialization.patches.removeAll { $0.field == n }
        if display.field == n { display.field = "velocity-magnitude" }
        log("Removed user-defined scalar \(n)")
    }

    @discardableResult
    func renameScalar(_ old: String, to new: String) -> Bool {
        guard !setup.models.passiveScalars.contains(where: { $0.name == new }) else {
            log("A scalar named \(new) already exists.", .warning); return false
        }
        guard let i = setup.models.passiveScalars.firstIndex(where: { $0.name == old }) else { return false }
        setup.models.passiveScalars[i].name = new
        for k in Array(setup.boundaries.keys) {
            if let v = setup.boundaries[k]?.scalars.removeValue(forKey: old) { setup.boundaries[k]?.scalars[new] = v }
        }
        for j in setup.initialization.patches.indices where setup.initialization.patches[j].field == old {
            setup.initialization.patches[j].field = new
        }
        if display.field == old { display.field = new }
        return true
    }

    // MARK: Materials

    @discardableResult
    func renameMaterial(_ old: String, to new: String) -> Bool {
        guard !setup.materials.contains(where: { $0.name == new }) else {
            log("A material named \(new) already exists.", .warning); return false
        }
        guard let i = setup.materials.firstIndex(where: { $0.name == old }) else { return false }
        setup.materials[i].name = new
        for k in Array(setup.cellZones.keys) where setup.cellZones[k]?.material == old { setup.cellZones[k]?.material = new }
        return true
    }

    /// Materials referenced by cell zones cannot be deleted.
    func removeMaterial(named n: String) -> Bool {
        if let zone = setup.cellZones.first(where: { $0.value.material == n })?.key {
            log("\(n) is used by cell zone \(zone); assign another material first.", .warning)
            return false
        }
        setup.materials.removeAll { $0.name == n }
        return true
    }

    // MARK: Expressions and reports

    @discardableResult
    func renameExpression(_ old: String, to new: String) -> Bool {
        guard !setup.expressions.contains(where: { $0.name == new }) else {
            log("An expression named \(new) already exists.", .warning); return false
        }
        guard let i = setup.expressions.firstIndex(where: { $0.name == old }) else { return false }
        setup.expressions[i].name = new
        return true
    }

    @discardableResult
    func renameReport(_ old: String, to new: String) -> Bool {
        guard !setup.reports.contains(where: { $0.name == new }) else {
            log("A report definition named \(new) already exists.", .warning); return false
        }
        guard let i = setup.reports.firstIndex(where: { $0.name == old }) else { return false }
        setup.reports[i].name = new
        return true
    }
}
