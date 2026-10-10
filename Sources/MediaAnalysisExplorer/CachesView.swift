import SwiftUI
import AppKit
import ExplorerCore

struct CachesView: View {
    @ObservedObject var model: ExplorerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("Cache view", selection: $model.cacheView) {
                    ForEach(CacheViewMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 560)
                Spacer()
                if model.busy.contains("cacheKnowledge") { ProgressView("Reading descriptions…").controlSize(.small) }
                Button("Rescan", systemImage: "arrow.clockwise") { model.scan() }.disabled(model.busy.contains("scan"))
                if model.busy.contains("scan") { Button("Cancel") { model.stopScan() } }
            }
            if model.cacheView != .taxonomy && model.cacheView != .geography {
                cacheStatus
                HStack(spacing: 24) {
                    metric("Files", model.cacheAccessFailure == nil ? String(model.files.count) : "Unavailable")
                    metric("Bundles", model.cacheAccessFailure == nil ? String(model.cacheBundles.count) : "Unavailable")
                    metric("Logical size", model.cacheAccessFailure == nil ? bytes(model.logicalBytes) : "Unavailable")
                    metric("Allocated size", model.cacheAccessFailure == nil ? bytes(model.allocatedBytes) : "Unavailable")
                    Spacer()
                    Text("\(model.inaccessible) unreadable entries").font(.caption).foregroundStyle(.secondary).help(model.cacheRoot)
                }
                Text(model.scanNote).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            switch model.cacheView {
            case .files: CacheFilesView(model: model)
            case .bundles: CacheBundlesView(model: model)
            case .taxonomy: TaxonomyBrowserView(model: model)
            case .geography: GeographyView(model: model, geography: model.geography)
            }
        }.padding(18)
        .onChange(of: model.selectedFile) { _, _ in if model.cacheView == .files { model.inspect() } }
        .task { model.ensureCacheLoaded(); if model.cacheView == .taxonomy { model.ensureTaxonomySources() } }
        .sheet(item: $model.sourceGraphInspection) { value in SourceGraphInspectionView(value: value) { model.sourceGraphInspection = nil } }
    }
    @ViewBuilder private var cacheStatus: some View {
        if let failure = model.cacheAccessFailure {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure.isPermissionDenied ? "Cache access unavailable" : "Cache scan failed", systemImage: "lock.trianglebadge.exclamationmark").font(.headline)
                    Text(failure.path).font(.caption).textSelection(.enabled)
                    if failure.isPermissionDenied {
                        HStack {
                            Button("Request Cache Access…") { model.requestCacheAccess() }
                            Button("Full Disk Access Settings") { model.openPrivacySettings() }
                            Button("Show App in Finder") { model.revealApp() }
                            InfoButton(title: "Cache authorization", text: "Approve the cache folder in the native picker. If macOS still denies access, enable this app in Full Disk Access and reopen it. Installed taxonomy resources can be browsed independently of this cache folder.")
                        }
                    } else { Button("Retry") { model.scan() } }
                    DisclosureGroup("Technical error") { Text(failure.detail).font(.caption.monospaced()).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.monospacedDigit()); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
}

struct CacheFilesView: View {
    @ObservedObject var model: ExplorerModel
    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search files, models or descriptions", text: $model.cacheSearch).textFieldStyle(.roundedBorder)
                Picker("File type", selection: $model.cacheFileType) {
                    Text("All files").tag("all")
                    Text("E5 programs").tag("e5")
                }.pickerStyle(.segmented)
                Text("\(model.visibleFiles.count) matching files").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                List(model.visibleFiles, selection: $model.selectedFile) { file in CacheFileRow(file: file, explanation: model.cacheExplanations[file.id], bundleName: model.cacheBundleName(for: file)).tag(file.id) }.listStyle(.inset)
            }.frame(minWidth: 300, idealWidth: 390, maxWidth: 540).padding(.trailing, 10)
            ScrollView {
                if let file = model.currentFile { CacheFileInspector(model: model, file: file).padding(16) }
                else { ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass") }
            }.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
struct CacheFileRow: View {
    let file: InventoryFile
    let explanation: CacheExplanation?
    let bundleName: String?
    var body: some View {
        let known = explanation ?? CacheExplanation.describe(url: file.url, metadata: nil)
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(file.url.lastPathComponent).lineLimit(1); Spacer(); Text(bytes(file.logicalBytes)).font(.caption).foregroundStyle(.secondary) }
            Text(known.role).font(.caption).foregroundStyle(.teal)
            if let first = known.dataObservations.first,
               first != bundleName.map({ "Declared source container: " + $0 }),
               first != bundleName.map({ "Declared source model name: " + $0 }) {
                Text(first).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let bundleName {
                Text(bundleName).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(file.url.path)
            } else {
                Text(file.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }.padding(.vertical, 3)
    }
}
struct CacheFileInspector: View {
    @ObservedObject var model: ExplorerModel
    let file: InventoryFile
    var body: some View {
        let explanation = model.cacheExplanations[file.id] ?? CacheExplanation.describe(url: file.url, metadata: model.inspection?.metadata, bnns: model.inspection?.bnns, e5: model.inspection?.e5)
        VStack(alignment: .leading, spacing: 16) {
            Text(file.url.lastPathComponent).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(file.url.path).font(.caption).textSelection(.enabled)
            Text(explanation.role).font(.headline)
            Text(explanation.purpose ?? explanation.summary).font(.subheadline).foregroundStyle(.secondary)
            if !explanation.executionBackends.isEmpty {
                Text("Compute stages: " + explanation.executionBackends.joined(separator: " and ")).font(.caption).foregroundStyle(.teal)
            }
            if let program = model.inspection?.e5 {
                E5ProgramView(program: program, manifest: file.url, files: model.files, openFile: model.showBundleFile).id(file.id)
            } else if let program = model.inspection?.bnns { BNNSProgramView(program: program).id(file.id) }
            else { ForEach(explanation.dataObservations, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } }
            if TaxonomySource.isSceneIndex(file.url) {
                Button("Open Taxonomy Browser", systemImage: "list.bullet.indent") { model.openTaxonomy(file) }.buttonStyle(.borderedProminent)
                Text("Decode this cache file’s actual category records and lookup structures.").font(.caption).foregroundStyle(.secondary)
            }
            if GeographySource.isIndex(file.url) {
                Button("Open Geography", systemImage: "map") { model.openGeography(file) }.buttonStyle(.borderedProminent)
                Text("Explore this cache’s geographic cells, scene groups and taxonomy links.").font(.caption).foregroundStyle(.secondary)
            }
            if let bundle = model.cacheBundles.first(where: { $0.contains(file) }) {
                HStack { Button("Open Containing Bundle", systemImage: "shippingbox") { model.showBundle(bundle.url) }; Text(bundle.title).font(.caption).lineLimit(2) }
            }
            ForEach(explanation.sourceReferences, id: \.self) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source model").font(.caption.weight(.medium))
                    Text(source).font(.caption2.monospaced()).textSelection(.enabled)
                    Button("Inspect Source Model") { model.inspectSourceGraph(source) }.controlSize(.small).disabled(model.busy.contains("sourceGraph"))
                }
            }
            if !explanation.pathFields.isEmpty { MetadataFields(fields: explanation.pathFields) }
            MetadataFields(fields: ["Logical bytes": String(file.logicalBytes), "Allocated bytes": file.allocatedBytes.map(String.init) ?? "Unavailable", "Modified": file.modified?.formatted() ?? "Unavailable"])
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            if model.busy.contains("inspect") { ProgressView("Reading file…") }
            if let inspection = model.inspection {
                if let format = inspection.metadataFormat { Text(format).font(.caption).foregroundStyle(.teal) }
                if let issue = inspection.metadataIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Signature & checksums") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("First 64 bytes · hex").font(.caption.weight(.medium))
                        Text(inspection.signature).font(.caption.monospaced()).textSelection(.enabled)
                        if let hash = inspection.sha256 { MetadataFields(fields: ["File SHA-256": hash]) }
                        if let hash = inspection.metadataSHA256 { MetadataFields(fields: ["Decoded metadata SHA-256": hash]) }
                    }
                }
                if let metadata = inspection.metadata {
                    DisclosureGroup("Static metadata · up to 256 KiB") { Text(metadata).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CacheBundlesView: View {
    @ObservedObject var model: ExplorerModel
    @State private var fileFilter = ""
    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search bundles, models or contents", text: $model.bundleSearch).textFieldStyle(.roundedBorder)
                Text("\(model.visibleBundles.count) matching bundles").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                List(model.visibleBundles, selection: $model.selectedBundle) { bundle in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(bundle.title).font(.headline).lineLimit(2)
                        HStack { Text("\(bundle.files.count) files"); Text(bytes(bundle.logicalBytes)); if let build = bundle.buildLabel { Text(build) } }.font(.caption).foregroundStyle(.secondary)
                        Text(bundle.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }.padding(.vertical, 4).tag(bundle.id)
                }.listStyle(.inset)
            }.frame(minWidth: 300, idealWidth: 390, maxWidth: 540).padding(.trailing, 10)
            ScrollView {
                if let bundle = model.currentBundle {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(bundle.title).font(.title3.weight(.semibold)); Spacer()
                            Button("Reveal Bundle") { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
                        }
                        Text(bundle.summary).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(bundle.files.count) files · \(bytes(bundle.logicalBytes))").font(.caption)
                        DisclosureGroup("File Details") {
                            Text(bundle.url.path).font(.caption2.monospaced()).textSelection(.enabled)
                            ForEach(bundle.sourceReferences, id: \.self) { Text($0).font(.caption2.monospaced()).textSelection(.enabled) }
                            MetadataFields(fields: ["Build label": bundle.buildLabel ?? "Not stored in path", "Opaque cache key": bundle.cacheKey ?? "Not stored in path", "Targets": bundle.targets.isEmpty ? "No target sub-bundles inventoried" : bundle.targets.joined(separator: ", "), "Allocated bytes": bundle.allocatedBytes.map(String.init) ?? "Partial / unavailable", "Latest file modification": bundle.modified?.formatted() ?? "Unavailable"])
                        }
                        if !bundle.sourceReferences.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Source models").font(.headline)
                                ForEach(bundle.sourceReferences, id: \.self) { source in
                                    Button("Inspect Source Model") { model.inspectSourceGraph(source) }.controlSize(.small).help(source)
                                }
                            }
                        }
                        Divider()
                        Text("Bundle contents").font(.headline)
                        TextField("Filter relative paths or file roles", text: $fileFilter).textFieldStyle(.roundedBorder)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(bundle.files.filter { fileFilter.isEmpty || $0.id.localizedCaseInsensitiveContains(fileFilter) || model.cacheExplanations[$0.id]?.role.localizedCaseInsensitiveContains(fileFilter) == true }) { file in
                                Button { model.showBundleFile(file) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(String(file.id.dropFirst(bundle.id.count + 1))).font(.caption.monospaced()).multilineTextAlignment(.leading); Spacer(); Text(bytes(file.logicalBytes)).font(.caption).foregroundStyle(.secondary) }
                                        Text((model.cacheExplanations[file.id] ?? CacheExplanation.describe(url: file.url, metadata: nil)).role).font(.caption).foregroundStyle(.teal)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }.padding(16)
                } else { ContentUnavailableView("Select a bundle", systemImage: "shippingbox", description: Text("Bundles are grouped from the readable cache inventory.")) }
            }.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }.onChange(of: model.selectedBundle) { _, _ in fileFilter = "" }
    }
}
