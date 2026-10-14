import SwiftUI
import AppKit
import ExplorerCore

struct ExplorerView: View {
    @ObservedObject var model: ExplorerModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundStyle(.teal); Text("MediaAnalysis\nExplorer").font(.headline) }.padding(.horizontal).padding(.top, 20)
                List(Section.allCases, selection: $model.section) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section).padding(.vertical, 6)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Databases read-only", systemImage: "lock.shield").foregroundStyle(.teal)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary)
                    InfoButton(title: "Local analysis", text: "Stored analysis is read locally. Analyze Media runs local analyses on private copies of files you choose. Source databases and originals are not modified; Apple's framework may maintain derived caches.")
                }.padding()
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    message(error, color: .red) { model.errorMessage = nil }
                }
                if let notice = model.notice { message(notice, color: .teal) { model.notice = nil } }
                switch model.section {
                case .media: MediaView(model: model)
                case .analyze: AnalyzeMediaView(model: model.localAnalysis, explorer: model)
                case .processing: ProcessingView(model: model)
                case .caches: CachesView(model: model)
                }
            }.navigationTitle(model.section.rawValue)
        }
        .onChange(of: model.section) { _, _ in model.activateSection() }
        .toolbar {
            ToolbarItem { LocalAnalysisStatus(model: model.localAnalysis) { model.section = .analyze } }
            ToolbarItem { if !model.busy.isEmpty { ProgressView().controlSize(.small) } }
            ToolbarItem {
                if model.section != .analyze {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshCurrentSection() }
                }

            }
        }
        .disclosureGroupStyle(HeaderDisclosureGroupStyle())
    }
    private func message(_ text: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle").foregroundStyle(color)
            Text(text).font(.caption).textSelection(.enabled)
            Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.padding(12).background(color.opacity(0.08))
    }
}

struct MediaView: View {
    @ObservedObject var model: ExplorerModel
    @StateObject private var photoBrowser = PhotoLibraryBrowser()
    private var browserVisible: Bool { model.mediaBrowserVisible }
    private var assetIndex: Int? { model.assets.firstIndex { $0.id == model.selectedAsset } }
    var body: some View {
        Group {
            if !model.sourceReady {
                if model.busy.contains("source") {
                    ProgressView("Reading media library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView { Label("Media analysis unavailable", systemImage: "photo.badge.exclamationmark") } description: {
                        InfoButton(title: "Photos analysis access", text: "The explorer automatically reads the Photos analysis store and resolves its originals. Grant access if macOS blocked the read.")
                    } actions: {
                        Button("Retry") { model.showMedia() }
                        Button("Authorize Library Access…") { model.requestDatabaseAccess() }
                        Button("Full Disk Access Settings") { model.openPrivacySettings() }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if !browserVisible {
                        HStack(spacing: 10) {
                            Button("Back", systemImage: "chevron.left") { model.backToMediaBrowser() }
                                .keyboardShortcut("[", modifiers: .command)
                                .help("Back to media browser")
                            if let asset = model.currentAsset {
                                Text(model.detail?.media?.originalName ?? asset.displayName ?? "Analysis asset")
                                    .font(.headline).lineLimit(1).truncationMode(.middle)
                                    .help(model.detail?.media?.originalName ?? asset.identifier).textSelection(.enabled)
                                Spacer(minLength: 8)
                                if model.selectedPhotoAsset == nil, let index = assetIndex {
                                    Button { stepAsset(-1) } label: { Image(systemName: "chevron.left") }
                                        .disabled(index == 0).help("Previous asset on this page")
                                    Text("\(index + 1) / \(model.assets.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Button { stepAsset(1) } label: { Image(systemName: "chevron.right") }
                                        .disabled(index + 1 >= model.assets.count).help("Next asset on this page")
                                }
                            } else { Text("Media Analysis").font(.headline); Spacer() }
                        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 9)
                        Divider()
                    }
                    Group {
                        if browserVisible {
                            if model.canBrowsePhotos {
                                PhotoLibraryPicker(browser: photoBrowser) { [weak model] identifier in
                                    model?.openPhotoAnalysis(identifier: identifier)
                                }
                            } else {
                                ContentUnavailableView("Photos browser unavailable", systemImage: "photo.on.rectangle", description: Text("Open the Photos analysis library to browse photos and videos."))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else if model.busy.contains("photoSelection") {
                            ProgressView("Finding cached analysis…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let failure = model.photoSelectionFailure {
                            ContentUnavailableView {
                                Label("Cached analysis unavailable", systemImage: "photo.badge.exclamationmark")
                            } description: {
                                Text(failure)
                            } actions: {
                                if let identifier = model.photoSelectionIdentifier {
                                    Button("Retry") { model.openPhotoAnalysis(identifier: identifier) }
                                }
                                Button("Back to Photos") { model.backToMediaBrowser() }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let asset = model.currentAsset {
                            if let detail = model.detail {
                                AssetVisualization(model: model, detail: detail, asset: asset).id(asset.id)
                            } else if model.busy.contains("detail") {
                                ProgressView("Reading result records…").frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ContentUnavailableView("Analysis unavailable", systemImage: "exclamationmark.triangle", description: Text("The stored results could not be read."))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            ContentUnavailableView("Select an asset", systemImage: "photo")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshMediaIfNeeded(); model.loadDetail() }
        .task(id: model.source) {
            while !Task.isCancelled {
                await model.pollMediaChanges()
                do { try await Task.sleep(for: .milliseconds(model.analysisLauncher.isRunning ? 250 : 1_000)) }
                catch { break }
            }
        }
        .onChange(of: model.selectedAsset) { _, _ in
            model.loadDetail()
        }
    }
    private func stepAsset(_ direction: Int) {
        guard let index = assetIndex, model.assets.indices.contains(index + direction) else { return }
        model.selectedAsset = model.assets[index + direction].id
    }
}

struct RawFields: View {
    let fields: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 12) {
                    Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                    Text(fields[key] ?? "NULL").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
