import SwiftUI
import ExplorerCore

/// Only the canvas, region inspector and tiny row highlights observe this.
/// The full analysis browser owns the reference without subscribing to changes.
@MainActor final class RegionInteraction: ObservableObject {
    @Published var hovered: String?
    @Published var selected: String?
    var active: String? { selected ?? hovered }
    func reset() { selected = nil; hovered = nil }
}

/// Pointer positions do not invalidate a view unless the hit region changes.
@MainActor final class RegionPointer {
    var point: CGPoint?
}

struct RegionSelectionBackground: View {
    @ObservedObject var interaction: RegionInteraction
    let regions: [String]
    let table: String
    var body: some View {
        regions.contains(interaction.active ?? "") ? regionColor(table).opacity(0.12) : Color.clear
    }
}

#if DEBUG
/// Native hosted checks can count real body evaluations, without model runs.
@MainActor enum AnalysisRenderProbe {
    static var didRender: ((String) -> Void)?
    static func record(_ view: String) { didRender?(view) }
}
#endif
