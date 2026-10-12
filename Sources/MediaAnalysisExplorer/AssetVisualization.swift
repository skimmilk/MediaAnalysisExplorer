import SwiftUI
import AppKit
import AVKit
import ExplorerCore

struct AssetVisualization: View {
    @ObservedObject var model: ExplorerModel
    let detail: AssetDetail
    let asset: MediaAsset
    @State private var previewImage: NSImage?
    @State private var hovered: String?
    @State private var selected: String?
    @State private var referencedRegion: StoredRegion?
    @State private var referencedTimeline: RegionTimeline?
    private let hidden: Set<String> = []
    private let bottomOrigin = true
    private let overlays = true
    @State private var clock = PlaybackClock()
    @State private var player: AVPlayer?
    private var timeline: RegionTimeline { referencedTimeline ?? detail.regionTimeline }
    private var regions: [StoredRegion] {
        timeline.regions.sorted {
            let a = $0.start ?? .infinity, b = $1.start ?? .infinity
            return a == b ? $0.id < $1.id : a < b
        }
    }
    private var captionFamilies: [ResultFamily] { detail.families.filter { $0.id.contains("CAPTION") && $0.table.has("ZCAPTION") } }
    private var otherFamilies: [ResultFamily] { detail.families.filter { !captionFamilies.map(\.id).contains($0.id) }.sorted { $0.id < $1.id } }
    private var activeRegion: String? { selected ?? hovered }
    private var inspected: StoredRegion? { regions.first { $0.id == activeRegion } }
    var body: some View {
        GeometryReader { geometry in
            let height = max(230, min(620, geometry.size.height - (model.preview?.video == true ? 310 : 180)))
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
        .onChange(of: model.preview?.data, initial: true) { _, data in previewImage = data.flatMap(NSImage.init(data:)) }
        .onChange(of: model.preview?.video, initial: true) { _, video in
            stopPlayer()
            if video == true, let url = detail.media?.originalURL {
                let newPlayer = AVPlayer(url: url); player = newPlayer
                clock.follow(newPlayer)
            }
        }
        .onDisappear { stopPlayer() }
        .popover(item: $model.linkedRecords) { records in
            LinkedRecordInspector(model: model, records: records, player: player, inspect: { region in
                referencedRegion = region
                referencedTimeline = RegionTimeline(regions: detail.regionTimeline.regions.filter { $0.id != region.id } + [region])
                selected = region.id; hovered = nil; model.linkedRecords = nil
            }, done: { model.linkedRecords = nil })
        }
        .popover(item: $model.thumbnailInspection) { value in ThumbnailInspectionView(inspection: value) { model.thumbnailInspection = nil } }
        .onChange(of: detail.regionTimeline.regions.count) { _, _ in
            if let region = referencedRegion { referencedTimeline = RegionTimeline(regions: detail.regionTimeline.regions.filter { $0.id != region.id } + [region]) }
        }
    }
    private func imageColumn(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewCanvas(height: height)
            if model.preview?.video == true {
                LivePlaybackPanel(model: model, clock: clock, timeline: detail.playbackTimeline, player: player)
                AudioTimelineView(clock: clock, timeline: detail.playbackTimeline, player: player)
            }
            if model.preview?.video == true {
                PlaybackReadout(clock: clock)
            }
            if captionFamilies.isEmpty {
                Text("No caption stored for this asset.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(captionFamilies) { family in
                    if family.id == "ZVIDEOSEGMENTCAPTIONRESULT", model.preview?.video == true {
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
                                RecordRelationshipsView(model: model, detail: detail, row: row, table: family.id, player: player)
                                DisclosureGroup("Caption fields") { MetadataFields(fields: VisualMetadata.meaningfulFields(row).filter { $0.key != "ZCAPTION" }) }.font(.caption)
                            }
                        }
                        if family.count > family.rows.count { Text("Showing \(family.rows.count) of \(family.count) captions.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func previewCanvas(height: CGFloat) -> some View {
        if let preview = model.preview, let image = previewImage {
            RegionCanvas(clock: clock, timeline: timeline, preview: preview, image: image, player: player,
                         hidden: hidden, overlays: overlays, bottomOrigin: bottomOrigin, hovered: $hovered, selected: $selected)
                .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if model.busy.contains("preview") {
            ProgressView("Loading local preview…").frame(maxWidth: .infinity).frame(height: height)
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "photo", description: Text(model.previewFailure ?? detail.media?.availability ?? "No linked local original.")).frame(height: height)
        }
    }
    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 10) { inspectorHeader; inspectorResults }
    }
    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stored analysis").font(.headline)
                Spacer()
                Text("\(detail.families.count) families · \(detail.families.reduce(0) { $0 + $1.count }) results").font(.caption2).foregroundStyle(.secondary)
            }
            Text(asset.identifier).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).help(asset.identifier).textSelection(.enabled)
            if detail.media?.location != nil {
                Button("Show Geography", systemImage: "map") { model.openMediaGeography() }.controlSize(.small)
            }
            if !regions.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(inspected?.title ?? "Region inspector", systemImage: "viewfinder").font(.subheadline.weight(.semibold))
                            InfoButton(title: "Region inspector", text: "Hover a box on the image, click to pin, or choose a detection above.")
                            Spacer()
                            if selected != nil { Text("Pinned").font(.caption2).foregroundStyle(.orange); Button("Unpin") { selected = nil; hovered = nil }.controlSize(.mini) }
                        }
                        Picker("Detection", selection: Binding(get: { selected ?? "" }, set: { selected = $0.isEmpty ? nil : $0; hovered = nil })) {
                            Text("Hover to inspect…").tag("")
                            ForEach(regions) { region in Text("\(region.title) #\(region.record)").tag(region.id) }
                        }.labelsHidden().controlSize(.small)
                        if let region = inspected {
                            Text("\(region.table) · #\(region.record)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Button("Full record details") { model.inspectReference(ResultReference(table: region.table, field: "Z_PK", value: region.record, label: region.title + " · record " + region.record)) }.controlSize(.mini)
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
                                    if let row = detail.families.first(where: { $0.id == region.table })?.rows.first(where: { ($0.fields["Z_PK"] ?? String($0.id)) == region.record }) {
                                        DecodedPayloadFields(row: row)
                                    }
                                }
                            }
                                .frame(height: 170)
                        } else {
                            Text("No detection selected.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                        }
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var inspectorResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            if detail.families.isEmpty { Text("No stored result rows yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(otherFamilies) { family in
                if family.id == "ZFEATUREVECTORRESULT" {
                    ImageAppearanceFamilyView(family: family, player: player, loading: model.busy.contains("resultPage"), loadMore: { model.loadMoreResults(family.id) })
                } else {
                    CompactResultFamily(model: model, detail: detail, family: family, regions: regions.filter { $0.table == family.id }, active: activeRegion, player: player,
                                        loading: model.busy.contains("resultPage"), loadMore: { model.loadMoreResults(family.id) }) { region in
                        selected = region.id
                    }
                }
            }
            DisclosureGroup("Asset fields · analysis key \(asset.id)") { MetadataFields(fields: VisualMetadata.explainedFields(DBRow(id: 0, fields: asset.fields), table: "ZASSET")) }.font(.caption)
            if model.preview?.video != true, !detail.playbackTimeline.issues.isEmpty { ForEach(detail.playbackTimeline.issues, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) } }
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
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stopPlayer() {
        clock.follow(nil)
        player?.pause(); player = nil
    }

}

private struct CompactResultFamily: View {
    @ObservedObject var model: ExplorerModel
    let detail: AssetDetail
    let family: ResultFamily
    let regions: [StoredRegion]
    let active: String?
    let player: AVPlayer?
    let loading: Bool
    let loadMore: () -> Void
    let inspect: (StoredRegion) -> Void
    @State private var expanded: Bool
    @State private var visibleCount = 20
    init(model: ExplorerModel, detail: AssetDetail, family: ResultFamily, regions: [StoredRegion], active: String?, player: AVPlayer?, loading: Bool, loadMore: @escaping () -> Void, inspect: @escaping (StoredRegion) -> Void) {
        self.model = model; self.detail = detail
        self.family = family; self.regions = regions; self.active = active; self.player = player; self.loading = loading; self.loadMore = loadMore; self.inspect = inspect
        _expanded = State(initialValue: family.count == 1)
    }
    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(family.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if family.id == "ZHUMANPOSERESULT" {
                        Text("Keypoints not stored in \(family.rows.filter { $0["ZKEYPOINTS"] == "NULL" }.count) of \(family.rows.count) loaded rows.").font(.caption2).foregroundStyle(.secondary)
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
                            RecordRelationshipsView(model: model, detail: detail, row: row, table: family.id, player: player)
                            DisclosureGroup("Raw fields · \(row.fields.values.filter { $0 == "NULL" }.count) NULL") { MetadataFields(fields: row.fields) }.font(.caption2)
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(matching.contains { $0.id == active } ? regionColor(family.id).opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        if family.rows.count > 1 { Divider() }
                    }
                    if family.count > min(visibleCount, family.rows.count) {
                        HStack {
                            Text("Showing \(min(visibleCount, family.rows.count)) · \(family.rows.count) loaded · \(family.count) stored").font(.caption2).foregroundStyle(.secondary)
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
                    if detail.playbackTimeline.classes.contains(family.id) {
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
