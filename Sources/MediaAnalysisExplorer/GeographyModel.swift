import SwiftUI
import MapKit
import CoreLocation
import ExplorerCore

struct GeographyBookmark: Codable, Identifiable, Equatable {
    var id: String { title + ":" + String(point.latitude) + ":" + String(point.longitude) }
    let title: String
    let point: GeoCoordinate
    let area: GeoArea
}
struct GeographyExample: Identifiable {
    var id: String { title }
    let title: String
    let point: GeoCoordinate
    static let all: [Self] = [
        .init(title: "Golden Gate Bridge", point: .init(latitude: 37.8199, longitude: -122.4783)),
        .init(title: "Eiffel Tower", point: .init(latitude: 48.8584, longitude: 2.2945)),
        .init(title: "Chicago Loop", point: .init(latitude: 41.8781, longitude: -87.6298)),
        .init(title: "Sydney Opera House", point: .init(latitude: -33.8568, longitude: 151.2153)),
        .init(title: "Mount Fuji", point: .init(latitude: 35.3606, longitude: 138.7274)),
        .init(title: "Grand Canyon", point: .init(latitude: 36.1069, longitude: -112.1129))]
}
@MainActor final class GeographyModel: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate, @preconcurrency CLLocationManagerDelegate {
    @Published var atlas: SceneGeography?
    @Published var taxonomy: SceneTaxonomy?
    @Published var localization: TaxonomyLocalization?
    @Published var source: GeographySource?
    @Published var loading = false
    @Published var querying = false
    @Published var failure: String?
    @Published var message: String?
    @Published var worldOverview = false
    @Published var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783), span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.12)))
    @Published var area = GeoArea(center: GeographyExample.all[0].point, latitudeSpan: 0.08, longitudeSpan: 0.12)
    @Published var viewport = GeographyViewport.empty
    @Published var selectedPoint: GeoCoordinate? = GeographyExample.all[0].point
    @Published var placeTitle = GeographyExample.all[0].title
    @Published var theme: Int?
    @Published var groupQuery = ""
    @Published var selectedGroup: Int?
    @Published var searchText = "" { didSet {
        if searchText != oldValue {
            searchTask?.cancel(); activeSearch?.cancel(); searchGeneration = UUID(); searching = false
            completer.queryFragment = searchText
            if searchText.isEmpty { completions = [] }
        }
    } }
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var searching = false
    @Published var requestingLocation = false
    @Published var bookmarks: [GeographyBookmark] = []
    @Published var recent: [GeographyBookmark] = []
    @Published var comparisonCode: UInt32?
    @Published var mediaSceneIDs: Set<UInt32> = []
    @Published var mediaName: String?
    @Published var scoreMaximum = 3
    @Published var scoreBlend = 0.25
    @Published private(set) var canGoBack = false
    private struct Navigation { let area: GeoArea; let point: GeoCoordinate?; let title: String; let theme: Int?; let group: Int?; let world: Bool }
    private var history: [Navigation] = []
    private let preferences: UserDefaults
    private let completer = MKLocalSearchCompleter()
    private let locationManager = CLLocationManager()
    private var loadTask: Task<Void, Never>?, queryTask: Task<Void, Never>?, searchTask: Task<Void, Never>?
    private var loadBudget: WorkBudget?, queryBudget: WorkBudget?
    private var loadGeneration = UUID(), queryGeneration = UUID(), searchGeneration = UUID()
    private var worldTask: Task<Void, Never>?
    private var worldGeneration = UUID()
    private var activeSearch: MKLocalSearch?
    private var pendingScene: UInt64?
    private var sceneNodes: [UInt32: SceneConcept] = [:]
    var selectedCell: GeographyCell? { selectedPoint.flatMap { atlas?.cell(at: $0) } }
    var comparisonCell: GeographyCell? { comparisonCode.flatMap { atlas?.cell(code: $0) } }
    var isBookmarked: Bool { guard let point = selectedPoint else { return false }; return bookmarks.contains { GeoHash.encode($0.point) == GeoHash.encode(point) } }
    var currentGroup: GeographyGroup? { guard let atlas, let selectedGroup, atlas.groups.indices.contains(selectedGroup) else { return nil }; return atlas.groups[selectedGroup] }
    var visibleGroups: [GeographyGroup] {
        guard let atlas else { return [] }
        let q = groupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return atlas.groups.filter { group in
            q.isEmpty || group.name.localizedCaseInsensitiveContains(q) || group.sceneIDs.contains { id in
                let node = sceneNodes[id]
                return String(id) == q || node.map { (localization?.label($0.name) ?? $0.name).localizedCaseInsensitiveContains(q) } == true
            }
        }
    }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest]
        locationManager.delegate = self
        bookmarks = decodePreferences("geography.bookmarks.v1", maximum: 30)
        recent = decodePreferences("geography.recent.v1", maximum: 10)
    }
    private func decodePreferences(_ key: String, maximum: Int) -> [GeographyBookmark] {
        guard let data = preferences.data(forKey: key), data.count <= 128 * 1024, let items = try? JSONDecoder().decode([GeographyBookmark].self, from: data) else { return [] }
        return Array(items.filter { $0.point.isValid && $0.area.isValid && $0.title.count <= 256 }.prefix(maximum))
    }
    func load(_ source: GeographySource, scope: URL?, reload: Bool = false) {
        if self.source == source, !reload, loading || atlas != nil { return }
        loadTask?.cancel(); loadBudget?.cancel(); queryTask?.cancel(); queryBudget?.cancel()
        loadGeneration = UUID(); let generation = loadGeneration, budget = WorkBudget(seconds: 60); loadBudget = budget
        worldTask?.cancel(); worldGeneration = UUID()
        self.source = source; atlas = nil; taxonomy = nil; localization = nil; viewport = .empty; comparisonCode = nil
        theme = nil; selectedGroup = nil; history = []; canGoBack = false; groupQuery = ""
        failure = nil; message = nil; loading = true; querying = false
        loadTask = Task {
            let result = await Task.detached(priority: .utility) {
                let scoped = scope?.startAccessingSecurityScopedResource() == true
                defer { if scoped { scope?.stopAccessingSecurityScopedResource() } }
                return Result { () -> (SceneGeography, SceneTaxonomy?, TaxonomyLocalization?) in
                    let atlas = try SceneGeographyReader.load(source, budget: budget)
                    let taxonomySource = try? SceneTaxonomyReader.installedSources().first { $0.version == 99 }
                    let taxonomy = taxonomySource.flatMap { try? SceneTaxonomyReader.load($0, budget: budget) }
                    let labels = try? SceneTaxonomyReader.localization(budget: budget)
                    try budget.check(); return (atlas, taxonomy, labels)
                }
            }.value
            guard generation == loadGeneration else { return }; loading = false
            switch result {
            case .success(let value):
                atlas = value.0; taxonomy = value.1; localization = value.2
                sceneNodes = Dictionary(uniqueKeysWithValues: (value.1?.nodes.values.compactMap { node -> (UInt32, SceneConcept)? in UInt32(exactly: node.sceneID).map { ($0, node) } } ?? []))
                if let pendingScene { self.pendingScene = nil; showScene(pendingScene) }
                requestViewport(area)
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
    func requestViewport(_ area: GeoArea) {
        guard area.isValid else { return }; self.area = area
        guard let atlas else { return }
        queryTask?.cancel(); queryBudget?.cancel(); queryGeneration = UUID(); let generation = queryGeneration, theme = theme
        querying = true
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(180)); guard !Task.isCancelled else { return }
            let budget = WorkBudget(seconds: 12); queryBudget = budget
            let result = await Task.detached(priority: .utility) { Result { try atlas.viewport(area, group: theme, budget: budget) } }.value
            guard generation == queryGeneration else { return }; querying = false
            switch result { case .success(let value): viewport = value; case .failure(let error): message = error.localizedDescription }
        }
    }
    private func remember() {
        history.append(.init(area: area, point: selectedPoint, title: placeTitle, theme: theme, group: selectedGroup, world: worldOverview))
        if history.count > 40 { history.removeFirst() }; canGoBack = true
    }
    func goBack() {
        guard let state = history.popLast() else { return }
        selectedPoint = state.point; placeTitle = state.title; theme = state.theme; selectedGroup = state.group
        if state.world { worldOverview = true; requestViewport(state.area) } else { moveCamera(state.area) }; canGoBack = !history.isEmpty
    }
    func moveCamera(_ value: GeoArea) {
        worldOverview = false
        area = value
        camera = .region(MKCoordinateRegion(center: .init(latitude: value.center.latitude, longitude: value.center.longitude), span: .init(latitudeDelta: value.latitudeSpan, longitudeDelta: value.longitudeSpan)))
        requestViewport(value)
    }
    func showWorld() {
        remember()
        worldOverview = true; viewport = .empty
        requestViewport(.init(center: .init(latitude: 0, longitude: 0), latitudeSpan: 180, longitudeSpan: 360))
    }
    func exploreWorld(_ point: GeoCoordinate) {
        guard let atlas, let code = GeoHash.encode(point) else { return }
        let precision = viewport.precision, prefix = code >> (5 * (6 - precision))
        guard let tile = viewport.tiles.first(where: { $0.code == prefix }) else { focus(point, title: "Selected area"); return }
        worldTask?.cancel(); worldGeneration = UUID(); let generation = worldGeneration, sourceID = source?.id, theme = theme
        worldTask = Task {
            let result = await Task.detached(priority: .utility) { try? atlas.nearestCell(in: tile, to: point, group: theme, budget: WorkBudget(seconds: 10)) }.value
            guard generation == worldGeneration, sourceID == source?.id else { return }
            focus(result?.coordinate ?? point, title: "Cached cell in selected block")
        }
    }
    func focus(_ point: GeoCoordinate, title: String, remember: Bool = true, recordRecent: Bool = true) {
        guard point.isValid else { return }
        worldTask?.cancel(); worldGeneration = UUID(); requestingLocation = false
        if remember { self.remember() }
        selectedPoint = point; placeTitle = String(title.prefix(256)); selectedGroup = nil; message = nil; searchText = ""; completions = []
        let a = GeoArea(center: point, latitudeSpan: 0.08, longitudeSpan: 0.12)
        moveCamera(a)
        let item = GeographyBookmark(title: placeTitle, point: point, area: a)
        if recordRecent {
            recent.removeAll { $0.point == point }; recent.insert(item, at: 0); recent = Array(recent.prefix(10))
            preferences.set(try? JSONEncoder().encode(recent), forKey: "geography.recent.v1")
        }
    }
    func select(_ point: GeoCoordinate) {
        guard point.isValid else { return }; requestingLocation = false; remember(); selectedPoint = point; placeTitle = "Selected area"; selectedGroup = nil
    }
    func selectCell(_ cell: GeographyCell, centerMap: Bool = false) {
        select(cell.coordinate)
        if centerMap { moveCamera(.init(center: cell.coordinate, latitudeSpan: min(area.latitudeSpan, 0.08), longitudeSpan: min(area.longitudeSpan, 0.12))) }
    }
    func setTheme(_ group: Int?) {
        guard group == nil || atlas?.groups.indices.contains(group!) == true else { return }
        remember(); theme = group; selectedGroup = group; viewport = .empty; requestViewport(area)
    }
    func showScene(_ id: UInt64) {
        guard let atlas else { pendingScene = id; return }
        guard let group = atlas.group(forSceneID: id) else { message = "This scene ID has no explicit geography group. Taxonomy descendants are separate relationships."; return }
        setTheme(group.id)
    }
    func toggleBookmark() {
        guard let point = selectedPoint else { return }
        if isBookmarked { bookmarks.removeAll { GeoHash.encode($0.point) == GeoHash.encode(point) } }
        else { bookmarks.insert(.init(title: placeTitle, point: point, area: area), at: 0); bookmarks = Array(bookmarks.prefix(30)) }
        preferences.set(try? JSONEncoder().encode(bookmarks), forKey: "geography.bookmarks.v1")
    }
    func restore(_ bookmark: GeographyBookmark) {
        remember(); selectedPoint = bookmark.point; placeTitle = bookmark.title
        if bookmark.area.longitudeSpan >= 359 { worldOverview = true; requestViewport(bookmark.area) } else { moveCamera(bookmark.area) }
    }
    func pinComparison() { comparisonCode = selectedCell?.code }
    func sceneName(_ id: UInt32) -> String {
        guard let node = sceneNodes[id] else { return "Scene \(id)" }
        return localization?.label(node.name) ?? node.name
    }
    func sceneKey(_ id: UInt32) -> String? { sceneNodes[id]?.name }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { completions = searchText.isEmpty ? [] : Array(completer.results.prefix(6)) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { completions = [] }
    func search(_ completion: MKLocalSearchCompletion? = nil) {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if completion == nil {
            if text.lowercased().hasPrefix("geohash:"), let code = GeoHash.code(text.dropFirst(8).trimmingCharacters(in: .whitespaces)) { focus(GeoHash.bounds(code).center, title: "Geographic cell \(text.lowercased())"); return }
            let components = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 2, let lat = Double(components[0]), let lon = Double(components[1]) {
                let point = GeoCoordinate(latitude: lat, longitude: lon)
                guard point.isValid else { message = "Use latitude −90…90 and longitude −180…180."; return }
                focus(point, title: "Coordinates \(lat), \(lon)"); return
            }
        }
        guard completion != nil || !text.isEmpty else { return }
        searchTask?.cancel(); activeSearch?.cancel(); searchGeneration = UUID(); let generation = searchGeneration
        let request = completion.map(MKLocalSearch.Request.init(completion:)) ?? MKLocalSearch.Request()
        if completion == nil { request.naturalLanguageQuery = text }
        request.region = .init(center: .init(latitude: area.center.latitude, longitude: area.center.longitude), span: .init(latitudeDelta: area.latitudeSpan, longitudeDelta: area.longitudeSpan))
        let search = MKLocalSearch(request: request); activeSearch = search; searching = true; message = nil
        searchTask = Task {
            guard !Task.isCancelled else { return }
            do {
                let response = try await search.start()
                guard generation == searchGeneration else { return }; searching = false
                guard let item = response.mapItems.first else { message = "No place found. Try a city, address or coordinates."; return }
                let point = item.placemark.coordinate
                focus(.init(latitude: point.latitude, longitude: point.longitude), title: item.name ?? text)
            } catch { guard generation == searchGeneration else { return }; searching = false; message = "Place search unavailable. Coordinates and reference places still work. " + error.localizedDescription }
        }
    }
    func nearby() {
        message = nil; requestingLocation = true
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways: locationManager.requestLocation()
        default: requestingLocation = false; message = "Location access is unavailable. Search a place or enter coordinates instead."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requestingLocation else { return }
        if manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else if manager.authorizationStatus != .notDetermined { requestingLocation = false; message = "Location access was not granted. Place search remains available." }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requestingLocation, let location = locations.last, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) <= 120 else { return }
        requestingLocation = false; let c = location.coordinate; focus(.init(latitude: c.latitude, longitude: c.longitude), title: "Nearby", recordRecent: false)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { requestingLocation = false; message = "Current location unavailable. " + error.localizedDescription }
}
