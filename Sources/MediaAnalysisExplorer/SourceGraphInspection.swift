import SwiftUI
import ExplorerCore

struct SourceGraphInspection: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let inspection: FileInspection
    let explanation: CacheExplanation
}
struct SourceGraphInspectionView: View {
    let value: SourceGraphInspection
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Source Model").font(.headline); Spacer(); Button("Done", action: done) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(value.url.path).font(.caption2.monospaced()).textSelection(.enabled)
                    Text(value.explanation.purpose ?? value.explanation.summary).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(value.explanation.dataObservations, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    if let format = value.inspection.metadataFormat { Text(format).font(.caption).foregroundStyle(.teal) }
                    if let hash = value.inspection.metadataSHA256 { MetadataFields(fields: ["Decoded SHA-256": hash]) }
                    if let issue = value.inspection.metadataIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    if let metadata = value.inspection.metadata { Text(metadata).font(.caption.monospaced()).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(width: 850, height: 680)
    }
}
