import XCTest
import CryptoKit
@testable import ExplorerCore

final class SceneGeographyTests: XCTestCase {
    private let source = GeographySource(url: URL(fileURLWithPath: "/fixture/SceneGeography_v1.bz2"), isCache: false)
    private var small: String { "v:2\nf:0.5\nf:1.7062603531702307\ns:Bridge,7\ns:Sky,1,2\np:9q8zhu,0.695,0.127,0:1,1:0\np:u09tun,0.882,1,1:1\n" }
    func testGeohashBoundsMidpointsAndDateLine() throws {
        let point = GeoCoordinate(latitude: 37.8199, longitude: -122.4783)
        let code = try XCTUnwrap(GeoHash.encode(point)); XCTAssertEqual(GeoHash.key(code), "9q8zhu")
        let bounds = GeoHash.bounds(code)
        XCTAssertEqual(bounds.latitudeSpan, 0.0054931640625); XCTAssertEqual(bounds.longitudeSpan, 0.010986328125)
        XCTAssertEqual(GeoHash.encode(bounds.center), code)
        XCTAssertEqual(GeoHash.key(try XCTUnwrap(GeoHash.encode(.init(latitude: 48.8584, longitude: 2.2945)))), "u09tun")
        XCTAssertNil(GeoHash.encode(.init(latitude: .nan, longitude: 0))); XCTAssertNil(GeoHash.code("invalid"))
        let crossing = GeoArea(center: .init(latitude: 0, longitude: 179), latitudeSpan: 20, longitudeSpan: 8)
        XCTAssertTrue(crossing.contains(.init(latitude: 0, longitude: -179))); XCTAssertFalse(crossing.contains(.init(latitude: 0, longitude: -170)))
        XCTAssertEqual(point.distance(to: point), 0)
    }
    func testGroupLinkageScoreAndSparseNearbyCoverage() throws {
        let atlas = try SceneGeographyReader.decodeArchive(Data(small.utf8), source: source)
        XCTAssertEqual(atlas.groups.map(\.cellCount), [1, 2]); XCTAssertEqual(atlas.groups[1].sceneIDs, [1, 2])
        let cell = try XCTUnwrap(atlas.cell(key: "9q8zhu"))
        XCTAssertEqual(cell.popularity1, 0.695); XCTAssertEqual(cell.popularity0, 0.127)
        XCTAssertEqual(atlas.group(forSceneID: 7)?.id, 0); XCTAssertNil(atlas.group(forSceneID: 999))
        XCTAssertEqual(try atlas.score(cell: cell, sceneIDs: [7], maximumMatches: 3, popularityWeight: 0), 1.7062603531702307)
        XCTAssertEqual(try atlas.score(cell: cell, sceneIDs: [7, 1, 2], maximumMatches: 1, popularityWeight: 0), 1.7062603531702307)
        XCTAssertEqual(try atlas.score(cell: cell, sceneIDs: [7, 1, 2], maximumMatches: 3, popularityWeight: 0), 2.7062603531702307)
        XCTAssertEqual(try atlas.score(cell: cell, sceneIDs: [7], maximumMatches: 3, popularityWeight: 0.25), (0.75 * 1.7062603531702307 + 0.25 * 0.127) / 4, accuracy: 1e-14)
        XCTAssertEqual(try atlas.score(cell: cell, sceneIDs: [], maximumMatches: 3, popularityWeight: 1), -2)
        XCTAssertEqual(try atlas.score(cell: nil, sceneIDs: [7], maximumMatches: 3, popularityWeight: 1), -1)
        XCTAssertThrowsError(try atlas.score(cell: cell, sceneIDs: [7], maximumMatches: 251, popularityWeight: 0.2))
        XCTAssertEqual(try atlas.nearby(cell.coordinate).map(\.key), ["9q8zhu"])
        XCTAssertEqual(try atlas.nearby(cell.coordinate, group: 0).count, 1)
        XCTAssertTrue(try atlas.nearby(.init(latitude: -90, longitude: 0)).isEmpty)
        let world = try atlas.viewport(.init(center: .init(latitude: 0, longitude: 0), latitudeSpan: 180, longitudeSpan: 360))
        XCTAssertEqual(world.totalCells, 2); XCTAssertEqual(world.tiles.reduce(0) { $0 + $1.count }, 2); XCTAssertEqual(world.groupCounts, [1, 2])
        let theme = try atlas.viewport(.init(center: .init(latitude: 0, longitude: 0), latitudeSpan: 180, longitudeSpan: 360), group: 0)
        XCTAssertEqual(theme.matchingCells, 1); XCTAssertEqual(theme.cells.first?.key, "9q8zhu"); XCTAssertEqual(theme.tiles.first?.maximumWeight, 1.7062603531702307)
    }
    func testWorldBlockDrilldownUsesActualCellAndThemeMembership() throws {
        let atlas = try SceneGeographyReader.decodeArchive(Data(small.utf8), source: source)
        let world = try atlas.viewport(.init(center: .init(latitude: 0, longitude: 0), latitudeSpan: 180, longitudeSpan: 360))
        let golden = try XCTUnwrap(atlas.cell(key: "9q8zhu"))
        let tile = try XCTUnwrap(world.tiles.first { $0.code == golden.code >> (5 * (6 - $0.precision)) })
        XCTAssertEqual(try atlas.nearestCell(in: tile, to: tile.bounds.center)?.key, "9q8zhu")
        XCTAssertEqual(try atlas.nearestCell(in: tile, to: tile.bounds.center, group: 0)?.key, "9q8zhu")
        XCTAssertNil(try atlas.nearestCell(in: tile, to: tile.bounds.center, group: 99))
        let invalid = GeographyTile(code: .max, precision: 6, count: 1, maximumWeight: nil)
        XCTAssertThrowsError(try atlas.nearestCell(in: invalid, to: tile.bounds.center))
    }

    func testInvalidReferencesDuplicateKeysAndCancellation() throws {
        for invalid in [small + "p:9q8zhu,0.2,0.2,0:0\n", small.replacingOccurrences(of: "0:1", with: "8:1"), small.replacingOccurrences(of: "0:1", with: "0:9"), small.replacingOccurrences(of: "0.695", with: "nan"), small.replacingOccurrences(of: "v:2", with: "v:3"), small + "x:unknown\n", small.replacingOccurrences(of: "s:Bridge,7", with: "s:Bridge,7,7"), small.replacingOccurrences(of: "0:1,1:0", with: "0:1,0:0")] {
            XCTAssertThrowsError(try SceneGeographyReader.decodeArchive(Data(invalid.utf8), source: source))
        }
        let budget = WorkBudget(); budget.cancel()
        XCTAssertThrowsError(try SceneGeographyReader.decodeArchive(Data(small.utf8), source: source, budget: budget))
        XCTAssertThrowsError(try SceneGeographyReader.decodeIndex(Data(repeating: 0, count: 512), source: source))
        XCTAssertThrowsError(try SceneGeographyReader.decompress(Data([0x42, 0x5a, 0x68])))
    }
    func testEveryRealCacheRecordAgainstIndependentSourceAndNoBackfill() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("research-notes/scene-geography")
        let url = root.appendingPathComponent("native-cache/PFSceneGeographyData.index")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Geography research copy unavailable") }
        let bytes = try Data(contentsOf: url), before = SHA256.hash(data: bytes)
        let archiveBytes = try Data(contentsOf: root.appendingPathComponent("SceneGeography_v1.bz2"))
        let start = Date()
        let archive = try SceneGeographyReader.decodeArchive(SceneGeographyReader.decompress(archiveBytes), source: source, storedData: archiveBytes, budget: WorkBudget(seconds: 120))
        let cache = try SceneGeographyReader.load(.init(url: url, isCache: true), budget: WorkBudget(seconds: 120))
        XCTAssertEqual(cache.cells.count, 554185); XCTAssertEqual(archive.cells.count, 554194)
        XCTAssertEqual(cache.groups.count, 100); XCTAssertEqual(cache.groups.flatMap(\.sceneIDs).count, 882)
        XCTAssertEqual(cache.assignmentCount, 2435162); XCTAssertEqual(cache.weights, archive.weights)
        XCTAssertEqual(cache.groups.map(\.sceneIDs), archive.groups.map(\.sceneIDs)); XCTAssertTrue(cache.checksumValid); XCTAssertTrue(cache.companionMatched)
        var mismatches = 0
        for cell in cache.cells {
            guard let original = archive.cell(code: cell.code) else { mismatches += 1; continue }
            if cell.popularity0 != original.popularity0 || cell.popularity1 != original.popularity1 || !cache.assignments(for: cell).elementsEqual(archive.assignments(for: original)) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0)
        let omitted = Set(archive.cells.map(\.code)).subtracting(cache.cells.map(\.code)).map { GeoHash.key($0) }.sorted()
        XCTAssertEqual(omitted, ["7nj8fs", "9r04bb", "c816v3", "d3fy74", "dnhret", "thewsy", "u0tj0n", "w6tq46", "wvzpd1"])
        let canyon = GeoCoordinate(latitude: 36.1069, longitude: -112.1129)
        XCTAssertNil(cache.cell(at: canyon)); XCTAssertFalse(try cache.nearby(canyon).isEmpty)
        let world = try cache.viewport(.init(center: .init(latitude: 0, longitude: 0), latitudeSpan: 180, longitudeSpan: 360), budget: WorkBudget(seconds: 30))
        XCTAssertEqual(world.totalCells, cache.cells.count); XCTAssertEqual(world.tiles.reduce(0) { $0 + $1.count }, cache.cells.count); XCTAssertLessThanOrEqual(world.tiles.count, 2000)
        XCTAssertEqual(world.groupCounts[14], 3811); XCTAssertEqual(world.groupCounts[39], 80595)
        var corrupt = bytes; corrupt[1000] ^= 1
        XCTAssertThrowsError(try SceneGeographyReader.decodeIndex(corrupt, source: source, budget: WorkBudget(seconds: 30)))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
        print("Complete geography/source verification took \(Date().timeIntervalSince(start)) seconds")
    }
    func testControlledIndexPointerCorruptionWithValidChecksum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("research-notes/scene-geography/boundary-controls")
        let url = root.appendingPathComponent("newline-65535.index")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Boundary control index unavailable") }
        var data = try Data(contentsOf: url)
        let original = try SceneGeographyReader.decodeIndex(data, source: .init(url: url, isCache: true))
        XCTAssertEqual(original.cells.count, 2)
        let keyRange = try XCTUnwrap(data.range(of: Data("u09tun".utf8)))
        let entry = keyRange.lowerBound - 9
        // Break the pair-vector pointer while recomputing a valid integrity checksum.
        withUnsafeBytes(of: Int64.max.littleEndian) { data.replaceSubrange(entry + 0x38..<entry + 0x40, with: $0) }
        let magic = try XCTUnwrap(data.range(of: Data("PFSceneGeography".utf8))).lowerBound
        func fnv(_ range: Range<Int>) -> UInt64 { range.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64(bitPattern: Int64(Int8(bitPattern: data[$1])))) &* 0x100000001b3 } }
        let checksum = (fnv(0..<magic) ^ fnv(magic + 45..<data.count)).byteSwapped.littleEndian
        withUnsafeBytes(of: checksum) { data.replaceSubrange(magic + 37..<magic + 45, with: $0) }
        XCTAssertThrowsError(try SceneGeographyReader.decodeIndex(data, source: .init(url: url, isCache: true)))
    }
}
