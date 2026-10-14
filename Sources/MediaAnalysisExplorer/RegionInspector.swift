import SwiftUI
import AVFoundation
import ExplorerCore

struct RegionInspector: View {
    @ObservedObject var interaction: RegionInteraction
    let timeline: RegionTimeline
    let families: [ResultFamily]
    let player: AVPlayer?
    let inspectRecord: (StoredRegion) -> Void
    private var inspected: StoredRegion? { interaction.active.flatMap { timeline.regionsByID[$0] } }
    var body: some View {
        #if DEBUG
        let _ = AnalysisRenderProbe.record("inspector")
        #endif
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(inspected?.title ?? "Region inspector", systemImage: "viewfinder").font(.subheadline.weight(.semibold))
                    InfoButton(title: "Region inspector", text: "Hover a box on the image, click to pin, or choose a detection above.")
                    Spacer()
                    if interaction.selected != nil {
                        Text("Pinned").font(.caption2).foregroundStyle(.orange)
                        Button("Unpin") { interaction.reset() }.controlSize(.mini)
                    }
                }
                RegionDetectionPicker(interaction: interaction, revision: timeline.revision,
                    regions: timeline.orderedRegions, selected: interaction.selected).equatable()
                if let region = inspected {
                    Text("\(region.table) · #\(region.record)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Button("Full record details") { inspectRecord(region) }.controlSize(.mini)
                    if let start = region.start, let player {
                        HStack {
                            Text(String(format: "Detection at %.3f s", start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Jump to detection") { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }.controlSize(.mini)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            MetadataFields(fields: VisualMetadata.explainedFields(DBRow(id: 0, fields: region.fields), table: region.table), table: region.table)
                            if let row = families.first(where: { $0.id == region.table })?.rows.first(where: { $0.referenceID == region.record }) {
                                DecodedPayloadFields(row: row)
                            }
                        }
                    }.frame(height: 170)
                } else {
                    Text("No detection selected.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Hover changes neither the menu's items nor its pinned selection. Keep this
/// potentially large native picker outside the hover update path.
private struct RegionDetectionPicker: View, Equatable {
    let interaction: RegionInteraction
    let revision: UUID
    let regions: [StoredRegion]
    let selected: String?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.interaction === rhs.interaction && lhs.revision == rhs.revision && lhs.selected == rhs.selected
    }
    var body: some View {
        #if DEBUG
        let _ = AnalysisRenderProbe.record("picker")
        #endif
        Picker("Detection", selection: Binding(get: { selected ?? "" }, set: {
            interaction.selected = $0.isEmpty ? nil : $0; interaction.hovered = nil
        })) {
            Text("Hover to inspect…").tag("")
            ForEach(regions) { region in Text("\(region.title) #\(region.record)").tag(region.id) }
        }.labelsHidden().controlSize(.small)
    }
}
