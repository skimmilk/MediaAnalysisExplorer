import SwiftUI
import AppKit
import ExplorerCore

struct InlineThumbnailView: View {
    @ObservedObject var model: ExplorerModel
    let thumbnailID: String
    @State private var image: NSImage?
    @State private var failure: String?
    private var requestID: String { model.source.libraryPath + ":" + (model.currentAsset?.identifier ?? "") + ":" + thumbnailID }
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 150)
                    .accessibilityLabel("Stored video thumbnail " + thumbnailID)
                    .accessibilityIdentifier("stored-video-thumbnail")
            } else if let failure {
                Text("Thumbnail unavailable").font(.caption2).foregroundStyle(.secondary).help(failure)
            } else {
                ProgressView("Loading thumbnail…").controlSize(.small).font(.caption2)
            }
        }
        .task(id: requestID) {
            image = nil; failure = nil
            do {
                let preview = try await model.readInlineThumbnail(thumbnailID)
                try Task.checkCancellation()
                guard let loaded = NSImage(data: preview.data) else { throw ExplorerError("Unreadable thumbnail image") }
                image = loaded
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

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
