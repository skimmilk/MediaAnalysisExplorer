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
                    InfoButton(title: "Local read-only analysis", text: "Analysis is read locally. Source databases, cache files and originals are not modified.")
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
                case .processing: ProcessingView(model: model)
                case .caches: CachesView(model: model)
                }
            }.navigationTitle(model.section.rawValue)
        }
        .onChange(of: model.section) { _, _ in model.activateSection() }
        .toolbar {
            ToolbarItem { if !model.busy.isEmpty { ProgressView().controlSize(.small) } }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshCurrentSection() }

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
                    HStack(spacing: 10) {
                        Button(browserVisible ? "Hide Browser" : "Browse Media", systemImage: "rectangle.leftthird.inset.filled") { model.mediaBrowserVisible.toggle() }
                            .keyboardShortcut("b", modifiers: [.command, .shift])
                            .disabled(model.currentAsset == nil)
                        if let asset = model.currentAsset {
                            Text(model.detail?.media?.originalName ?? asset.displayName ?? "Analysis asset")
                                .font(.headline).lineLimit(1).truncationMode(.middle)
                                .help(model.detail?.media?.originalName ?? asset.identifier).textSelection(.enabled)
                            Spacer(minLength: 8)
                            if let index = assetIndex {
                                Button { stepAsset(-1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(index == 0).help("Previous asset on this page")
                                Text("\(index + 1) / \(model.assets.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button { stepAsset(1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(index + 1 >= model.assets.count).help("Next asset on this page")
                            }
                        } else { Text("Select media to inspect").font(.headline); Spacer() }
                    }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 9)
                    Divider()
                    HSplitView {
                        if browserVisible { mediaBrowser.frame(minWidth: 240, idealWidth: 280, maxWidth: 340) }
                        if let asset = model.currentAsset {
                            if let detail = model.detail {
                                AssetVisualization(model: model, detail: detail, asset: asset).id(asset.id)
                            } else { ProgressView("Reading result records…").frame(maxWidth: .infinity, maxHeight: .infinity) }
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
    private var mediaBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Identifier or filename", text: $model.search).textFieldStyle(.plain) }.padding(10)
            if let warning = model.photosWarning { Text(warning).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10).padding(.bottom, 6) }
            Divider()
            if model.assets.isEmpty && !model.busy.contains("media") { ContentUnavailableView("No matching assets", systemImage: "photo", description: Text("No compatible rows were found in this source.")) }
            else {
                List(model.assets, selection: $model.selectedAsset) { asset in
                    VStack(alignment: .leading, spacing: 3) {
                        if let name = asset.displayName { Text(name).font(.subheadline.weight(.medium)).lineLimit(2) }
                        Text(asset.identifier).font(.system(.caption2, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Text("Analysis key \(asset.id)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 2).tag(asset.id)
                }.listStyle(.inset)
            }
            HStack {
                Button { model.previousAssets() } label: { Image(systemName: "chevron.left") }.disabled(model.pageCursors.count <= 1 || model.busy.contains("media")).help("Previous page")
                Spacer(); Text("Page \(model.pageCursors.count) · \(model.assets.count) assets").font(.caption2).foregroundStyle(.secondary)
                if model.busy.contains("media") { ProgressView().controlSize(.mini) }
                Spacer(); Button { model.nextAssets() } label: { Image(systemName: "chevron.right") }.disabled(!model.hasNext || model.busy.contains("media")).help("Next page")
            }.controlSize(.small).padding(10)
        }
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
