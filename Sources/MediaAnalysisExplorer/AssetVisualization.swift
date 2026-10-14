import SwiftUI
import AppKit
import AVKit
import ExplorerCore

struct AssetVisualization: View {
    @ObservedObject var model: ExplorerModel
    let detail: AssetDetail
    let asset: MediaAsset
    var body: some View {
        AnalysisVisualization(model: model, display: AnalysisDisplay(families: detail.families,
            regionTimeline: detail.regionTimeline, playbackTimeline: detail.playbackTimeline,
            preview: model.preview, mediaURL: detail.media?.originalURL, previewPending: model.busy.contains("preview"),
            previewFailure: model.previewFailure ?? detail.media?.availability, title: "Stored analysis",
            identifier: asset.identifier, stored: detail, asset: asset))
    }
}

/// Both sources use this presentation contract and the same inspection controls.
/// Persistence relationships are supplied only for real stored records.
struct AnalysisDisplay {
    let families: [ResultFamily]
    let regionTimeline: RegionTimeline
    let playbackTimeline: PlaybackTimeline
    let preview: MediaPreview?
    let mediaURL: URL?
    let previewPending: Bool
    let previewFailure: String?
    let title: String
    let identifier: String
    var stored: AssetDetail? = nil
    var asset: MediaAsset? = nil
    var captionFamilies: [ResultFamily]? = nil
    var sourceID = "stored"
}

struct AnalysisVisualization: View {
    @ObservedObject var model: ExplorerModel
    let display: AnalysisDisplay
    private var detail: AssetDetail? { display.stored }
    private var families: [ResultFamily] { display.families }
    @State private var localRecord: DBRow?
    @State private var previewImage: NSImage?
    @State private var ownedInteraction = RegionInteraction()
    var suppliedInteraction: RegionInteraction? = nil
    var suppliedPlayer: AVPlayer? = nil
    private var interaction: RegionInteraction { suppliedInteraction ?? ownedInteraction }
    @State private var referencedRegion: StoredRegion?
    @State private var referencedTimeline: RegionTimeline?
    private let hidden: Set<String> = []
    private let bottomOrigin = true
    private let overlays = true
    @State private var clock = PlaybackClock()
    @State private var player: AVPlayer?
    private var timeline: RegionTimeline { referencedTimeline ?? display.regionTimeline }
    private var regions: [StoredRegion] { timeline.orderedRegions }
    private var captionFamilies: [ResultFamily] { display.captionFamilies ?? families.filter { $0.id.contains("CAPTION") && $0.table.has("ZCAPTION") } }
    private var otherFamilies: [ResultFamily] { families.filter { !captionFamilies.map(\.id).contains($0.id) }.sorted { $0.id < $1.id } }
    var body: some View {
        #if DEBUG
        let _ = AnalysisRenderProbe.record("analysis")
        #endif
        GeometryReader { geometry in
            let height = max(230, min(620, geometry.size.height - (display.preview?.video == true ? 310 : 180)))
            if geometry.size.width >= 720 {
                HSplitView {
                    ScrollView { imageColumn(height: height).padding(12) }
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        inspectorHeader.padding(12)
                        Divider()
                        ScrollView { inspectorResults.padding(12) }
                    }
                        .frame(minWidth: 310, idealWidth: 370, maxWidth: 440, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.18))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        imageColumn(height: min(height, 380))
                        Divider()
                        inspectorColumn
                    }.padding(12)
                }
            }
        }
        .onChange(of: display.preview?.data, initial: true) { _, data in previewImage = data.flatMap(NSImage.init(data:)) }
        .onChange(of: display.preview?.video, initial: true) { _, video in
            stopPlayer()
            if video == true, let url = display.mediaURL {
                let newPlayer = suppliedPlayer ?? AVPlayer(url: url); player = newPlayer
                clock.follow(newPlayer)
            }
        }
        .onDisappear { stopPlayer() }
        .onChange(of: display.sourceID) { _, _ in interaction.reset(); referencedRegion = nil; referencedTimeline = nil; localRecord = nil }
        .popover(item: $localRecord) { row in
            ScrollView { VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Fresh result details").font(.headline); Spacer(); Button("Done") { localRecord = nil } }
                MetadataFields(fields: row.fields)
                DecodedPayloadFields(row: row)
                AnalysisRawFields(row: row)
            }.padding(14) }.frame(width: 430, height: 420)
        }
        .popover(item: Binding(get: { detail == nil ? nil : model.linkedRecords }, set: { model.linkedRecords = $0 })) { records in
            LinkedRecordInspector(model: model, records: records, player: player, inspect: { region in
                referencedRegion = region
                referencedTimeline = RegionTimeline(regions: display.regionTimeline.regions.filter { $0.id != region.id } + [region])
                interaction.selected = region.id; interaction.hovered = nil; model.linkedRecords = nil
            }, done: { model.linkedRecords = nil })
        }
        .popover(item: Binding(get: { detail == nil ? nil : model.thumbnailInspection }, set: { model.thumbnailInspection = $0 })) { value in ThumbnailInspectionView(inspection: value) { model.thumbnailInspection = nil } }
        .onChange(of: display.regionTimeline.regions.count) { _, _ in
            if let region = referencedRegion { referencedTimeline = RegionTimeline(regions: display.regionTimeline.regions.filter { $0.id != region.id } + [region]) }
        }
    }
    private func imageColumn(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewCanvas(height: height)
            if display.preview?.video == true {
                LivePlaybackPanel(model: model, clock: clock, timeline: display.playbackTimeline, player: player, families: detail == nil ? families : [], stored: detail != nil)
                AudioTimelineView(clock: clock, timeline: display.playbackTimeline, player: player)
            }
            if display.preview?.video == true {
                PlaybackReadout(clock: clock)
            }
            if captionFamilies.isEmpty {
                Text(detail == nil ? "No caption returned yet." : "No caption stored for this asset.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(captionFamilies) { family in
                    if family.id == "ZVIDEOSEGMENTCAPTIONRESULT", display.preview?.video == true {
                        DisclosureGroup("All stored segment captions · \(family.count)") { captionCard(family) }.font(.caption)
                    } else { captionCard(family) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func captionCard(_ family: ResultFamily) -> some View {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(VisualMetadata.title(family.id), systemImage: "text.bubble").font(.caption.weight(.semibold))
                            Spacer(); Text("\(family.count) \(family.count == 1 ? "result" : "results")").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(family.rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row["ZCAPTION"] == "NULL" ? "No caption text stored." : row["ZCAPTION"]).font(.body).textSelection(.enabled)
                                HStack(spacing: 12) {
                                    if row["ZCONFIDENCE"] != "NULL" { Text("Confidence \(row["ZCONFIDENCE"])") }
                                    if row["ZISUNSAFE"] != "NULL" { Text("Unsafe flag \(row["ZISUNSAFE"])") }
                                    if let start = VisualMetadata.seconds(row, value: "ZSTARTTIMEVALUE", scale: "ZSTARTTIMESCALE") {
                                        Text("At " + VisualMetadata.compactSeconds(start))
                                        if let player { Button("Jump") { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) } }
                                    }
                                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).controlSize(.mini)
                                if let detail { RecordRelationshipsView(model: model, detail: detail, row: row, table: family.id, player: player) }
                                DisclosureGroup("Caption fields") { MetadataFields(fields: VisualMetadata.meaningfulFields(row).filter { $0.key != "ZCAPTION" }); if row.nativeEvidence != nil { AnalysisRawFields(row: row) } }.font(.caption)
                            }
                        }
                        if family.count > family.rows.count { Text("Showing \(family.rows.count) of \(family.count) captions.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func previewCanvas(height: CGFloat) -> some View {
        if let preview = display.preview, let image = previewImage {
            RegionCanvas(clock: clock, timeline: timeline, preview: preview, image: image, player: player,
                         hidden: hidden, overlays: overlays, bottomOrigin: bottomOrigin, interaction: interaction)
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if display.previewPending {
            ProgressView("Loading local preview…").frame(maxWidth: .infinity).frame(height: height)
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "photo", description: Text(display.previewFailure ?? "No local preview available.")).frame(height: height)
        }
    }
    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 10) { inspectorHeader; inspectorResults }
    }
    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(display.title).font(.headline)
                Spacer()
                Text("\(families.count) families · \(families.reduce(0) { $0 + $1.count }) results").font(.caption2).foregroundStyle(.secondary)
            }
            Text(display.identifier).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).help(display.identifier).textSelection(.enabled)
            if detail?.media?.location != nil {
                Button("Show Geography", systemImage: "map") { model.openMediaGeography() }.controlSize(.small)
            }
            if !regions.isEmpty {
                RegionInspector(interaction: interaction, timeline: timeline, families: families,
                                player: player, inspectRecord: inspectRecord)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var inspectorResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            if families.isEmpty { Text(detail == nil ? "No result rows returned yet." : "No stored result rows yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(otherFamilies) { family in
                if family.id == "ZFEATUREVECTORRESULT" {
                    ImageAppearanceFamilyView(family: family, player: player, loading: model.busy.contains("resultPage"), loadMore: { if detail != nil { model.loadMoreResults(family.id) } })
                } else {
                    CompactResultFamily(model: model, detail: detail, timedClasses: display.playbackTimeline.classes, family: family, regions: timeline.regionsByTable[family.id] ?? [], interaction: interaction, player: player,
                                        loading: model.busy.contains("resultPage"), loadMore: { if detail != nil { model.loadMoreResults(family.id) } }) { region in
                        interaction.selected = region.id
                    }
                }
            }
            if display.preview?.video != true, !display.playbackTimeline.issues.isEmpty { ForEach(display.playbackTimeline.issues, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) } }
            if let detail, let asset = display.asset {
                DisclosureGroup("Asset fields · analysis key \(asset.id)") { MetadataFields(fields: VisualMetadata.explainedFields(DBRow(id: 0, fields: asset.fields), table: "ZASSET")) }.font(.caption)
                PersistenceHistoryView(history: detail.persistence)
                DisclosureGroup("Photos linkage & original") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(detail.media == nil ? "Photos link unavailable" : "Matched Photos record").font(.caption).foregroundStyle(.secondary)
                            InfoButton(title: "Photos linkage", text: detail.linkageNote)
                        }
                        if let media = detail.media {
                            Text(media.availability).font(.caption)
                            Text(media.originalURL?.path ?? media.filename).font(.caption2).textSelection(.enabled)
                            HStack {
                                Button("Reveal", systemImage: "folder") { if let url = media.originalURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                Button("Open Original", systemImage: "eye") { if let url = media.originalURL { NSWorkspace.shared.open(url) } }
                            }.disabled(media.originalURL == nil).controlSize(.small)
                        }
                    }.padding(.top, 6)
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inspectRecord(_ region: StoredRegion) {
        if detail != nil {
            model.inspectReference(ResultReference(table: region.table, field: "Z_PK", value: region.record, label: region.title + " · record " + region.record))
        } else {
            localRecord = families.first { $0.id == region.table }?.rows.first { $0.referenceID == region.record }
        }
    }
    private func stopPlayer() {
        clock.follow(nil)
        player?.pause(); player = nil
    }

}

private struct CompactResultFamily: View {
    @ObservedObject var model: ExplorerModel
    let detail: AssetDetail?
    let timedClasses: [String]
    let family: ResultFamily
    let regions: [StoredRegion]
    let interaction: RegionInteraction
    let player: AVPlayer?
    let loading: Bool
    let loadMore: () -> Void
    let inspect: (StoredRegion) -> Void
    @State private var expanded: Bool
    @State private var visibleCount = 20
    init(model: ExplorerModel, detail: AssetDetail?, timedClasses: [String], family: ResultFamily, regions: [StoredRegion], interaction: RegionInteraction, player: AVPlayer?, loading: Bool, loadMore: @escaping () -> Void, inspect: @escaping (StoredRegion) -> Void) {
        self.model = model; self.detail = detail; self.timedClasses = timedClasses
        self.family = family; self.regions = regions; self.interaction = interaction; self.player = player; self.loading = loading; self.loadMore = loadMore; self.inspect = inspect
        _expanded = State(initialValue: family.count == 1)
    }
    var body: some View {
        #if DEBUG
        let _ = AnalysisRenderProbe.record("family")
        #endif
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if family.id == "ZHUMANPOSERESULT" {
                        Text("Keypoints unavailable in \(family.rows.filter { $0["ZKEYPOINTS"] == "NULL" }.count) of \(family.rows.count) loaded records.").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array(family.rows.prefix(visibleCount))) { row in
                        let matching = regions.filter { $0.record == (row.fields["Z_PK"] ?? String(row.id)) }
                        VStack(alignment: .leading, spacing: 5) {
                            if family.id == "ZSAFETYRESULT" { SensitivityPercentages(row: row) }
                            if family.count > 1 { Text("Record \(row.fields["Z_PK"] ?? String(row.id))").font(.caption.weight(.medium)) }
                            if let text = row.fields["ZTEXT"], text != "NULL" { Text(text).font(.callout).textSelection(.enabled) }
                            if family.id == "ZVIDEOTHUMBNAILRESULT" {
                                HStack {
                                    Text(VisualMetadata.thumbnailSubtitle(row)).font(.caption2.monospacedDigit())
                                    if let start = VisualMetadata.eventTime(row), let player { Button("Jump") { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }.controlSize(.mini) }
                                }.foregroundStyle(.secondary)
                                InlineThumbnailView(model: model, thumbnailID: row["ZTHUMBNAILID"])
                            } else if let start = VisualMetadata.eventTime(row) {
                                HStack {
                                    Text("At " + VisualMetadata.compactSeconds(start)).font(.caption2.monospacedDigit())
                                    if let player { Button("Jump") { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)); if let region = matching.first { inspect(region) } }.controlSize(.mini) }
                                    if let duration = VisualMetadata.seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE") { Text(String(format: "· %.3f s", duration)).font(.caption2.monospacedDigit()) }
                                }.foregroundStyle(.secondary)
                            }
                            ForEach(matching) { region in Button("Inspect \(region.title.lowercased()) #\(region.record)") { inspect(region) }.controlSize(.mini).tint(regionColor(region.table)) }
                            if family.id != "ZVIDEOTHUMBNAILRESULT" {
                                MetadataFields(fields: VisualMetadata.explainedFields(row, table: family.id).filter { $0.key != "ZTEXT" }, table: family.id)
                                DecodedPayloadFields(row: row, peers: family.rows)
                            }
                            if let detail { RecordRelationshipsView(model: model, detail: detail, row: row, table: family.id, player: player) }
                            AnalysisRawFields(row: row)
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RegionSelectionBackground(interaction: interaction, regions: matching.map(\.id), table: family.id))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        if family.rows.count > 1 { Divider() }
                    }
                    if family.count > min(visibleCount, family.rows.count) {
                        HStack {
                            Text("Showing \(min(visibleCount, family.rows.count)) · \(family.rows.count) loaded · \(family.count) results").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if visibleCount < family.rows.count { Button("Show next 20") { visibleCount += 20 }.controlSize(.mini) }
                            if family.rows.count < family.count { Button(loading ? "Loading…" : "Load next 100") { loadMore() }.disabled(loading).controlSize(.mini) }
                        }
                    }
                }.padding(.top, 5)
            } label: {
                HStack {
                    Text(VisualMetadata.title(family.id)).font(.subheadline.weight(.semibold))
                    if let explanation = VisualMetadata.explanation(family.id) {
                        InfoButton(title: VisualMetadata.title(family.id), text: explanation)
                    }
                    Spacer()
                    if timedClasses.contains(family.id) {
                        Button { model.togglePlaybackWatch(family.id) } label: {
                            Image(systemName: model.watchedPlaybackClasses.contains(family.id) ? "pin.fill" : "pin")
                        }.buttonStyle(.plain)
                            .help("Watch \(VisualMetadata.title(family.id)) at the top of At playback, including gaps")
                            .accessibilityLabel("Toggle watch for \(VisualMetadata.title(family.id))")
                    }
                    Text("\(family.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
        }
    }
}

struct DecodedPayloadFields: View {
    let row: DBRow
    var peers: [DBRow] = []
    var body: some View {
        ForEach(row.decoded.keys.sorted(), id: \.self) { column in
            if let decoded = row.decoded[column] {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(column == "ZACTIONSCONFIDENCE" ? "Action probabilities" : VisualMetadata.label(column)).font(.caption.weight(.semibold)).help(column)
                        InfoButton(title: "Decoded payload", text: column == "ZSENSITIVITYSCENERESULTS"
                            ? [decoded.summary, decoded.fields["Label evidence"], decoded.fields["Score interpretation"]].compactMap { $0 }.joined(separator: "\n\n")
                            : decoded.summary)
                    }
                    if column == "ZACTIONSCONFIDENCE", !decoded.actionProbabilities.isEmpty {
                        ForEach(decoded.actionProbabilities) { action in
                            HStack(alignment: .top) {
                                Text(action.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text(action.percentage).monospacedDigit()
                            }.font(.caption)
                        }
                    } else if column == "ZSENSITIVITYSCENERESULTS" {
                        SensitivityScoreFields(fields: decoded.fields)
                    } else { MetadataFields(fields: decoded.fields) }
                    if !decoded.vector.isEmpty { DescriptorVectorView(payload: decoded, column: column, peers: peers) }
                }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

struct SensitivityPercentages: View {
    let row: DBRow
    var body: some View {
        if let payload = row.decoded["ZSENSITIVITYSCENERESULTS"] {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sensitivity scores").font(.caption.weight(.semibold))
                    InfoButton(title: "Sensitivity scores", text: SensitivityLabels.scoreInterpretation)
                }
                SensitivityScoreFields(fields: payload.fields, percentages: true)
            }
        }
    }
}

private struct SensitivityScoreFields: View {
    let fields: [String: String]
    var percentages = false
    private var scoreKeys: [String] {
        fields.keys.filter { $0.contains(" · ID ") || ($0.hasPrefix("ID ") && $0.hasSuffix("(unresolved)")) }.sorted()
    }
    var body: some View {
        ForEach(scoreKeys, id: \.self) { key in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label(for: key))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(value(for: key)).monospacedDigit().textSelection(.enabled)
            }.font(.caption)
        }
    }
    private func label(for key: String) -> String {
        guard percentages else { return key }
        return key.hasPrefix("ID ") ? "Unknown sensitivity label" : key.components(separatedBy: " · ID ")[0]
    }
    private func value(for key: String) -> String {
        guard percentages else { return fields[key] ?? "" }
        guard let raw = fields[key], let score = Double(raw), score.isFinite, (score * 100).isFinite else { return "Unavailable" }
        return String(format: "%.2f%%", score * 100)
    }
}

struct MetadataFields: View {
    let fields: [String: String]
    var table: String? = nil
    var body: some View {
        let presentation = MetadataPresentation(fields: fields)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(presentation.values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 10) {
                    Text(VisualMetadata.label(key)).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 135, alignment: .leading).lineLimit(2)
                    Text(presentation.values[key] ?? "").font(.caption.monospacedDigit()).textSelection(.enabled).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.help(fieldHelp(key))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fieldHelp(_ key: String) -> String {
        let text = key + ": " + (fields[key] ?? "")
        return text
    }
}

func regionColor(_ table: String) -> Color {
    if table.contains("POSE") { return .orange }
    if table.contains("FACE") { return .cyan }
    if table.contains("PETS") { return .green }
    if table.contains("SALIENCY") { return .pink }
    return .purple
}
