import SwiftUI
import AVFoundation
import ExplorerCore

/// Only this compact panel observes playback. Its record content is unchanged
/// between interval boundaries, avoiding 30 Hz metadata-formatting work.
struct LivePlaybackPanel: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject var clock: PlaybackClock
    let timeline: PlaybackTimeline
    let player: AVPlayer?
    var families: [ResultFamily] = []
    var stored = true
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("At playback", systemImage: "play.circle").font(.caption.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(Array(Set(timeline.classes + model.watchedPlaybackClasses)).sorted { VisualMetadata.title($0) < VisualMetadata.title($1) }, id: \.self) { table in
                        Button { model.togglePlaybackWatch(table) } label: {
                            Label(VisualMetadata.title(table), systemImage: model.watchedPlaybackClasses.contains(table) ? "pin.fill" : "pin")
                        }
                    }
                } label: { Label("Watch classes", systemImage: "pin") }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    .help("Pin a class below the video. Its current values remain visible through gaps and across clips.")
                Text(String(format: "%.2f s", clock.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                InfoButton(title: "Playback timing", text: "Analysis results follow playback. Click a timed result to jump to that point.")
            }
            PlaybackMomentContent(model: model, revision: timeline.revision, records: timeline.active(at: clock.seconds), watching: model.watchedPlaybackClasses, available: timeline.classes, player: player, families: families, stored: stored).equatable()
            if !timeline.issues.isEmpty {
                DisclosureGroup("Timing coverage is partial") {
                    ForEach(timeline.issues, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                }.font(.caption2)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PlaybackMomentContent: View, Equatable {
    @ObservedObject var model: ExplorerModel
    let revision: UUID
    let records: [TimedResult]
    let watching: [String]
    let available: [String]
    let player: AVPlayer?
    let families: [ResultFamily]
    let stored: Bool
    private let playerIdentity: ObjectIdentifier?
    private let modelIdentity: ObjectIdentifier
    @State private var inspected: TimedResult?
    init(model: ExplorerModel, revision: UUID, records: [TimedResult], watching: [String], available: [String], player: AVPlayer?, families: [ResultFamily], stored: Bool) {
        self.model = model; modelIdentity = ObjectIdentifier(model)
        self.revision = revision; self.records = records; self.watching = watching; self.available = available; self.player = player
        playerIdentity = player.map(ObjectIdentifier.init)
        self.families = families; self.stored = stored
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stored == rhs.stored && lhs.watching == rhs.watching && lhs.available == rhs.available && lhs.revision == rhs.revision && lhs.records.map(\.id) == rhs.records.map(\.id) && lhs.playerIdentity == rhs.playerIdentity && lhs.modelIdentity == rhs.modelIdentity
    }
    private var captions: [TimedResult] { records.filter { $0.kind == .caption && !watching.contains($0.table) } }
    private var audio: [TimedResult] { records.filter { $0.kind == .audio && !watching.contains($0.table) } }
    private var others: [TimedResult] { records.filter { $0.kind != .caption && $0.kind != .audio && !watching.contains($0.table) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !watching.isEmpty {
                Text("Watching · saved across media").font(.caption2).foregroundStyle(.secondary)
                ForEach(TimedResultGroup.grouped(records.filter { watching.contains($0.table) }, watching: watching)) { group in
                    classCard(group, watched: true)
                }
                Divider()
            }
            if captions.isEmpty && !watching.contains(where: { $0.contains("CAPTION") }) {
                Text("No active segment caption.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(captions) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.caption ?? (record.row["ZTEXT"] == "NULL" ? "No caption text stored." : record.row["ZTEXT"])).font(.callout).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Text(record.title).font(.caption2).foregroundStyle(.secondary)
                            Text(timeRange(record)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            if record.row["ZCONFIDENCE"] != "NULL" { Text("Confidence \(shortNumber(record.row["ZCONFIDENCE"]))").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            watchButton(record.table)
                            Button { inspected = record } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Inspect caption fields")
                        }
                    }
                }
            }
            HStack { Text(watching.contains(where: { PlaybackTimeline.audioTables.contains($0) }) ? "Other audio events" : "Audio events").font(.caption.weight(.semibold)); Spacer(); Text("Analysis predictions").font(.caption2).foregroundStyle(.secondary) }
            if audio.isEmpty {
                Text("No other active audio event.").font(.caption2).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))], alignment: .leading, spacing: 5) {
                    ForEach(audio) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { watchButton(record.table); Text(record.title).font(.caption.weight(.semibold)) }
                            Button { inspected = record } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Image(systemName: "waveform"); Text(record.title).fontWeight(.semibold); Spacer();
                                    if record.row["ZCONFIDENCE"] != "NULL" { Text(shortNumber(record.row["ZCONFIDENCE"])).monospacedDigit() }
                                }
                                Text(timeRange(record)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }.font(.caption).padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.teal.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).help("Inspect \(record.title.lowercased()) fields and interval")
                        }
                    }
                }
            }
            if !others.isEmpty {
                DisclosureGroup("Other active timed analysis · \(TimedResultGroup.grouped(others).count) classes · \(others.count) records") {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(TimedResultGroup.grouped(others)) { group in classCard(group, watched: false) }
                    }.padding(.top, 7)
                }.font(.caption)
            }
        }
        .popover(item: $inspected) { record in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(record.title).font(.headline); Spacer(); Button("Done") { inspected = nil }.controlSize(.small) }
                    if record.table != "ZFEATUREVECTORRESULT" { Text(timeRange(record)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if let explanation = VisualMetadata.explanation(record.table) {
                        InfoButton(title: record.title, text: explanation)
                    }
                    if let caption = record.caption { Text(caption).textSelection(.enabled) }
                    if record.table == "ZVIDEOTHUMBNAILRESULT" {
                        Text(VisualMetadata.thumbnailSubtitle(record.row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        InlineThumbnailView(model: model, thumbnailID: record.row["ZTHUMBNAILID"])
                    }
                    if record.table == "ZFEATUREVECTORRESULT" {
                        if let row = (families.isEmpty ? model.detail?.families ?? [] : families).first(where: { $0.id == record.table })?.rows.first(where: { $0.referenceID == record.row.referenceID }) {
                            ImageAppearanceRecordView(row: row, player: player)
                        } else {
                            Text("Sample at " + ImageFeatureSamples.timeLabel(record.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        if record.table == "ZSAFETYRESULT" { SensitivityPercentages(row: record.row) }
                        if let player { Button("Jump to start") { player.seek(to: CMTime(seconds: max(0, record.start), preferredTimescale: 600)) }.controlSize(.small) }
                        if record.table != "ZVIDEOTHUMBNAILRESULT" {
                            MetadataFields(fields: record.fields)
                            DecodedPayloadFields(row: record.row)
                        }
                    }
                    if stored { Button(record.table == "ZFEATUREVECTORRESULT" ? "Open color sample" : "Full decoded record") {
                        inspected = nil
                        model.inspectReference(ResultReference(table: record.table, field: "Z_PK", value: record.row["Z_PK"], label: record.title + " · record " + record.row["Z_PK"]))
                    }.disabled(model.busy.contains("linkedRecords")) }
                    if record.table != "ZFEATUREVECTORRESULT" {
                        AnalysisRawFields(row: record.row)
                    }
                }.padding(14)
            }.frame(width: 430, height: 420)
        }
    }
    private func watchButton(_ table: String) -> some View {
        Button { model.togglePlaybackWatch(table) } label: {
            Image(systemName: watching.contains(table) ? "pin.fill" : "pin")
        }.buttonStyle(.plain).foregroundStyle(watching.contains(table) ? Color.teal : Color.secondary)
            .help(watching.contains(table) ? "Stop watching this class" : "Watch this class at the top, including gaps")
            .accessibilityLabel(watching.contains(table) ? "Unwatch \(VisualMetadata.title(table))" : "Watch \(VisualMetadata.title(table))")
    }
    private func classCard(_ group: TimedResultGroup, watched: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(group.title).font(.caption.weight(.semibold))
                Text("\(group.records.count) active").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if watched {
                    Button { model.movePlaybackWatchToTop(group.table) } label: { Image(systemName: "arrow.up.to.line") }
                        .buttonStyle(.plain).help("Move this watched class first")
                }
                watchButton(group.table)
            }
            if group.records.isEmpty {
                Text(available.contains(group.table) ? "No active result at this time." : "No timed results of this class in this media.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(group.records) { record in
                    Button { inspected = record } label: {
                        HStack(alignment: .top, spacing: 8) {
                            if group.table == "ZCLASSIFICATIONRESULT" {
                                Text(record.fields["Scene label · installed taxonomy"] ?? "Scene ID \(record.row["ZSCENEID"])")
                                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                if record.row["ZCONFIDENCE"] != "NULL" {
                                    Text(shortNumber(record.row["ZCONFIDENCE"])).font(.caption.monospacedDigit())
                                }
                            } else {
                                Text(record.caption ?? record.summary).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(timeRange(record)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Inspect fields and interval; scene confidence values are not normalized together")
                }
            }
        }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(watched ? Color.teal.opacity(0.08) : Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
    private func timeRange(_ record: TimedResult) -> String {
        if let end = record.end { return String(format: "%.2f–%.2f s", record.start, end) }
        return String(format: "At %.2f s", record.start)
    }
    private func shortNumber(_ string: String) -> String { Double(string).map { String(format: "%.4f", $0) } ?? string }
}
