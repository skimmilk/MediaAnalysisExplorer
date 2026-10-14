import AppKit
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import ExplorerCore

/// Pinned in the main window toolbar, including while browsing other sections.
struct LocalAnalysisStatus: View {
    @ObservedObject var model: LocalAnalysisModel
    var show: () -> Void
    var body: some View {
        LocalProgressIndicator(progress: model.progress, cancel: model.cancel, show: show)
    }
}

private struct LocalProgressIndicator: View {
    @ObservedObject var progress: LocalAnalysisProgress
    let cancel: () -> Void
    let show: () -> Void
    var body: some View {
        if progress.running {
            HStack(spacing: 10) {
                Button(action: show) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(progress.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(progress.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }.font(.caption)
                        ProgressView(value: progress.fraction).tint(.teal).controlSize(.small)
                        Text(progress.phase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(width: 230)
                }.buttonStyle(.plain).help("Show analysis · progress across analysis passes")
                Button(action: cancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Stop analysis; retain completed results")
            }.padding(.horizontal, 6)
        }
    }
}

struct AnalyzeMediaView: View {
    @ObservedObject var model: LocalAnalysisModel
    let explorer: ExplorerModel
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.current?.name ?? "Analyze your media").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("Drop one image or video here").font(.caption).foregroundStyle(.secondary)
                Button("Choose Media…", systemImage: "plus") { model.choose() }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if let error = model.dropError {
                HStack { Text(error).font(.caption); Spacer(); Button { model.dropError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .padding(12).background(.orange.opacity(0.1))
            }
            if model.current == nil {
                ContentUnavailableView {
                    Label("Drop media to analyze", systemImage: "photo.badge.bolt")
                } description: {
                    Text("An image or video starts analyzing immediately. Explore captions, scenes, detections and features alongside a preview.")
                    Text("Images up to 40 megapixels · Videos up to 2 minutes · Files up to 256 MB")
                        .font(.caption).padding(.top, 8)
                } actions: { Button("Choose Media…") { model.choose() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let run = model.current {
                    LocalMediaInspector(explorer: explorer, run: run).id(run.id)
                }
            }
        }
        .background(targeted ? Color.teal.opacity(0.07) : Color.clear)
        .overlay { if targeted { RoundedRectangle(cornerRadius: 8).strokeBorder(.teal, lineWidth: 3).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: model.acceptDrop)
    }
}

/// Local admission/progress is distinct; every analysis display control lives
/// in AnalysisVisualization, shared with the Photos browser.
struct LocalMediaInspector: View {
    @ObservedObject var explorer: ExplorerModel
    let run: LocalMediaRun
    var display: AnalysisDisplay {
        AnalysisDisplay(families: run.presentation.families,
            regionTimeline: run.presentation.regionTimeline, playbackTimeline: run.presentation.playbackTimeline,
            preview: run.preview, mediaURL: run.url,
            previewPending: run.state == .preparing, previewFailure: run.previewError,
            title: "Fresh analysis", identifier: run.name, sourceID: run.id.uuidString)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = run.error ?? run.reports.compactMap(\.failure).first {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            AnalysisVisualization(model: explorer, display: display)
            if !run.reports.isEmpty {
                DisclosureGroup("Analysis details & native evidence") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(run.reports) { report in
                                DisclosureGroup(report.pass.title) {
                                    AnalysisValueTree(value: report.raw, depth: 0)
                                }
                            }
                        }.padding(12)
                    }.frame(maxHeight: 230)
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

struct AnalysisRawFields: View {
    let row: AnalysisRecord
    var body: some View {
        if let native = row.nativeEvidence {
            DisclosureGroup("Native fields & display mapping") {
                VStack(alignment: .leading, spacing: 8) {
                    if !row.analysisSources.isEmpty {
                        Text("Analysis sources: " + row.analysisSources.joined(separator: ", "))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    AnalysisValueTree(value: native, depth: 0)
                    DisclosureGroup("Adapted display fields") {
                        MetadataFields(fields: row.fields)
                        MetadataFields(fields: row.fieldOrigins)
                    }
                }
            }.font(.caption2)
        } else {
            DisclosureGroup("Raw fields · \(row.fields.values.filter { $0 == "NULL" }.count) NULL") {
                MetadataFields(fields: row.fields)
            }.font(.caption2)
        }
    }
}

/// A bounded fallback ensures new/unknown family structures remain inspectable
/// without an app-specific decoder. Binary payloads are never dumped as base64.
struct AnalysisValueTree: View {
    let value: AnalysisValue
    let depth: Int
    @State private var limit = 30
    var body: some View {
        Group {
            if value["class"].text == "NSData" {
                VStack(alignment: .leading, spacing: 3) {
                    Label(value.summary, systemImage: "number.square")
                    if let digest = value["sha256"].text { Text("SHA-256 " + digest).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(2) }
                    if value["payloadOmitted"] == .bool(true) { Text("Payload omitted by output limit").foregroundStyle(.orange) }
                }
            } else if depth >= 10 { Text("Nested value · inspection depth limit").foregroundStyle(.secondary) }
            else if !value.items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(value.items.prefix(limit).enumerated()), id: \.offset) { index, item in
                        DisclosureGroup("Item \(index + 1) · \(item.summary.prefix(90))") {
                            AnalysisValueTree(value: item, depth: depth + 1).padding(.leading, 6)
                        }
                    }
                    if value.items.count > limit { Button("Show more items") { limit += 30 } }
                    if value.isTruncated { Text("Truncated by worker limits").foregroundStyle(.orange) }
                }
            } else if !value.object.isEmpty {
                let keys = value.object.keys.sorted().filter { $0 != "base64" }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(keys.prefix(limit)), id: \.self) { key in
                        let item = value[key]
                        if !item.object.isEmpty || !item.items.isEmpty {
                            DisclosureGroup("\(VisualMetadata.label(key)) · \(item.summary.prefix(90))") {
                                AnalysisValueTree(value: item, depth: depth + 1).padding(.leading, 6)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(VisualMetadata.label(key)).foregroundStyle(.secondary)
                                Text(item.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if keys.count > limit { Button("Show more fields") { limit += 30 } }
                }
            } else { Text(value.summary).textSelection(.enabled) }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
