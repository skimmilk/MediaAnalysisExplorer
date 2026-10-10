import SwiftUI
import ExplorerCore

/// A full-world overview uses an explicit equirectangular projection; MapKit's
/// globe camera can expose only a hemisphere. The local inspection map remains MapKit.
struct GeographyWorldOverview: View {
    @ObservedObject var geography: GeographyModel
    let atlas: SceneGeography
    private static let land: [[GeoCoordinate]] = {
        guard let url = Bundle.module.url(forResource: "land-110m", withExtension: "geojson", subdirectory: "Geography"),
              let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let features = object["features"] as? [[String: Any]] else { return [] }
        var rings: [[GeoCoordinate]] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            let polygons: [[[[Double]]]]
            if let values = geometry["coordinates"] as? [[[[Double]]]] { polygons = values }
            else if let values = geometry["coordinates"] as? [[[Double]]] { polygons = [values] }
            else { continue }
            for polygon in polygons {
                for ring in polygon {
                    let points = ring.compactMap { pair -> GeoCoordinate? in
                        guard pair.count >= 2 else { return nil }; let point = GeoCoordinate(latitude: pair[1], longitude: pair[0]); return point.isValid ? point : nil
                    }
                    if points.count > 2 { rings.append(points) }
                }
            }
        }; return rings
    }()
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = min(geometry.size.height - 80, width / 2)
            let maximum = geography.viewport.tiles.map(\.count).max() ?? 1
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(geography.theme == nil ? "World Coverage" : "World · \(atlas.groups[geography.theme!].name)").font(.headline)
                    Spacer()
                    if geography.querying { ProgressView().controlSize(.small) }
                    Button("Return to Selected Place") {
                        if let point = geography.selectedPoint { geography.focus(point, title: geography.placeTitle) }
                    }.controlSize(.small)
                }
                Spacer(minLength: 0)
                Canvas { context, size in
                    func project(_ point: GeoCoordinate) -> CGPoint { .init(x: (point.longitude + 180) / 360 * size.width, y: (90 - point.latitude) / 180 * size.height) }
                    var land = Path()
                    for ring in Self.land {
                        land.move(to: project(ring[0])); for point in ring.dropFirst() { land.addLine(to: project(point)) }; land.closeSubpath()
                    }
                    context.fill(land, with: .color(.secondary.opacity(0.18)), style: .init(eoFill: true))
                    for tile in geography.viewport.tiles {
                        let b = tile.bounds, start = project(.init(latitude: b.north, longitude: b.west)), end = project(.init(latitude: b.south, longitude: b.east))
                        let opacity = tile.maximumWeight.map { 0.15 + 0.6 * min(1, $0 / (atlas.weights.max() ?? 1)) } ?? (0.15 + 0.6 * log1p(Double(tile.count)) / log1p(Double(maximum)))
                        let path = Path(CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y))
                        context.fill(path, with: .color((geography.theme == nil ? Color.blue : Color.teal).opacity(opacity)))
                    }
                    for lat in [-60.0, 0, 60] {
                        var line = Path(); line.move(to: project(.init(latitude: lat, longitude: -180))); line.addLine(to: project(.init(latitude: lat, longitude: 180)))
                        context.stroke(line, with: .color(.secondary.opacity(0.2)), style: .init(lineWidth: 0.5, dash: [3, 4]))
                    }
                    if let selected = geography.selectedPoint {
                        let p = project(selected); context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.orange))
                    }
                }
                .frame(height: max(140, height))
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .accessibilityLabel("World geography coverage")
                .accessibilityAddTraits(.isImage)
                .accessibilityHint("Use Explore places or Browse Area to navigate selectable cells.")
                .onTapGesture { point in
                    let coordinate = GeoCoordinate(latitude: 90 - point.y / max(140, height) * 180, longitude: point.x / width * 360 - 180)
                    geography.exploreWorld(coordinate)
                }
                HStack { Text("180° W"); Spacer(); Text("0° longitude"); Spacer(); Text("180° E") }.font(.caption2).foregroundStyle(.secondary)
                Text(geography.theme == nil ? "Cached cells per block · stronger fill = more records" : "Maximum stored group weight per block · stronger fill = higher weight").font(.caption).foregroundStyle(.secondary)
                Text("Click a shaded block to inspect its nearest cached cell. Land outline: Natural Earth, public domain. Coordinates use an equirectangular projection.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
