import SwiftUI
import AVFoundation
import ExplorerCore

struct RecordRelationshipsView: View {
    @ObservedObject var model: ExplorerModel
    let detail: AssetDetail
    let row: DBRow
    let table: String
    let player: AVPlayer?
    private var intervalLinks: [ResultReference] {
        guard table.contains("CAPTION") || table.contains("EMBEDDING"), let start = VisualMetadata.eventTime(row),
              let duration = VisualMetadata.seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE") else { return [] }
        return detail.playbackTimeline.records.filter {
            ($0.kind == .caption || $0.table == "ZVIDEOEMBEDDINGRESULT" || $0.table == "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT") && $0.table != table &&
            abs($0.start - start) < 0.000001 && abs(($0.duration ?? -1) - duration) < 0.000001
        }.map { ResultReference(table: $0.table, field: "Z_PK", value: $0.row["Z_PK"], label: $0.title + " · same stored interval") }
    }
    var body: some View {
        let explicit = ResultReferences.links(row: row, table: table)
        let linked = explicit + intervalLinks
        if !linked.isEmpty {
            DisclosureGroup("Related analysis · \(linked.count)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(linked) { link in
                        Button(link.label) { model.inspectReference(link) }.controlSize(.small)
                            .disabled(model.busy.contains("linkedRecords"))
                    }
                    InfoButton(title: "Related analysis", text: "Records linked to this asset and its selected result.")
                }.padding(.top, 6)
            }.font(.caption)
        }
        if table == "ZVIDEOTHUMBNAILRESULT", row["ZTHUMBNAILID"] != "NULL" {
            Button("Preview stored derivative · " + row["ZTHUMBNAILID"]) { model.inspectThumbnail(row["ZTHUMBNAILID"]) }.controlSize(.small).disabled(model.busy.contains("thumbnail"))
        }
    }
}

struct LinkedRecordInspector: View {
    @ObservedObject var model: ExplorerModel
    let records: LinkedRecords
    let player: AVPlayer?
    let inspect: (StoredRegion) -> Void
    let done: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(records.reference.label).font(.headline); Spacer(); Button("Done", action: done) }
                Text("Same-asset lookup · \(records.reference.table) · \(records.reference.field)=\(records.reference.value)").font(.caption2.monospaced()).textSelection(.enabled)
                if records.rows.isEmpty { Text("No matching stored record was found for this asset.").foregroundStyle(.secondary) }
                if records.rows.count == 100 { Text("Showing at most 100 matches; additional matching records may exist.").font(.caption).foregroundStyle(.secondary) }
                ForEach(VisualMetadata.chronologicalRows(records.rows)) { row in
                    GroupBox("Record " + row["Z_PK"]) {
                        VStack(alignment: .leading, spacing: 9) {
                            if records.reference.table == "ZVIDEOTHUMBNAILRESULT" {
                                Text(VisualMetadata.thumbnailSubtitle(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                InlineThumbnailView(model: model, thumbnailID: row["ZTHUMBNAILID"])
                            }
                            if records.reference.table == "ZSAFETYRESULT" { SensitivityPercentages(row: row) }
                            if records.reference.table != "ZFEATUREVECTORRESULT", let start = VisualMetadata.eventTime(row), let player { Button(String(format: "Jump to %.3f s", start)) { player.seek(to: CMTime(seconds: max(0, start), preferredTimescale: 600)) } }
                            let family = ResultFamily(table: TableSchema(name: records.reference.table, columns: [:]), count: 1, rows: [row])
                            ForEach(VisualMetadata.regions(family)) { region in Button("Pin " + region.title) { inspect(region) } }
                            if records.reference.table == "ZFEATUREVECTORRESULT" {
                                ImageAppearanceRecordView(row: row, player: player)
                            } else if records.reference.table != "ZVIDEOTHUMBNAILRESULT" {
                                MetadataFields(fields: VisualMetadata.explainedFields(row, table: records.reference.table))
                                DecodedPayloadFields(row: row, peers: records.rows)
                            }
                            ForEach(ResultReferences.links(row: row, table: records.reference.table)) { reference in
                                Button(reference.label) { model.inspectReference(reference) }.disabled(model.busy.contains("linkedRecords"))
                            }
                            if records.reference.table == "ZVIDEOTHUMBNAILRESULT", row["ZTHUMBNAILID"] != "NULL" {
                                Button("Preview stored derivative") { model.inspectThumbnail(row["ZTHUMBNAILID"]) }
                            }
                            if records.reference.table != "ZFEATUREVECTORRESULT" {
                                DisclosureGroup("Raw fields") { MetadataFields(fields: row.fields) }
                            }
                        }.padding(5)
                    }
                }
            }.padding(14)
        }.frame(width: 520, height: 620)
    }
}
