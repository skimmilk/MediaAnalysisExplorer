import AppKit
import Combine
import SwiftUI
import ExplorerCore

enum CacheViewMode: String, CaseIterable, Identifiable {
    case files = "Files", bundles = "Bundles", taxonomy = "Scene Taxonomy", geography = "Geography"
    var id: String { rawValue }
}

enum Section: String, CaseIterable, Identifiable {
    case media = "Media", analyze = "Analyze Media", processing = "Processing", caches = "Models & Caches"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .media: "photo.on.rectangle"; case .analyze: "photo.badge.bolt"; case .processing: "clock.arrow.circlepath"; case .caches: "shippingbox" }
    }
}

@MainActor final class ExplorerModel: ObservableObject {
    @Published var section: Section = .media
    let daemonDatabases = DaemonDatabase.known(home: FileManager.default.homeDirectoryForCurrentUser)
    @Published var dashboard: ProcessingDashboard?
    @Published var processingHistory: ProcessingHistory? { didSet { trackRecentAnalysis() } }
    @Published private(set) var recentAnalysisArrivals: [String: Date] = [:]
    private var recentAnalysisDates: [String: Date] = [:]
    private var recentHistoryWindow: DateInterval?
    private var processingRefreshPending = false
    @Published var processingHistoryFailure: String?
    let analysisLauncher: AnalysisLauncher
    let localAnalysis: LocalAnalysisModel
    @Published var processingRange: ProcessingRange = .week { didSet { if !settingHistoryWindow && oldValue != processingRange { refreshProcessingHistory() } } }
    @Published var processingStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())! { didSet { if !settingHistoryWindow && processingRange == .custom { refreshProcessingHistory() } } }
    @Published var processingEnd = Date() { didSet { if !settingHistoryWindow && processingRange == .custom { refreshProcessingHistory() } } }
    private var settingHistoryWindow = false
    @Published var cacheExplanations: [String: CacheExplanation] = [:]
    @Published var cacheBundles: [CacheBundle] = []
    @Published var cacheView: CacheViewMode = .bundles
    let geography: GeographyModel
    @Published var taxonomyFromGeography = false
    @Published var selectedBundle: String?
    @Published var bundleSearch = ""
    @Published var taxonomySources: [TaxonomySource] = []
    @Published var selectedTaxonomySource: String?
    @Published var taxonomy: SceneTaxonomy?
    @Published var comparisonTaxonomy: SceneTaxonomy?
    @Published var taxonomyLocalization: TaxonomyLocalization?
    @Published var taxonomyLocale = "en"
    @Published var taxonomyFailure: String?
    @Published var taxonomyComparisonFailure: String?
    @Published var taxonomyQuery = ""
    @Published var taxonomyNetwork: UInt32 = 0
    @Published var taxonomyIndexed = "all"
    @Published var selectedConcept: String? = "Q1349227"
    private var didLoadTaxonomySources = false
    private var cacheInspections: [String: FileInspection] = [:]
    private var didScan = false
    @Published var linkedRecords: LinkedRecords?
    @Published var thumbnailInspection: ThumbnailInspection?
    @Published var sourceGraphInspection: SourceGraphInspection?
    private var didStart = false
    private let automaticLoading: Bool
    private var selectedDatabaseAccessURL: URL?
    @Published var source = SourceConfiguration()
    @Published var schema: [TableSchema] = []
    @Published var sourceReady = false
    @Published var search = "" { didSet { if search != oldValue { scheduleMediaSearch() } } }
    @Published var mediaBrowserVisible = true
    @Published private(set) var photoSelectionIdentifier: String?
    @Published private(set) var photoSelectionFailure: String?
    @Published private(set) var selectedPhotoAsset: MediaAsset?
    @Published var assets: [MediaAsset] = []
    @Published var hasNext = false
    @Published var pageCursors: [Int64] = [0]
    @Published var photosWarning: String?
    @Published var selectedAsset: String? {
        didSet {
            if selectedAsset != oldValue {
                mediaBrowserVisible = selectedAsset == nil
                if selectedPhotoAsset?.id != selectedAsset {
                    selectedPhotoAsset = nil; photoSelectionIdentifier = nil; photoSelectionFailure = nil
                }
            }
        }
    }
    @Published var detail: AssetDetail?
    @Published var preview: MediaPreview?
    @Published var previewFailure: String?
    @Published private(set) var watchedPlaybackClasses: [String] = []
    private let playbackPreferences: UserDefaults
    private static let playbackWatchKey = "watchedPlaybackClasses.v1"
    @Published var cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches").path
    @Published var files: [InventoryFile] = []
    @Published var cacheSearch = ""
    @Published var cacheFileType = "all" {
        didSet {
            if cacheFileType != oldValue, !visibleFiles.contains(where: { $0.id == selectedFile }) {
                selectedFile = visibleFiles.first?.id; inspect()
            }
        }
    }
    @Published var selectedFile: String?
    @Published var inspection: FileInspection?
    @Published var scanNote = "Reading the daemon cache automatically…"
    @Published var visited = 0
    @Published var inaccessible = 0
    @Published var cacheAccessFailure: FileAccessFailure?
    @Published var cachePermissionRequested = false
    private var selectedCacheURL: URL?
    private var requestedCachePaths: Set<String> = []
    private static let cacheBookmarkKey = "cacheFolderReadOnlyBookmark"
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var busy: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var budgets: [String: WorkBudget] = [:]
    private var generations: [String: UUID] = [:]
    private struct MediaKey: Equatable { let source: SourceConfiguration; let asset: String }
    private struct CachedMedia {
        let key: MediaKey
        var detail: AssetDetail
        let preview: MediaPreview?
        let failure: String?
    }
    private var loadedMediaKey: MediaKey?
    private var mediaCache: [CachedMedia] = []
    private var mediaRefreshPending = false
    private var mediaChangeMonitor: ProcessingChangeMonitor?
    private var monitoredMediaSource: SourceConfiguration?
    private var launchWasRunning = false
    private var analysisLaunchObservation: AnyCancellable?

    init(automaticLoading: Bool = true, preferences: UserDefaults = .standard, localAnalysis: LocalAnalysisModel? = nil) {
        self.automaticLoading = automaticLoading
        self.localAnalysis = localAnalysis ?? LocalAnalysisModel()
        analysisLauncher = AnalysisLauncher(recoverSession: automaticLoading, preferences: preferences)
        geography = GeographyModel(preferences: preferences)
        playbackPreferences = preferences
        watchedPlaybackClasses = TimedResultGroup.orderedClasses(preferences.stringArray(forKey: Self.playbackWatchKey) ?? [])
        analysisLaunchObservation = analysisLauncher.$status.sink { [weak self] status in
            guard let self else { return }
            let running = status.map { !$0.finished } ?? false
            let ended = launchWasRunning && !running
            launchWasRunning = running
            if ended {
                mediaAnalysisChanged()
                refreshDashboard(); refreshProcessingHistory()
            }
        }
        guard let data = UserDefaults.standard.data(forKey: Self.cacheBookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else {
                UserDefaults.standard.removeObject(forKey: Self.cacheBookmarkKey)
                scanNote = "Saved cache access expired. Click Request Cache Access to authorize the folder again."
                return
            }
            if cacheRoot == url.path || cacheRoot.hasPrefix(url.path + "/") { selectedCacheURL = url }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.cacheBookmarkKey)
            scanNote = "Saved cache access is unavailable. Click Request Cache Access to authorize the folder again."
        }
    }

    var currentAsset: MediaAsset? {
        if let selectedPhotoAsset, selectedPhotoAsset.id == selectedAsset { return selectedPhotoAsset }
        return assets.first { $0.id == selectedAsset }
    }
    var canBrowsePhotos: Bool { !source.isFixture && !source.photosPath.isEmpty && !source.libraryPath.isEmpty }
    func togglePlaybackWatch(_ table: String) {
        if watchedPlaybackClasses.contains(table) { watchedPlaybackClasses.removeAll { $0 == table } }
        else { watchedPlaybackClasses = TimedResultGroup.orderedClasses(watchedPlaybackClasses + [table]) }
        playbackPreferences.set(watchedPlaybackClasses, forKey: Self.playbackWatchKey)
    }
    func movePlaybackWatchToTop(_ table: String) {
        watchedPlaybackClasses = TimedResultGroup.orderedClasses([table] + watchedPlaybackClasses)
        playbackPreferences.set(watchedPlaybackClasses, forKey: Self.playbackWatchKey)
    }
    var currentFile: InventoryFile? { files.first { $0.id == selectedFile } }
    var currentBundle: CacheBundle? { cacheBundles.first { $0.id == selectedBundle } }
    func cacheBundleName(for file: InventoryFile) -> String? { cacheBundles.first { $0.contains(file) }?.title }
    var visibleBundles: [CacheBundle] {
        cacheBundles.filter { bundleSearch.isEmpty || [$0.title, $0.id, $0.description, $0.summary].contains { $0.localizedCaseInsensitiveContains(bundleSearch) } || $0.sourceReferences.contains { $0.localizedCaseInsensitiveContains(bundleSearch) } }
    }
    var visibleConcepts: [SceneConcept] {
        taxonomy?.matching(query: taxonomyQuery, network: taxonomyNetwork == 0 ? nil : taxonomyNetwork,
                           indexed: taxonomyIndexed == "all" ? nil : taxonomyIndexed == "yes", localization: taxonomyLocalization) ?? []
    }
    var currentConcept: SceneConcept? { selectedConcept.flatMap { taxonomy?.nodes[$0] } }
    var hasMediaAssets: Bool { schema.contains { $0.name == "ZASSET" && $0.has("Z_PK", "ZLOCALIDENTIFIER") } }
    var visibleFiles: [InventoryFile] {
        files.filter { file in
            (cacheFileType != "e5" || file.url.pathExtension.lowercased() == "e5") &&
            (cacheSearch.isEmpty || file.url.path.localizedCaseInsensitiveContains(cacheSearch) || cacheBundleName(for: file)?.localizedCaseInsensitiveContains(cacheSearch) == true || cacheExplanations[file.id]?.role.localizedCaseInsensitiveContains(cacheSearch) == true || cacheExplanations[file.id]?.purpose?.localizedCaseInsensitiveContains(cacheSearch) == true || cacheExplanations[file.id]?.summary.localizedCaseInsensitiveContains(cacheSearch) == true || cacheExplanations[file.id]?.sourceReferences.contains { $0.localizedCaseInsensitiveContains(cacheSearch) } == true || cacheExplanations[file.id]?.dataObservations.contains { $0.localizedCaseInsensitiveContains(cacheSearch) } == true)
        }
    }
    var logicalBytes: Int64 { files.reduce(0) { $0 + $1.logicalBytes } }
    var allocatedBytes: Int64 { files.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } }

    func cancel(_ lane: String) {
        tasks[lane]?.cancel(); budgets[lane]?.cancel(); generations[lane] = UUID(); busy.remove(lane)
    }
    private func run<T: Sendable>(_ lane: String, seconds: Double = 5,
                                 onFailure: ((Error) -> Void)? = nil,
                                 work: @escaping @Sendable (WorkBudget) throws -> T,
                                 apply: @escaping @MainActor (T) -> Void) {
        cancel(lane)
        let generation = UUID(); generations[lane] = generation
        let budget = WorkBudget(seconds: seconds); budgets[lane] = budget; busy.insert(lane)
        let scope = ["source", "media", "photoSelection", "detail", "resultPage", "linkedRecords", "thumbnail", "preview", "dashboard", "processingHistory"].contains(lane) ? selectedDatabaseAccessURL : nil
        tasks[lane] = Task {
            let result = await Task.detached(priority: .utility) {
                let scoped = scope?.startAccessingSecurityScopedResource() == true
                defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
                return Result { try work(budget) }
            }.value
            guard generations[lane] == generation else { return }
            busy.remove(lane)
            switch result { case .success(let value): apply(value); case .failure(let error): errorMessage = error.localizedDescription; onFailure?(error) }
        }
    }
    func connect(_ configuration: SourceConfiguration) {
        for lane in ["source", "media", "mediaSearch", "photoSelection", "detail", "resultPage", "preview"] { cancel(lane) }
        mediaCache = []; loadedMediaKey = nil; mediaBrowserVisible = true
        selectedPhotoAsset = nil; photoSelectionIdentifier = nil; photoSelectionFailure = nil
        mediaRefreshPending = false; mediaChangeMonitor = nil; monitoredMediaSource = nil
        source = configuration; sourceReady = false; schema = []; assets = []; detail = nil; preview = nil; previewFailure = nil; selectedAsset = nil
        search = ""; pageCursors = [0]; photosWarning = nil; notice = nil; errorMessage = nil
        run("source", work: { try ReadDatabase(path: configuration.analysisPath, budget: $0).schema() }) { [self] schemas in
            schema = schemas; sourceReady = true
            if schemas.contains(where: { $0.name == "ZASSET" && $0.has("ZLOCALIDENTIFIER", "Z_PK") }) { loadAssets(reset: true) }
        }
    }
    func startIfNeeded(arguments: [String]? = nil) {
        guard !didStart else { return }
        didStart = true
        let args = arguments ?? ProcessInfo.processInfo.arguments
        if args.contains("--analyze") { section = .analyze; return }
        if args.contains("--geography") {
            section = .caches; cacheView = .geography
            ensureCacheLoaded(); ensureGeography()
            return
        }
        if args.contains("--media"), let photos = daemonDatabases.first(where: { $0.name == "Photos analysis" }) {
            section = .media; connect(photos.source)
        } else if let photos = daemonDatabases.first(where: { $0.name == "Photos analysis" }) { connect(photos.source) }
        refreshDashboard(); ensureCacheLoaded()
        if args.contains("--processing") { section = .processing }
        if args.contains("--caches") { section = .caches }
        if args.contains("--e5") { section = .caches; cacheView = .files; cacheFileType = "e5" }
        if args.contains("--taxonomy") { section = .caches; cacheView = .taxonomy; ensureTaxonomySources() }
    }
    func showMedia() {
        section = .media
        if !sourceReady, let photos = daemonDatabases.first(where: { $0.name == "Photos analysis" }) { connect(photos.source) }
    }
    func activateSection() {
        switch section {
        case .analyze: break
        case .media:
            if !sourceReady && !busy.contains("source") { showMedia() }
            else { refreshMediaIfNeeded() }
        case .processing: if dashboard == nil { refreshDashboard() }; if processingHistory == nil && !busy.contains("processingHistory") { refreshProcessingHistory() }
        case .caches: ensureCacheLoaded(); if cacheView == .taxonomy { ensureTaxonomySources() }; if cacheView == .geography { ensureGeography() }
        }
    }
    func refreshCurrentSection() {
        switch section {
        case .analyze: localAnalysis.retry()
        case .media:
            if sourceReady {
                mediaCache = []; loadedMediaKey = nil
                if let identifier = photoSelectionIdentifier { openPhotoAnalysis(identifier: identifier, showViewer: !mediaBrowserVisible) }
                else { loadAssets(refreshDetail: true) }
            } else { showMedia() }
        case .processing: refreshDashboard(); refreshProcessingHistory()
        case .caches: scan(); if cacheView == .taxonomy { loadTaxonomy() }; if cacheView == .geography { loadGeography(reload: true) }
        }
    }
    func refreshDashboard() {
        guard automaticLoading, !busy.contains("dashboard") else { return }
        let databases = daemonDatabases
        run("dashboard", seconds: 20, work: { ProcessingDashboardReader.read(databases: databases, budget: $0) }) { [self] report in dashboard = report }
    }
    func refreshProcessingHistory() {
        guard automaticLoading else { return }
        processingRefreshPending = false
        let databases = daemonDatabases, range = processingRange, start = processingStart, end = processingEnd
        processingHistoryFailure = nil
        run("processingHistory", seconds: 20, onFailure: { [self] error in processingHistoryFailure = error.localizedDescription }, work: {
            try ProcessingHistoryReader.read(databases: databases, range: range, customStart: start, customEnd: end, budget: $0)
        }) { [self] history in processingHistory = history }
    }
    func pollProcessingChanges(_ monitor: ProcessingChangeMonitor) async {
        guard automaticLoading else { return }
        let scope = selectedDatabaseAccessURL
        let scoped = scope?.startAccessingSecurityScopedResource() == true
        defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
        let changed = await monitor.hasChanges()
        guard !Task.isCancelled else { return }
        if changed { mediaAnalysisChanged() }
        processingRefreshPending = processingRefreshPending || changed
        if processingRefreshPending && !busy.contains("processingHistory") { refreshProcessingHistory() }
    }
    func mediaAnalysisChanged() {
        mediaRefreshPending = true
        refreshMediaIfNeeded()
    }
    func refreshMediaIfNeeded() {
        guard mediaRefreshPending, section == .media, sourceReady, hasMediaAssets,
              busy.isDisjoint(with: ["source", "media", "photoSelection", "detail", "preview", "resultPage"]) else { return }
        mediaRefreshPending = false
        mediaCache = []; loadedMediaKey = nil
        // Reuse the current query/page. loadAssets retains the selected asset
        // when it is still present and rereads its stored analysis results.
        if let identifier = photoSelectionIdentifier, !mediaBrowserVisible { openPhotoAnalysis(identifier: identifier) }
        else { loadAssets(refreshDetail: true) }
    }
    func pollMediaChanges() async {
        guard automaticLoading, sourceReady, hasMediaAssets else { return }
        let config = source
        if monitoredMediaSource != config || mediaChangeMonitor == nil {
            monitoredMediaSource = config
            mediaChangeMonitor = ProcessingChangeMonitor(databases: [DaemonDatabase(name: "Media", purpose: "Selected analysis source", source: config)])
        }
        guard let monitor = mediaChangeMonitor else { return }
        let scope = selectedDatabaseAccessURL
        let scoped = scope?.startAccessingSecurityScopedResource() == true
        defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
        let changed = await monitor.hasChanges()
        guard !Task.isCancelled, source == config else { return }
        if changed { mediaAnalysisChanged() }
        else { refreshMediaIfNeeded() }
    }
    func refreshProcessingProcesses() {
        guard automaticLoading, !busy.contains("dashboard"), !busy.contains("dashboardSample"), let dashboard else { return }
        run("dashboardSample", seconds: 3, work: { _ in ProcessingDashboardReader.resampleProcesses(dashboard) }) { [self] sample in
            // A full dashboard read may have finished while the process sample ran.
            if !busy.contains("dashboard"), self.dashboard?.updated == dashboard.updated { self.dashboard = sample }
        }
    }
    private func trackRecentAnalysis() {
        guard let history = processingHistory, history.total(\.assets) != nil else { return }
        let now = Date(), window = DateInterval(start: history.start, end: history.end)
        let dates = Dictionary(history.recentAssets.map { ($0.identifier, $0.date) }, uniquingKeysWith: { a, b in max(a, b) })
        if recentHistoryWindow == window {
            var arrivals = recentAnalysisArrivals.filter { dates[$0.key] != nil && now.timeIntervalSince($0.value) < 30 }
            for (identifier, date) in dates where recentAnalysisDates[identifier].map({ date > $0 }) ?? true {
                arrivals[identifier] = now
            }
            recentAnalysisArrivals = arrivals
        } else {
            // Opening the dashboard or expanding the date range is a baseline,
            // rather than evidence of freshly completed analysis.
            recentAnalysisArrivals = [:]
        }
        recentAnalysisDates = dates
        recentHistoryWindow = window
    }
    func focusProcessingPeriod(start: Date, end: Date) {
        settingHistoryWindow = true
        processingStart = start; processingEnd = end.addingTimeInterval(-1); processingRange = .custom
        settingHistoryWindow = false
        refreshProcessingHistory()
    }
    func openProcessedAsset(_ asset: ProcessedAsset) {
        showMedia()
        cancel("photoSelection")
        selectedPhotoAsset = nil; photoSelectionIdentifier = nil; photoSelectionFailure = nil
        if let existing = assets.first(where: { $0.identifier == asset.identifier }) {
            selectedAsset = existing.id; mediaBrowserVisible = false; loadDetail()
        } else {
            selectedAsset = nil; loadDetail()
            search = asset.identifier
            loadAssets(reset: true)
        }
    }
    func backToMediaBrowser() {
        cancel("photoSelection")
        mediaBrowserVisible = true
    }
    func openPhotoAnalysis(identifier: String?, showViewer: Bool = true) {
        cancel("mediaSearch"); cancel("media"); cancel("photoSelection")
        selectedPhotoAsset = nil; selectedAsset = nil; loadDetail()
        photoSelectionIdentifier = identifier; photoSelectionFailure = nil
        mediaBrowserVisible = !showViewer
        guard let identifier else {
            photoSelectionFailure = "Photos did not supply an asset identifier. Return to Photos and choose another item."
            return
        }
        let config = source
        run("photoSelection", onFailure: { [self] error in photoSelectionFailure = error.localizedDescription }, work: {
            try LibraryReader.asset(identifier: identifier, source: config, budget: $0)
        }) { [self] asset in
            guard source == config, photoSelectionIdentifier == identifier else { return }
            guard let asset else {
                photoSelectionFailure = "No cached analysis record was found for this item in the current analysis library. It may not have been analyzed yet, or may belong to another Photos library."
                return
            }
            let browserWasVisible = mediaBrowserVisible
            selectedPhotoAsset = asset; selectedAsset = asset.id
            mediaBrowserVisible = browserWasVisible
            loadDetail()
        }
    }
    func ensureCacheLoaded() { if automaticLoading && !didScan { scan() } }
    func requestDatabaseAccess() {
        let target = source
        let panel = NSOpenPanel()
        panel.title = "Allow access to the daemon database folder"
        panel.message = "Select the folder containing \(target.analysisPath). The database will be opened read-only."
        panel.prompt = "Allow Access"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = target.libraryPath.isEmpty ? URL(fileURLWithPath: target.analysisPath).deletingLastPathComponent() : URL(fileURLWithPath: target.libraryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard target.analysisPath.hasPrefix(url.path + "/") else {
            errorMessage = "Choose a folder containing the configured live MediaAnalysis.sqlite. The database source remains unchanged."
            return
        }
        selectedDatabaseAccessURL = url
        connect(target)
    }
    private func scheduleMediaSearch() {
        cancel("mediaSearch"); cancel("media")
        guard sourceReady && hasMediaAssets else { return }
        tasks["mediaSearch"] = Task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            loadAssets(reset: true)
        }
    }
    func loadAssets(reset: Bool = false, refreshDetail: Bool = false) {
        guard sourceReady && hasMediaAssets else { return }
        cancel("mediaSearch")
        if reset { pageCursors = [0] }
        let config = source, query = search, cursor = pageCursors.last ?? 0
        run("media", work: { try LibraryReader.assets(source: config, search: query, after: cursor, budget: $0) }) { [self] page in
            guard source == config, search == query else { return }
            let previous = selectedAsset
            assets = page.assets; hasNext = page.hasNext; photosWarning = page.photosWarning
            if let previous, selectedPhotoAsset?.id == previous || page.assets.contains(where: { $0.id == previous }) { selectedAsset = previous }
            else { selectedAsset = !query.isEmpty && page.assets.count == 1 ? page.assets.first?.id : nil }
            if selectedAsset != previous || refreshDetail { loadDetail() }
        }
    }
    func nextAssets() { if let id = assets.last?.id, let cursor = Int64(id) { pageCursors.append(cursor); loadAssets() } }
    func previousAssets() { if pageCursors.count > 1 { pageCursors.removeLast(); loadAssets() } }
    func loadDetail() {
        if let asset = currentAsset {
            let key = MediaKey(source: source, asset: asset.id)
            if loadedMediaKey == key, detail != nil || busy.contains("detail") { return }
        }
        cancel("resultPage")
        cancel("linkedRecords"); linkedRecords = nil; cancel("thumbnail"); thumbnailInspection = nil
        detail = nil; preview = nil; previewFailure = nil; cancel("preview")
        guard let asset = currentAsset else { cancel("detail"); loadedMediaKey = nil; return }
        let config = source
        let key = MediaKey(source: config, asset: asset.id)
        loadedMediaKey = key
        if let index = mediaCache.firstIndex(where: { $0.key == key }) {
            cancel("detail")
            let cached = mediaCache.remove(at: index); mediaCache.append(cached)
            detail = cached.detail; preview = cached.preview; previewFailure = cached.failure
            return
        }
        run("detail", onFailure: { [self] _ in loadedMediaKey = nil }, work: { try LibraryReader.detail(asset: asset, source: config, budget: $0) }) { [self] value in
            detail = value
            if let url = value.media?.originalURL {
                run("preview", seconds: 15, work: { budget -> PreviewLoad in
                    do { return PreviewLoad(preview: try PreviewReader.read(url, budget: budget), failure: nil) }
                    catch { return PreviewLoad(preview: nil, failure: error.localizedDescription) }
                }) { [self] loaded in
                    preview = loaded.preview; previewFailure = loaded.failure
                    cacheMedia(key: key, detail: detail ?? value, preview: loaded.preview, failure: loaded.failure)
                }
            } else { cacheMedia(key: key, detail: value, preview: nil, failure: nil) }
        }
    }
    private func cacheMedia(key: MediaKey, detail: AssetDetail, preview: MediaPreview?, failure: String?) {
        mediaCache.removeAll { $0.key == key }
        mediaCache.append(CachedMedia(key: key, detail: detail, preview: preview, failure: failure))
        while mediaCache.count > 3 || mediaCache.reduce(0, { $0 + ($1.preview?.data.count ?? 0) }) > 24 * 1024 * 1024 {
            mediaCache.removeFirst()
        }
    }
    func loadMoreResults(_ table: String) {
        guard !busy.contains("resultPage"), let asset = currentAsset, let family = detail?.families.first(where: { $0.id == table }), family.rows.count < family.count else { return }
        let config = source, schema = family.table, offset = family.rows.count, currentDetail = detail!
        run("resultPage", seconds: 10, work: { budget in
            let rows = try ReadDatabase(path: config.analysisPath, budget: budget).analysisRows(table: schema, offset: offset, assetKey: asset.id)
            return currentDetail.appending(rows, to: table)
        }) { [self] updated in
            guard selectedAsset == asset.id else { return }
            if updated.families.first(where: { $0.id == table })?.rows.count == offset { notice = "No further records returned. Refresh if the live database changed." }
            else {
                detail = updated
                if let key = loadedMediaKey, let index = mediaCache.firstIndex(where: { $0.key == key }) { mediaCache[index].detail = updated }
            }
        }
    }
    func inspectReference(_ reference: ResultReference) {
        guard let asset = currentAsset else { return }
        let config = source
        run("linkedRecords", seconds: 10, work: { budget in
            let db = try ReadDatabase(path: config.analysisPath, budget: budget)
            guard let table = try db.schema().first(where: { $0.name == reference.table }) else { return LinkedRecords(reference: reference, rows: []) }
            return LinkedRecords(reference: reference, rows: try db.analysisRecords(table: table, assetKey: asset.id, field: reference.field, value: reference.value))
        }) { [self] value in
            guard selectedAsset == asset.id else { return }
            linkedRecords = value
        }
    }
    func inspectThumbnail(_ id: String) {
        guard let asset = currentAsset else { return }
        let config = source
        linkedRecords = nil
        run("thumbnail", seconds: 10, work: { budget in
            let url = try LibraryReader.thumbnailURL(identifier: asset.identifier, thumbnailID: id, source: config)
            return ThumbnailInspection(url: url, preview: try PreviewReader.read(url, budget: budget))
        }) { [self] value in
            guard selectedAsset == asset.id else { return }
            thumbnailInspection = value
        }
    }
    func readInlineThumbnail(_ id: String) async throws -> MediaPreview {
        guard let asset = currentAsset else { throw ExplorerError("No selected asset") }
        let config = source, scope = selectedDatabaseAccessURL
        let budget = WorkBudget(seconds: 10)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let scoped = scope?.startAccessingSecurityScopedResource() == true
                defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
                try budget.check()
                let url = try LibraryReader.thumbnailURL(identifier: asset.identifier, thumbnailID: id, source: config)
                return try PreviewReader.read(url, budget: budget, maximumPixelSize: 400)
            }.value
        } onCancel: { budget.cancel() }
    }
    func inspectSourceGraph(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/System/Library/"), ["net", "mil"].contains(url.pathExtension) else { errorMessage = "Unsupported declared source path"; return }
        run("sourceGraph", seconds: 10, work: { budget in
            let inspection = try Inventory.inspect(url: url, hash: false, budget: budget)
            return SourceGraphInspection(url: url, inspection: inspection, explanation: CacheExplanation.describe(url: url, metadata: inspection.metadata))
        }) { [self] value in sourceGraphInspection = value }
    }
    func scan() {
        didScan = true; cancel("cacheKnowledge"); cacheExplanations = [:]; cacheInspections = [:]
        cancel("scan"); cancel("inspect"); cancel("cacheKnowledge"); cacheInspections = [:]; cacheExplanations = [:]; cacheBundles = []; selectedBundle = nil
        files = []; selectedFile = nil; inspection = nil; visited = 0; inaccessible = 0
        cacheAccessFailure = nil; scanNote = "Scanning…"
        cachePermissionRequested = selectedCacheURL?.path == cacheRoot
        let generation = UUID(); generations["scan"] = generation; busy.insert("scan")
        let budget = WorkBudget(seconds: 15); budgets["scan"] = budget
        let root = selectedCacheURL.flatMap { $0.path == cacheRoot ? $0 : nil } ?? URL(fileURLWithPath: cacheRoot)
        let access = selectedCacheURL ?? root
        let stream = AsyncThrowingStream<InventoryUpdate, Error> { continuation in
            Task.detached(priority: .utility) {
                let scoped = access.startAccessingSecurityScopedResource()
                defer { if scoped { access.stopAccessingSecurityScopedResource() } }
                do { try Inventory.scan(root: root, budget: budget) { continuation.yield($0) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
        tasks["scan"] = Task {
            var shouldRequestAccess = false
            do {
                for try await update in stream {
                    guard generations["scan"] == generation else { return }
                    files.append(contentsOf: update.files)
                    visited = update.visited; inaccessible = update.inaccessible; scanNote = update.note
                }
            } catch {
                if generations["scan"] == generation {
                    cacheAccessFailure = FileAccessFailure(error: error, url: root)
                    inaccessible = max(inaccessible, 1)
                    scanNote = "Scan failed. Disk totals are unavailable; this does not mean the folder is empty."
                    shouldRequestAccess = cacheAccessFailure?.isPermissionDenied == true && !requestedCachePaths.contains(root.path)
                }
            }
            if generations["scan"] == generation {
                busy.remove("scan")
                updateTaxonomyCacheSources()
                if shouldRequestAccess && cacheRoot == root.path { requestCacheAccess() }
                else if cacheAccessFailure == nil { loadCacheKnowledge() }
            }
        }
    }
    func stopScan() { cancel("scan"); scanNote = "Cancelled. Displayed inventory is partial." }
    func inspect() {
        cancel("inspect")
        guard let file = currentFile else { cancel("inspect"); inspection = nil; return }
        if let cached = cacheInspections[file.id] { inspection = cached; return }
        inspection = nil
        let scope = selectedCacheURL
        run("inspect", seconds: 15, work: { budget in
            let scoped = scope?.startAccessingSecurityScopedResource() == true
            defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
            return try Inventory.inspect(url: file.url, hash: false, budget: budget)
        }) { [self] value in inspection = value }
    }
    private func loadCacheKnowledge() {
        let inventory = files, scope = selectedCacheURL, root = URL(fileURLWithPath: cacheRoot)
        run("cacheKnowledge", seconds: 15, work: { budget in
            let scoped = scope?.startAccessingSecurityScopedResource() == true
            defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
            var explanations: [String: CacheExplanation] = [:]; var inspections: [String: FileInspection] = [:]; var textBytes = 0
            for file in inventory.prefix(1024) {
                if budget.stopped { break }
                let value = textBytes < 16 * 1024 * 1024 ? try? Inventory.inspect(url: file.url, hash: false, budget: budget) : nil
                if let value, textBytes < 16 * 1024 * 1024 {
                    let cost = (value.metadata?.utf8.count ?? 0) + (value.bnns?.estimatedMetadataBytes ?? 0) + (value.e5?.estimatedMetadataBytes ?? 0)
                    if cost <= 16 * 1024 * 1024 - textBytes { textBytes += cost; inspections[file.id] = value }
                }
                explanations[file.id] = CacheExplanation.describe(url: file.url, metadata: inspections[file.id]?.metadata, bnns: inspections[file.id]?.bnns, e5: inspections[file.id]?.e5)
            }
            return CacheKnowledge(explanations: explanations, inspections: inspections)
        }) { [self] knowledge in
            cacheExplanations = knowledge.explanations; cacheInspections = knowledge.inspections
            cacheBundles = CacheBundle.group(files: inventory, explanations: knowledge.explanations, root: root)
            if selectedBundle == nil { selectedBundle = cacheBundles.first?.id }
            updateTaxonomyCacheSources()
            if selectedFile == nil {
                selectedFile = visibleFiles.first { knowledge.explanations[$0.id]?.sourceReferences.isEmpty == false }?.id ?? visibleFiles.first?.id
                inspect()
            }
        }
    }
    func showBundle(_ url: URL) {
        selectedBundle = cacheBundles.first { $0.id == url.standardizedFileURL.path }?.id
        bundleSearch = ""; cacheView = .bundles
    }
    func showBundleFile(_ file: InventoryFile) {
        cacheSearch = ""; cacheFileType = "all"; selectedFile = file.id; cacheView = .files; inspect()
    }
    var geographySources: [GeographySource] {
        var sources = [GeographySource(url: URL(fileURLWithPath: cacheRoot).appendingPathComponent("PFSceneGeographyData.index"), isCache: true), .installed]
        if let current = geography.source, !sources.contains(current) { sources.insert(current, at: 0) }
        return sources
    }
    func ensureGeography() {
        guard geography.atlas == nil, !geography.loading else { return }
        loadGeography()
    }
    func loadGeography(source: GeographySource? = nil, reload: Bool = false) {
        let source = source ?? geography.source ?? geographySources[0]
        geography.load(source, scope: source.isCache ? selectedCacheURL : nil, reload: reload)
    }
    func openGeography(_ file: InventoryFile) {
        guard GeographySource.isIndex(file.url) else { return }
        section = .caches; cacheView = .geography
        loadGeography(source: .init(url: file.url, isCache: true))
    }
    func revealGeographyFile() {
        guard let source = geography.source, source.isCache else { return }
        cacheSearch = ""; selectedFile = source.id; cacheView = .files; inspect()
    }
    func openGeographyConcept(_ name: String) {
        guard let reference = geography.taxonomy, reference.nodes[name] != nil else { return }
        taxonomy = reference; taxonomyLocalization = geography.localization; selectedTaxonomySource = reference.source.id
        taxonomyQuery = ""; taxonomyNetwork = 0; taxonomyIndexed = "all"; selectedConcept = name
        taxonomyFromGeography = true; cacheView = .taxonomy; ensureTaxonomySources(); loadTaxonomyComparison(for: reference)
    }
    func openGeographyScene(_ id: UInt64) {
        section = .caches; cacheView = .geography; ensureGeography(); geography.showScene(id)
    }
    func openMediaGeography() {
        guard let point = detail?.media?.location else { return }
        let ids = Set(detail?.families.flatMap { family in family.rows.compactMap { UInt32($0["ZSCENEID"]) } } ?? [])
        geography.mediaSceneIDs = ids; geography.mediaName = detail?.media?.originalName
        section = .caches; cacheView = .geography; ensureGeography()
        geography.focus(point, title: detail?.media?.originalName ?? "Media location")
    }
    func openTaxonomy(_ file: InventoryFile) {
        taxonomyFromGeography = false
        guard TaxonomySource.isSceneIndex(file.url) else { return }
        updateTaxonomyCacheSources()
        selectedTaxonomySource = file.id; taxonomyQuery = ""; taxonomyNetwork = 0; taxonomyIndexed = "all"
        cacheView = .taxonomy; ensureTaxonomySources(); loadTaxonomy()
    }
    func revealTaxonomyFile() {
        guard let source = taxonomy?.source, source.isCache else { return }
        cacheSearch = ""; selectedFile = source.id; cacheView = .files; inspect()
    }
    func selectTaxonomyConcept(_ name: String) {
        guard let node = taxonomy?.nodes[name] else { return }
        if !visibleConcepts.contains(where: { $0.id == name }) {
            taxonomyQuery = ""
            if taxonomyNetwork != 0, taxonomyNetwork != node.networkID { taxonomyNetwork = 0 }
            if taxonomyIndexed != "all", node.indexed != (taxonomyIndexed == "yes") { taxonomyIndexed = "all" }
        }
        selectedConcept = name
    }
    func ensureTaxonomySources() {
        ensureCacheLoaded()
        guard !didLoadTaxonomySources, !busy.contains("taxonomySources") else { return }
        didLoadTaxonomySources = true
        let locale = taxonomyLocale
        run("taxonomySources", seconds: 15, onFailure: { [self] error in
            didLoadTaxonomySources = false; taxonomyFailure = error.localizedDescription
        }, work: { budget in
            (try SceneTaxonomyReader.installedSources(), try SceneTaxonomyReader.localization(locale: locale, budget: budget))
        }) { [self] value in
            taxonomySources = value.0; taxonomyLocalization = value.1; updateTaxonomyCacheSources()
            if cacheView == .taxonomy {
                if let taxonomy { loadTaxonomyComparison(for: taxonomy) }
                else if !busy.contains("taxonomy") { loadTaxonomy() }
            }
        }
    }
    private func updateTaxonomyCacheSources() {
        let caches = files.filter { TaxonomySource.isSceneIndex($0.url) }.map { TaxonomySource(url: $0.url, isCache: true) }.sorted {
            if $0.version != $1.version { return ($0.version ?? 0) > ($1.version ?? 0) }
            return $0.id < $1.id
        }
        taxonomySources = caches + taxonomySources.filter { !$0.isCache }
        // Wait for inventory before choosing a default, so faster archive
        // discovery cannot select an installed source ahead of a daemon cache.
        if selectedTaxonomySource == nil, !busy.contains("scan"), let source = taxonomySources.first {
            selectedTaxonomySource = source.id
            if cacheView == .taxonomy, !busy.contains("taxonomy") { loadTaxonomy() }
        }
    }
    func loadTaxonomy() {
        guard let source = taxonomySources.first(where: { $0.id == selectedTaxonomySource }) else { return }
        cancel("taxonomyComparison"); taxonomy = nil; comparisonTaxonomy = nil; taxonomyFailure = nil; taxonomyComparisonFailure = nil
        let scope = source.isCache ? selectedCacheURL : nil
        run("taxonomy", seconds: 20, onFailure: { [self] error in taxonomyFailure = error.localizedDescription }, work: { budget in
            let scoped = scope?.startAccessingSecurityScopedResource() == true
            defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
            return try SceneTaxonomyReader.load(source, budget: budget)
        }) { [self] value in
            taxonomy = value
            if selectedConcept.flatMap({ value.nodes[$0] }) == nil { selectedConcept = value.matching(query: "", localization: taxonomyLocalization).first?.id }
            loadTaxonomyComparison(for: value)
        }
    }
    private func loadTaxonomyComparison(for value: SceneTaxonomy) {
        let installed = taxonomySources.filter { !$0.isCache }
        let source: TaxonomySource?
        if value.source.isCache {
            source = installed.first { $0.version == value.source.version } ?? installed.first
        } else { source = installed.first { $0.id != value.source.id } }
        guard let source else { return }
        run("taxonomyComparison", seconds: 15, onFailure: { [self] error in taxonomyComparisonFailure = error.localizedDescription }, work: {
            try SceneTaxonomyReader.load(source, budget: $0)
        }) { [self] reference in comparisonTaxonomy = reference }
    }
    func loadTaxonomyLocale() {
        let locale = taxonomyLocale
        run("taxonomyLocale", seconds: 15, onFailure: { [self] error in taxonomyFailure = "Localization unavailable: " + error.localizedDescription }, work: {
            try SceneTaxonomyReader.localization(locale: locale, budget: $0)
        }) { [self] value in taxonomyLocalization = value }
    }
    func requestCacheAccess() {
        requestedCachePaths.insert(cacheRoot)
        let panel = NSOpenPanel()
        panel.title = "Allow MediaAnalysis Explorer to read this cache folder"
        panel.message = "Select the cache folder and click Allow Access. The explorer will read file sizes, signatures, and static metadata locally."
        panel.prompt = "Allow Access"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: cacheRoot, isDirectory: true)
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.acceptCacheFolder(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url { acceptCacheFolder(url) }
    }
    private func acceptCacheFolder(_ url: URL) {
        requestedCachePaths.insert(url.path)
        guard cacheRoot == url.path || cacheRoot.hasPrefix(url.path + "/") else { errorMessage = "Choose the daemon cache folder or a folder containing it."; return }
        selectedCacheURL = url; cachePermissionRequested = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.cacheBookmarkKey)
        } catch {
            // Keep the freshly selected URL usable even if macOS cannot persist its scope.
            UserDefaults.standard.removeObject(forKey: Self.cacheBookmarkKey)
            notice = "Folder selected for this session. macOS could not save access for future launches: \(error.localizedDescription)"
        }
        scan()
        if cacheView == .geography { loadGeography(reload: true) }
    }
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "Open System Settings → Privacy & Security → Full Disk Access." }
    }
    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func chooseFile(title: String, directory: Bool) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.treatsFilePackagesAsDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }

private struct PreviewLoad: Sendable { let preview: MediaPreview?; let failure: String? }

private struct CacheKnowledge: Sendable { let explanations: [String: CacheExplanation]; let inspections: [String: FileInspection] }
