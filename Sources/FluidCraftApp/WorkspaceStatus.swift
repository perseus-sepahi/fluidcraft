import Foundation
import AppKit
import FluidCraftMesh
import FluidCraftSolver
import FluidCraftFoam

/// A sidebar step's state: done, or something the user should look at before running.
enum StepStatus: Equatable {
    case done
    case attention(String)
}

extension Workspace {
    /// What the sidebar shows next to a step. nil = nothing to report yet.
    func status(_ item: OutlineItem) -> StepStatus? {
        switch item {
        case .meshGeneration:
            return mesh == nil ? .attention("No mesh yet: generate one, import one, or load a tutorial") : .done
        case .meshInfo:
            guard mesh != nil, let q = meshQuality else { return nil }
            if q.negativeVolumes > 0 { return .attention("\(q.negativeVolumes) cells have non-positive volume") }
            if q.minOrthogonalQuality < 0.01 { return .attention(String(format: "Very low orthogonal quality (%.3g)", q.minOrthogonalQuality)) }
            return .done
        case .cellZones:
            guard mesh != nil else { return nil }
            let missing = setup.cellZones.filter { setup.material(named: $0.value.material) == nil }.map(\.key).sorted()
            return missing.isEmpty ? .done : .attention("No material for " + missing.joined(separator: ", "))
        case .boundaries:
            return mesh == nil ? nil : .done
        case .openfoam:
            if foamInstallations.isEmpty { return .attention("OpenFOAM is not installed (Settings › Tools)") }
            if !foamUnapprovedContent.isEmpty { return .attention("Custom OpenFOAM content in this case needs your approval") }
            return nil
        case .initialization:
            return initialized ? .done : nil
        case .runCalculation:
            if hasResults { return .done }
            if mesh != nil && foamInstallations.isEmpty { return .attention("Running needs OpenFOAM (Settings › Tools)") }
            return nil
        default:
            return nil
        }
    }

    /// Pages that have nothing to show yet are dimmed (still selectable).
    func isAvailable(_ item: OutlineItem) -> Bool {
        switch item {
        case .meshInfo, .general, .models, .materials, .cellZones, .boundaries, .expressions, .referenceValues,
             .methods, .controls, .reportDefinitions, .monitors, .initialization, .openfoam, .runCalculation,
             .surfaces, .graphicsMesh:
            return mesh != nil
        case .contours, .vectors, .pathlines, .xyPlot, .reports:
            return solver != nil
        default:
            return true
        }
    }

    /// Case packages opened or saved recently that still exist.
    var recentCases: [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { CasePackage.isCase($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The OpenFOAM installation in use, for the status in the ribbon.
    var openFOAMSummary: (installed: Bool, text: String) {
        guard let i = foamInstallations.first else { return (false, "OpenFOAM not installed") }
        return (true, "OpenFOAM " + (i.version ?? i.name))
    }
}
