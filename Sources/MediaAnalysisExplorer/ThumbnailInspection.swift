import SwiftUI
import AppKit
import ExplorerCore

struct ThumbnailInspection: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let preview: MediaPreview
}
struct ThumbnailInspectionView: View {
    let inspection: ThumbnailInspection
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Stored thumbnail derivative").font(.headline); InfoButton(title: "Thumbnail provenance", text: "A thumbnail saved by mediaanalysisd for this asset."); Spacer(); Button("Done", action: done) }
            if let image = NSImage(data: inspection.preview.data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 400) }
            Text("\(inspection.preview.width) × \(inspection.preview.height) preview pixels").font(.caption.monospacedDigit())
            Text(inspection.url.path).font(.caption2).textSelection(.enabled)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([inspection.url]) }
        }.padding(16).frame(width: 580)
    }
}
