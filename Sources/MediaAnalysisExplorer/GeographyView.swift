import SwiftUI
import MapKit
import ExplorerCore

struct GeographyView: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject var geography: GeographyModel
    @State private var showingGroups = false
    @State private var showingAreaCells = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceControls
            if geography.loading {
                ProgressView("Reading geographic cells…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = geography.failure {
                ContentUnavailableView {
                    Label("Geography unavailable", systemImage: "map")
                } description: { Text(failure) } actions: {
                    Button("Retry") { model.loadGeography(reload: true) }
                    if geography.source?.isCache == true { Button("Request Cache Access") { model.requestCacheAccess() } }
                    Button("Browse Installed Atlas") { model.loadGeography(source: .installed) }
                }
            } else if let atlas = geography.atlas {
                browsingControls
                if let message = geography.message {
                    HStack { Text(message).font(.caption).foregroundStyle(.secondary); Spacer(); Button { geography.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss geography message") }
                }
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        if geography.worldOverview {
                            GeographyWorldOverview(geography: geography, atlas: atlas).frame(minHeight: 280)
                        } else { geographyMap(atlas) }
                        areaSummary(atlas)
                        if showingAreaCells { areaCells(atlas).frame(height: 160) }
                    }.frame(minWidth: 340, maxWidth: .infinity)
                    ScrollView { GeographyInspector(model: model, geography: geography, atlas: atlas).padding(14) }
                        .frame(minWidth: 300, idealWidth: 350, maxWidth: 450)
                }
            } else {
                ContentUnavailableView("Explore geographic scene data", systemImage: "map", description: Text("Open the daemon cache or the installed reference atlas."))
            }
        }
        .task { model.ensureGeography() }
    }
    private var sourceControls: some View {
        HStack {
            Text("Geography").font(.title3.weight(.semibold))
            Picker("Source", selection: Binding(get: { geography.source?.id ?? model.geographySources.first!.id }, set: { id in
                if let source = model.geographySources.first(where: { $0.id == id }) { model.loadGeography(source: source) }
            })) {
                ForEach(model.geographySources) { source in Text(source.title).tag(source.id) }
            }.frame(maxWidth: 240)
            if geography.source?.isCache == true { Button("Back to Cache File") { model.revealGeographyFile() } }
            Spacer()
            if let atlas = geography.atlas { Text("\(atlas.cells.count.formatted()) cells · \(atlas.groups.count) groups").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button { model.loadGeography(reload: true) } label: { Image(systemName: "arrow.clockwise") }.help("Reload the selected geography source").disabled(geography.loading)
        }
    }
    private var browsingControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { geography.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!geography.canGoBack).help("Previous geography view")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("City, address or landmark", text: $geography.searchText).onSubmit { geography.search() }
                        .accessibilityIdentifier("geography-search")
                    if geography.searching { ProgressView().controlSize(.small) }
                }.padding(6).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6)).frame(minWidth: 220, maxWidth: 370)
                Button("Nearby", systemImage: "location") { geography.nearby() }.disabled(geography.requestingLocation)
                Menu("Explore") {
                    ForEach(GeographyExample.all) { place in Button(place.title) { geography.focus(place.point, title: place.title) } }
                    Divider()
                    Button("World Coverage") { geography.showWorld() }
                    if !geography.bookmarks.isEmpty {
                        SwiftUI.Section("Bookmarks") { ForEach(geography.bookmarks) { item in Button(item.title) { geography.restore(item) } } }
                    }
                    if !geography.recent.isEmpty {
                        SwiftUI.Section("Recent Areas") { ForEach(geography.recent) { item in Button(item.title) { geography.restore(item) } } }
                    }
                }.fixedSize()
                Button(geography.theme.flatMap { geography.atlas?.groups[$0].name } ?? "Scene Groups", systemImage: "line.3.horizontal.decrease") { showingGroups.toggle() }
                    .popover(isPresented: $showingGroups) { groupCatalog.frame(width: 340, height: 520).padding(14) }
                InfoButton(title: "Explore geography", text: "Search a place, coordinates, or geohash, then click a cell to see its scene groups. Zoom in for individual cells. Place search and the map use Apple Maps.")
            }
            if !geography.searchText.isEmpty, !geography.completions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(geography.completions.enumerated()), id: \.offset) { _, completion in
                        Button { geography.search(completion) } label: {
                            HStack { Text(completion.title); Text(completion.subtitle).foregroundStyle(.secondary).lineLimit(1); Spacer() }.font(.caption)
                        }.buttonStyle(.plain).padding(5)
                    }
                }.padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    private var groupCatalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explore a Scene Group").font(.headline)
            TextField("Group, scene label or ID", text: $geography.groupQuery).textFieldStyle(.roundedBorder)
            Button("Show All Coverage") { geography.setTheme(nil); showingGroups = false }
            List(geography.visibleGroups) { group in
                Button {
                    geography.setTheme(group.id); showingGroups = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name).foregroundStyle(.primary)
                        Text("\(group.cellCount.formatted()) cells · \(group.sceneIDs.count) scene IDs").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }.listStyle(.plain)
            Text("Ranks cells in the visible map by this group’s stored weight. Equal weights remain ties.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func geographyMap(_ atlas: SceneGeography) -> some View {
        let maximumCount = geography.viewport.tiles.map(\.count).max() ?? 1
        return MapReader { proxy in
            Map(position: $geography.camera) {
                ForEach(geography.viewport.tiles) { tile in
                    MapPolygon(coordinates: corners(tile.bounds))
                        .foregroundStyle(tileColor(tile).opacity(tileOpacity(tile, atlas: atlas, maximumCount: maximumCount)))
                        .stroke(tileColor(tile).opacity(0.45), lineWidth: geography.viewport.precision == 6 ? 0.6 : 0.25)
                }
                if let cell = geography.selectedCell {
                    MapPolygon(coordinates: corners(cell.bounds)).foregroundStyle(.clear).stroke(.orange, lineWidth: 3)
                }
                if let point = geography.selectedPoint {
                    Annotation(geography.placeTitle, coordinate: .init(latitude: point.latitude, longitude: point.longitude), anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.orange).background(.white, in: Circle())
                    }
                }
                if let comparison = geography.comparisonCell {
                    MapPolygon(coordinates: corners(comparison.bounds)).foregroundStyle(.clear).stroke(.purple, lineWidth: 2)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
            .onMapCameraChange(frequency: .onEnd) { context in
                let region = context.region
                geography.requestViewport(.init(center: .init(latitude: region.center.latitude, longitude: region.center.longitude), latitudeSpan: min(180, region.span.latitudeDelta), longitudeSpan: min(360, region.span.longitudeDelta)))
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) { geography.select(.init(latitude: coordinate.latitude, longitude: coordinate.longitude)) }
            }
            .overlay(alignment: .topLeading) {
                Text(geography.theme == nil ? (geography.viewport.precision == 6 ? "Cached cells" : "Cached cells per block · stronger fill = more") : (geography.viewport.precision == 6 ? "Stored group weight · stronger fill = higher" : "Maximum group weight per block · stronger fill = higher"))
                    .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5)).padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if geography.querying { ProgressView("Reading this area…").controlSize(.small).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5)).padding(8) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).frame(minHeight: 280)
    }
    private func tileColor(_ tile: GeographyTile) -> Color { geography.theme == nil ? .blue : .teal }
    private func tileOpacity(_ tile: GeographyTile, atlas: SceneGeography, maximumCount: Int) -> Double {
        if let weight = tile.maximumWeight { return 0.12 + 0.58 * min(1, weight / (atlas.weights.max() ?? 1)) }
        return 0.12 + 0.5 * log1p(Double(tile.count)) / log1p(Double(maximumCount))
    }
    private func corners(_ b: GeoBounds) -> [CLLocationCoordinate2D] {
        [.init(latitude: b.south, longitude: b.west), .init(latitude: b.south, longitude: b.east), .init(latitude: b.north, longitude: b.east), .init(latitude: b.north, longitude: b.west)]
    }
    private func areaSummary(_ atlas: SceneGeography) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(geography.viewport.totalCells.formatted()) cells in view").font(.callout.weight(.medium))
                if geography.theme != nil { Text("· \(geography.viewport.matchingCells.formatted()) matching group").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(showingAreaCells ? "Hide Area List" : "Browse Area") { showingAreaCells.toggle() }.controlSize(.small)
            }
            let counts = geography.viewport.groupCounts
            let common = atlas.groups.filter { counts.indices.contains($0.id) && counts[$0.id] > 0 }.sorted { counts[$0.id] > counts[$1.id] }
            if !common.isEmpty {
                Text("Common here: " + common.prefix(3).map { $0.name }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            } else if !geography.querying { Text("No cached cell centers in this map area. Pan or zoom out to explore surrounding records.").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 4)
    }
    private func areaCells(_ atlas: SceneGeography) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                Text(geography.theme == nil ? "Nearest cells to the map center · up to 60" : "Highest stored group weights in view · up to 60; distance breaks ties").font(.caption).foregroundStyle(.secondary)
                ForEach(geography.viewport.cells) { cell in
                    Button { geography.selectCell(cell, centerMap: true) } label: {
                        HStack {
                            Text(cell.key).font(.caption.monospaced())
                            Text(atlas.assignments(for: cell).prefix(3).map { atlas.groups[Int($0.group)].name }.joined(separator: " · ")).font(.caption).lineLimit(1)
                            Spacer()
                            if let theme = geography.theme, let value = atlas.weight(in: cell, group: theme) { Text(value.formatted(.number.precision(.fractionLength(4)))).font(.caption.monospacedDigit()) }
                        }.padding(5).background(geography.selectedCell?.code == cell.code ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct GeographyInspector: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject var geography: GeographyModel
    let atlas: SceneGeography
    @State private var expandedGroups = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(geography.placeTitle).font(.title3.weight(.semibold))
                Spacer()
                Button { geography.toggleBookmark() } label: { Image(systemName: geography.isBookmarked ? "bookmark.fill" : "bookmark") }.help("Bookmark this area").disabled(geography.selectedPoint == nil)
            }
            HStack {
                Button("Zoom In") {
                    if let point = geography.selectedPoint { geography.moveCamera(.init(center: point, latitudeSpan: 0.025, longitudeSpan: 0.04)) }
                }
            }.controlSize(.small)
            if let cell = geography.selectedCell { cellContents(cell) }
            else {
                Label("No record at this point", systemImage: "square.dashed").font(.headline)
                Text("This point falls outside the atlas’s cached coverage.").font(.callout).foregroundStyle(.secondary)
            }
            if let group = geography.currentGroup { groupContents(group) }
            if geography.comparisonCell != nil { comparison }
            if let cell = geography.selectedCell, !geography.mediaSceneIDs.isEmpty { mediaContext(cell) }
            recordDetails
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func cellContents(_ cell: GeographyCell) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scene groups in this cell").font(.headline)
            Text("Stored weights · reference parameters").font(.caption).foregroundStyle(.secondary)
            if let theme = geography.theme, atlas.weight(in: cell, group: theme) == nil {
                Text("This cell does not list \(atlas.groups[theme].name). Its other groups are shown below.").font(.caption).foregroundStyle(.secondary)
            }
            let pairs = atlas.assignments(for: cell).sorted { atlas.weights[Int($0.weight)] > atlas.weights[Int($1.weight)] }
            ForEach(Array((expandedGroups ? pairs : Array(pairs.prefix(7))).enumerated()), id: \.offset) { _, pair in
                groupRow(pair, cell: cell)
            }
            if pairs.count > 7 { Button(expandedGroups ? "Show Fewer Groups" : "All \(pairs.count) Groups") { expandedGroups.toggle() }.font(.caption) }
            HStack {
                Button(geography.comparisonCode == cell.code ? "Pinned for Comparison" : "Pin for Comparison", systemImage: "pin") { geography.pinComparison() }
                    .disabled(geography.comparisonCode == cell.code)
            }.controlSize(.small)
        }
    }
    private func groupRow(_ pair: GeographyAssignment, cell: GeographyCell) -> some View {
        let group = atlas.groups[Int(pair.group)], weight = atlas.weights[Int(pair.weight)]
        return Button { geography.selectedGroup = group.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(group.name).foregroundStyle(.primary); Spacer(); Text(weight.formatted(.number.precision(.fractionLength(4)))).monospacedDigit().foregroundStyle(.secondary) }
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2).fill(Color.teal.opacity(0.6)).frame(width: max(1, proxy.size.width * min(1, weight / (atlas.weights.max() ?? 1))))
                }.frame(height: 3)
            }.font(.callout).padding(.vertical, 3)
        }.buttonStyle(.plain)
    }
    private func groupContents(_ group: GeographyGroup) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(group.name).font(.headline); Spacer(); Button { geography.selectedGroup = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close group details") }
                Text("\(group.cellCount.formatted()) cells · \(group.sceneIDs.count) exact scene IDs").font(.caption).foregroundStyle(.secondary)
                Button("Show Group on Map", systemImage: "map") { geography.setTheme(group.id) }
                DisclosureGroup("Scene IDs & Taxonomy Links") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.sceneIDs, id: \.self) { id in
                            Button {
                                if let key = geography.sceneKey(id) { model.openGeographyConcept(key) }
                            } label: { HStack { Text(geography.sceneName(id)); Spacer(); Text(String(id)).font(.caption.monospacedDigit()).foregroundStyle(.secondary); Image(systemName: "arrow.up.right") } }
                                .buttonStyle(.plain).disabled(geography.sceneKey(id) == nil)
                        }
                    }.padding(.top, 6)
                }.font(.caption)
                Text("Explicit geography membership. Taxonomy parents and children are separate links.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var comparison: some View {
        GroupBox("Cell Comparison") {
            VStack(alignment: .leading, spacing: 8) {
                if let pinned = geography.comparisonCell {
                    HStack { Text("Pinned: \(pinned.key)").font(.caption.monospaced()); Spacer(); Button("Clear") { geography.comparisonCode = nil }.controlSize(.small) }
                    if let selected = geography.selectedCell, pinned.code != selected.code {
                        Text("\(pinned.coordinate.distance(to: selected.coordinate).formatted(.number.precision(.fractionLength(0)))) m apart").font(.caption).foregroundStyle(.secondary)
                        let indexes = Set(atlas.assignments(for: pinned).map { Int($0.group) }).union(atlas.assignments(for: selected).map { Int($0.group) }).sorted()
                        HStack { Text("Group"); Spacer(); Text("Pinned / Selected") }.font(.caption.weight(.medium))
                        ForEach(indexes, id: \.self) { index in
                            HStack {
                                Text(atlas.groups[index].name).lineLimit(1); Spacer()
                                Text(weightText(atlas.weight(in: pinned, group: index)) + " / " + weightText(atlas.weight(in: selected, group: index))).monospacedDigit()
                            }.font(.caption)
                        }
                        Text("— means the group is absent from that cell.").font(.caption2).foregroundStyle(.secondary)
                    } else { Text("Select another cell to compare its groups and weights.").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func weightText(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(4))) } ?? "—" }
    private func mediaContext(_ cell: GeographyCell) -> some View {
        GroupBox("Media Geography Context") {
            VStack(alignment: .leading, spacing: 8) {
                Text(geography.mediaName ?? "Selected media").font(.callout)
                let matches = atlas.assignments(for: cell).flatMap { pair in atlas.groups[Int(pair.group)].sceneIDs.filter { geography.mediaSceneIDs.contains($0) } }
                Text(matches.isEmpty ? "No stored scene IDs overlap this cell’s explicit groups." : "Overlapping stored scenes: " + matches.prefix(20).map { geography.sceneName($0) }.joined(separator: ", ")).font(.caption)
                DisclosureGroup("Derived Score Explanation") {
                    VStack(alignment: .leading, spacing: 7) {
                        Stepper("Maximum matches: \(geography.scoreMaximum)", value: $geography.scoreMaximum, in: 0...250)
                        HStack { Text("Popularity weight"); Slider(value: $geography.scoreBlend, in: 0...1); Text(geography.scoreBlend.formatted(.number.precision(.fractionLength(2)))) }
                        if let score = try? atlas.score(cell: cell, sceneIDs: geography.mediaSceneIDs, maximumMatches: geography.scoreMaximum, popularityWeight: geography.scoreBlend) {
                            Text("Derived score: \(score.formatted(.number.precision(.fractionLength(6))))").monospacedDigit()
                        }
                        Text("Uses the asset’s loaded stored scene IDs and your parameters. This is not a stored photo confidence or proof of the daemon’s caller settings. −2 means no retained match.").foregroundStyle(.secondary)
                    }.font(.caption).padding(.top, 6)
                }
                Button("Clear Media Context") { geography.mediaSceneIDs = []; geography.mediaName = nil }.controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var recordDetails: some View {
        DisclosureGroup("Record & Source Details") {
            VStack(alignment: .leading, spacing: 8) {
                if let cell = geography.selectedCell {
                    let b = cell.bounds
                    Text("Geohash: \(cell.key)")
                    Text("Latitude: \(b.south) … \(b.north)\nLongitude: \(b.west) … \(b.east)")
                    Text("Popularity kind 1: \(cell.popularity1)\nPopularity kind 0: \(cell.popularity0)")
                    Text("Popularity definitions beyond enum 0/1 remain unknown. Stored weights can exceed 1.").foregroundStyle(.secondary)
                    ForEach(Array(atlas.assignments(for: cell).enumerated()), id: \.offset) { _, pair in Text("\(atlas.groups[Int(pair.group)].name): pair \(pair.group):\(pair.weight) · \(atlas.weights[Int(pair.weight)])") }
                }
                Divider()
                Text(atlas.source.title)
                Text(atlas.source.url.path).textSelection(.enabled)
                Text("\(atlas.storedBytes.formatted()) bytes · \(atlas.assignmentCount.formatted()) group links")
                Text(atlas.source.isCache ? "Index v2 · checksum \(atlas.checksumValid ? "verified" : "unverified")" : "Installed archive · source v2")
                Text(!atlas.source.isCache ? "Group names read from this source archive." : atlas.companionMatched ? "Group names verified against the companion archive." : "Group names unavailable; numeric groups are preserved.")
                Text("SHA-256: \(atlas.contentSHA256)").textSelection(.enabled)
                Text("The investigated build’s cache omits nine source cells at 64 KiB parser boundaries. The selected source is read independently; missing cells are never backfilled.").foregroundStyle(.secondary)
                Text("Map and search place names are separate from the atlas. Coverage counts include cell centers in the visible area. Coarse block shading summarizes only those records.").foregroundStyle(.secondary)
            }.font(.caption2).padding(.top, 6)
        }.font(.caption)
    }
}
