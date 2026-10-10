import Foundation
import CryptoKit
import CBZip2
import CAtlasSupport

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    public func distance(to other: Self) -> Double {
        let a = latitude * .pi / 180, b = other.latitude * .pi / 180
        let d = (other.latitude - latitude) * .pi / 180, l = (other.longitude - longitude) * .pi / 180
        let h = sin(d / 2) * sin(d / 2) + cos(a) * cos(b) * sin(l / 2) * sin(l / 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}
public struct GeoBounds: Hashable, Sendable {
    public let south: Double, west: Double, north: Double, east: Double
    public var center: GeoCoordinate { .init(latitude: (south + north) / 2, longitude: (west + east) / 2) }
    public var latitudeSpan: Double { north - south }
    public var longitudeSpan: Double { east - west }
}
public struct GeoArea: Codable, Hashable, Sendable {
    public let center: GeoCoordinate
    public let latitudeSpan: Double, longitudeSpan: Double
    public init(center: GeoCoordinate, latitudeSpan: Double, longitudeSpan: Double) {
        self.center = center; self.latitudeSpan = latitudeSpan; self.longitudeSpan = longitudeSpan
    }
    public var isValid: Bool { center.isValid && latitudeSpan.isFinite && longitudeSpan.isFinite && latitudeSpan > 0 && longitudeSpan > 0 && latitudeSpan <= 180 && longitudeSpan <= 360 }
    public func contains(_ point: GeoCoordinate) -> Bool {
        let delta = abs(point.longitude - center.longitude).truncatingRemainder(dividingBy: 360)
        return abs(point.latitude - center.latitude) <= latitudeSpan / 2 && min(delta, 360 - delta) <= longitudeSpan / 2
    }
}
public enum GeoHash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz".utf8)
    public static func key(_ code: UInt32, precision: Int = 6) -> String {
        guard (1...6).contains(precision) else { return "" }
        return String(bytes: (0..<precision).map { alphabet[Int((code >> (5 * (precision - 1 - $0))) & 31)] }, encoding: .utf8)!
    }
    public static func code(_ key: String) -> UInt32? {
        let bytes = Array(key.lowercased().utf8)
        guard bytes.count == 6 else { return nil }
        var result: UInt32 = 0
        for byte in bytes { guard let i = alphabet.firstIndex(of: byte) else { return nil }; result = (result << 5) | UInt32(i) }
        return result
    }
    public static func encode(_ point: GeoCoordinate) -> UInt32? {
        guard point.isValid else { return nil }
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0), result: UInt32 = 0
        for bit in 0..<30 {
            let isLongitude = bit % 2 == 0, interval = isLongitude ? lon : lat
            let mid = (interval.0 + interval.1) / 2, high = (isLongitude ? point.longitude : point.latitude) > mid
            result = (result << 1) | (high ? 1 : 0)
            if isLongitude { lon = high ? (mid, lon.1) : (lon.0, mid) } else { lat = high ? (mid, lat.1) : (lat.0, mid) }
        }; return result
    }
    public static func bounds(_ code: UInt32, precision: Int = 6) -> GeoBounds {
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        for bit in 0..<precision * 5 {
            let high = code & (1 << (precision * 5 - bit - 1)) != 0
            if bit % 2 == 0 { let mid = (lon.0 + lon.1) / 2; lon = high ? (mid, lon.1) : (lon.0, mid) }
            else { let mid = (lat.0 + lat.1) / 2; lat = high ? (mid, lat.1) : (lat.0, mid) }
        }; return .init(south: lat.0, west: lon.0, north: lat.1, east: lon.1)
    }
}
public struct GeographySource: Hashable, Identifiable, Sendable {
    public let url: URL, isCache: Bool
    public var id: String { url.path }
    public var title: String { isCache ? "Daemon geography cache" : "Installed geographic atlas" }
    public init(url: URL, isCache: Bool) { self.url = url; self.isCache = isCache }
    public static let installed = Self(url: URL(fileURLWithPath: "/System/Library/Photos/Resources/PhotosAtlas/SceneGeography_v1.bz2"), isCache: false)
    public static func isIndex(_ url: URL) -> Bool { url.lastPathComponent == "PFSceneGeographyData.index" }
}
public struct GeographyAssignment: Hashable, Sendable {
    public let group: UInt8, weight: UInt8
}
public struct GeographyGroup: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let sceneIDs: [UInt32]
    public let cellCount: Int
}
public struct GeographyCell: Identifiable, Sendable, Hashable {
    public var id: UInt32 { code }
    public var key: String { GeoHash.key(code) }
    public var bounds: GeoBounds { GeoHash.bounds(code) }
    public let code: UInt32
    public let coordinate: GeoCoordinate
    public let popularity1: Double, popularity0: Double
    let assignmentStart: Int, assignmentCount: Int
}
public struct GeographyTile: Identifiable, Sendable {
    public let code: UInt32, precision: Int, count: Int, maximumWeight: Double?
    public var id: UInt32 { code }
    public var bounds: GeoBounds { GeoHash.bounds(code, precision: precision) }
}
public struct GeographyViewport: Sendable {
    public let tiles: [GeographyTile]
    public let cells: [GeographyCell]
    public let totalCells: Int, matchingCells: Int, precision: Int
    public let groupCounts: [Int]
    public static let empty = Self(tiles: [], cells: [], totalCells: 0, matchingCells: 0, precision: 2, groupCounts: [])
}
public struct SceneGeography: Sendable {
    public let source: GeographySource
    public let cells: [GeographyCell], groups: [GeographyGroup], weights: [Double]
    public let assignments: [GeographyAssignment]
    public let contentSHA256: String, storedBytes: Int, checksumValid: Bool, magic: String?
    public let companionMatched: Bool
    public var assignmentCount: Int { assignments.count }
    public func cell(code: UInt32) -> GeographyCell? {
        var lo = 0, hi = cells.count
        while lo < hi { let mid = (lo + hi) / 2; if cells[mid].code < code { lo = mid + 1 } else { hi = mid } }
        return lo < cells.count && cells[lo].code == code ? cells[lo] : nil
    }
    public func cell(key: String) -> GeographyCell? { GeoHash.code(key).flatMap { cell(code: $0) } }
    public func cell(at point: GeoCoordinate) -> GeographyCell? { GeoHash.encode(point).flatMap { cell(code: $0) } }
    public func assignments(for cell: GeographyCell) -> ArraySlice<GeographyAssignment> { assignments[cell.assignmentStart..<cell.assignmentStart + cell.assignmentCount] }
    public func weight(in cell: GeographyCell, group: Int) -> Double? { assignments(for: cell).first { Int($0.group) == group }.map { weights[Int($0.weight)] } }
    public func group(forSceneID id: UInt64) -> GeographyGroup? { groups.first { $0.sceneIDs.contains { UInt64($0) == id } } }
    public func nearestCell(in tile: GeographyTile, to point: GeoCoordinate, group: Int? = nil, budget: WorkBudget = WorkBudget()) throws -> GeographyCell? {
        guard point.isValid, (1...6).contains(tile.precision), tile.code < 1 << (5 * tile.precision) else { throw ExplorerError("Invalid world overview selection") }
        let shift = 5 * (6 - tile.precision), lower = tile.code << shift, upper = UInt64(tile.code + 1) << shift
        var lo = 0, hi = cells.count
        while lo < hi { let mid = (lo + hi) / 2; if cells[mid].code < lower { lo = mid + 1 } else { hi = mid } }
        var best: GeographyCell?, distance = Double.infinity
        while lo < cells.count, UInt64(cells[lo].code) < upper {
            if lo % 1024 == 0 { try budget.check() }
            let candidate = cells[lo]
            if group == nil || weight(in: candidate, group: group!) != nil {
                let value = candidate.coordinate.distance(to: point)
                if value < distance { best = candidate; distance = value }
            }
            lo += 1
        }
        try budget.check(); return best
    }
    public func nearby(_ point: GeoCoordinate, group: Int? = nil, limit: Int = 40, maximumMeters: Double = 30_000, budget: WorkBudget = WorkBudget()) throws -> [GeographyCell] {
        guard point.isValid, (1...100).contains(limit), maximumMeters > 0, maximumMeters <= 100_000 else { throw ExplorerError("Invalid nearby geography query") }
        var candidates: [(Double, GeographyCell)] = []
        for (i, cell) in cells.enumerated() {
            if i % 4096 == 0 { try budget.check() }
            guard abs(cell.coordinate.latitude - point.latitude) <= maximumMeters / 110_000,
                  group == nil || weight(in: cell, group: group!) != nil else { continue }
            let distance = point.distance(to: cell.coordinate)
            if distance <= maximumMeters { candidates.append((distance, cell)) }
        }
        return candidates.sorted { $0.0 == $1.0 ? $0.1.code < $1.1.code : $0.0 < $1.0 }.prefix(limit).map(\.1)
    }
    public func viewport(_ area: GeoArea, group: Int? = nil, budget: WorkBudget = WorkBudget()) throws -> GeographyViewport {
        guard area.isValid, group == nil || groups.indices.contains(group!) else { throw ExplorerError("Invalid geography map region or group") }
        var precision = 2
        for p in 2...6 {
            let b = GeoHash.bounds(0, precision: p)
            if b.latitudeSpan >= area.latitudeSpan / 32 && b.longitudeSpan >= area.longitudeSpan / 48 { precision = p }
        }
        var hits: [(GeographyCell, Double?)] = [], totals = [Int](repeating: 0, count: groups.count), total = 0
        for (i, cell) in cells.enumerated() {
            if i % 4096 == 0 { try budget.check() }
            guard area.contains(cell.coordinate) else { continue }; total += 1
            for pair in assignments(for: cell) { totals[Int(pair.group)] += 1 }
            let value = group.flatMap { weight(in: cell, group: $0) }
            if group == nil || value != nil { hits.append((cell, value)) }
        }
        var bins: [UInt32: (Int, Double?)] = [:]
        repeat {
            bins = [:]
            for (i, hit) in hits.enumerated() {
                if i % 4096 == 0 { try budget.check() }
                let key = hit.0.code >> (5 * (6 - precision)), old = bins[key]
                bins[key] = ((old?.0 ?? 0) + 1, hit.1.map { max(old?.1 ?? 0, $0) })
            }
            if bins.count <= 2000 || precision == 2 { break }; precision -= 1
        } while true
        let tiles = bins.map { GeographyTile(code: $0.key, precision: precision, count: $0.value.0, maximumWeight: $0.value.1) }.sorted { $0.code < $1.code }
        let ranked = hits.sorted {
            if group != nil, $0.1 != $1.1 { return ($0.1 ?? 0) > ($1.1 ?? 0) }
            let a = area.center.distance(to: $0.0.coordinate), b = area.center.distance(to: $1.0.coordinate)
            return a == b ? $0.0.code < $1.0.code : a < b
        }.prefix(60).map(\.0)
        try budget.check()
        return .init(tiles: tiles, cells: ranked, totalCells: total, matchingCells: hits.count, precision: precision, groupCounts: totals)
    }
    public func score(cell: GeographyCell?, sceneIDs: Set<UInt32>, maximumMatches: Int, popularityWeight: Double) throws -> Double {
        guard (0...250).contains(maximumMatches), popularityWeight.isFinite, (0...1).contains(popularityWeight) else { throw ExplorerError("Score inputs exceed the verified domain") }
        guard let cell else { return -1 }
        var matching: [Double] = []
        for pair in assignments(for: cell) {
            for scene in groups[Int(pair.group)].sceneIDs where sceneIDs.contains(scene) { matching.append(weights[Int(pair.weight)]) }
        }
        let raw = matching.sorted(by: >).prefix(maximumMatches).reduce(0, +)
        guard raw > 0 else { return -2 }
        return popularityWeight == 0 ? raw : ((1 - popularityWeight) * min(raw, 5) + popularityWeight * cell.popularity0) / ((1 - popularityWeight) * 5 + popularityWeight)
    }
}

public enum SceneGeographyReader {
    public static func read(_ url: URL, maximum: Int, budget: WorkBudget) throws -> Data {
        try budget.check()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let before = try url.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true, let size = before.fileSize, size > 0, size <= maximum else { throw ExplorerError("Unsupported geography file type or size") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: keys)
        try budget.check()
        guard data.count == size, after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else { throw ExplorerError("Geography file changed during the read") }
        return data
    }
    public static func decompress(_ data: Data) throws -> Data {
        guard data.count <= 8 * 1024 * 1024, data.starts(with: [0x42, 0x5a, 0x68]) else { throw ExplorerError("Unsupported geography compression") }
        let maximum = 32 * 1024 * 1024
        var output = [CChar](repeating: 0, count: maximum + 1), count = UInt32(maximum + 1)
        var input = data.map { CChar(bitPattern: $0) }
        let code = BZ2_bzBuffToBuffDecompress(&output, &count, &input, UInt32(input.count), 0, 0)
        guard code == BZ_OK, count > 0, count <= maximum else { throw ExplorerError("Invalid or oversized geography archive") }
        return output.withUnsafeBytes { Data($0.prefix(Int(count))) }
    }
    public static func load(_ source: GeographySource, budget: WorkBudget) throws -> SceneGeography {
        let bytes = try read(source.url, maximum: source.isCache ? 128 * 1024 * 1024 : 8 * 1024 * 1024, budget: budget)
        if !source.isCache { return try decodeArchive(decompress(bytes), source: source, storedData: bytes, budget: budget) }
        // Companion only supplies verified names: it never contributes a missing cache cell.
        var reference: GeographyHeader?
        if let archive = try? read(GeographySource.installed.url, maximum: 8 * 1024 * 1024, budget: budget),
           let decoded = try? decompress(archive), let text = String(data: decoded, encoding: .utf8) {
            reference = try? GeographyHeader.parse(text, budget: budget)
        }
        return try decodeIndex(bytes, source: source, companion: reference, budget: budget)
    }
    public static func decodeArchive(_ data: Data, source: GeographySource, storedData: Data? = nil, budget: WorkBudget = WorkBudget(seconds: 45)) throws -> SceneGeography {
        guard data.count <= 32 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw ExplorerError("Unsupported geography text") }
        let header = try GeographyHeader.parse(text, budget: budget)
        var builder = GeographyBuilder(header: header)
        var startedCells = false
        for (i, line) in text.split(separator: "\n").enumerated() {
            if i % 1024 == 0 { try budget.check() }
            if line.hasPrefix("p:") {
                startedCells = true
                let fields = line.dropFirst(2).split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 4, let code = GeoHash.code(String(fields[0])), let p1 = Double(fields[1]), let p0 = Double(fields[2]) else { throw ExplorerError("Invalid geography cell") }
                var pairs: [GeographyAssignment] = []
                for field in fields.dropFirst(3) {
                    let pair = field.split(separator: ":", omittingEmptySubsequences: false)
                    guard pair.count == 2, let g = UInt8(pair[0]), let w = UInt8(pair[1]) else { throw ExplorerError("Invalid geography group/weight pair") }
                    pairs.append(.init(group: g, weight: w))
                }
                try builder.append(code: code, p1: p1, p0: p0, pairs: pairs)
            } else if startedCells && !line.hasPrefix("c:") { throw ExplorerError("Geography headers must precede cell records") }
            else if !(line.hasPrefix("v:") || line.hasPrefix("f:") || line.hasPrefix("s:") || line.hasPrefix("c:")) { throw ExplorerError("Unsupported geography source record") }
        }
        return try builder.finish(source: source, data: storedData ?? data, checksum: false, magic: nil, companionMatched: true, budget: budget)
    }
    public static func decodeIndex(_ data: Data, source: GeographySource, budget: WorkBudget = WorkBudget(seconds: 45)) throws -> SceneGeography {
        try decodeIndex(data, source: source, companion: nil, budget: budget)
    }
    private static func decodeIndex(_ data: Data, source: GeographySource, companion: GeographyHeader?, budget: WorkBudget) throws -> SceneGeography {
        guard data.count >= 512, data.count <= 128 * 1024 * 1024 else { throw ExplorerError("Unsupported geography index size") }
        return try data.withUnsafeBytes { raw in
            let b = GeographyIndexBytes(bytes: raw, budget: budget)
            guard try b.integer(0) == 2, try b.integer(0x38) == UInt64(data.count - 8), try b.integer(0x40) == 4 else { throw ExplorerError("Unsupported geography mapped-file header") }
            let magic = try b.find("PFSceneGeography0202"), size = 37
            guard magic <= data.count - size - 8, raw[magic + size - 1] == 0 else { throw ExplorerError("Invalid geography index magic") }
            let checksum = try (b.fnv(0..<magic) ^ b.fnv(magic + size + 8..<data.count)).byteSwapped
            guard checksum == (try b.integer(magic + size)) else { throw ExplorerError("Geography checksum failed; contents remain unavailable") }
            guard try b.integer(b.find("version\0") - 4, width: 4) == 2 else { throw ExplorerError("Unsupported geography index version") }
            let wt = try b.find("floatmap\0") - 32, gt = try b.find("scenes\0") - 32, pt = try b.find("POI\0") - 64
            let wv = try b.vector(wt, width: 8, limit: 256), gv = try b.vector(gt, width: 32, limit: 256)
            var weights: [Double] = [], ids: [[UInt32]] = []
            for i in 0..<wv.count { let w = Double(bitPattern: try b.integer(wv.start + i * 8)); guard w.isFinite, w > 0 else { throw ExplorerError("Invalid geography weight") }; weights.append(w) }
            for i in 0..<gv.count {
                let v = try b.vector(gv.start + i * 32, width: 4, limit: 10_000)
                ids.append(try (0..<v.count).map { UInt32(try b.integer(v.start + $0 * 4, width: 4)) })
            }
            let matched = companion.map { $0.weights == weights && $0.ids == ids } ?? false
            let header = GeographyHeader(weights: weights, names: matched ? companion!.names : ids.indices.map { "Group \($0)" }, ids: ids)
            try header.validate()
            var builder = GeographyBuilder(header: header)
            let buckets = try b.count(pt + 24, limit: 1 << 22), count = try b.count(pt + 32, limit: 1_000_000)
            guard buckets > 0, count > 0, let bucket = try b.pointer(pt + 56), let dummy = try b.pointer(bucket + buckets * 8) else { throw ExplorerError("Invalid geography hash table") }
            var entry = try b.pointer(dummy + 80), seen: Set<Int> = []
            builder.cells.reserveCapacity(count); builder.assignments.reserveCapacity(min(count * 5, 6_000_000))
            while let e = entry {
                if seen.count % 1024 == 0 { try budget.check() }
                guard seen.count < count, seen.insert(e).inserted, try b.integer(e + 8, width: 1) == 13, try b.integer(e + 15, width: 1) == 0,
                      let key = String(bytes: raw[(e + 9)..<(e + 15)], encoding: .ascii), let code = GeoHash.code(key) else { throw ExplorerError("Invalid or cyclic geography key map") }
                let v = try b.vector(e + 48, width: 2, limit: 256)
                let pairs = try (0..<v.count).map { i in GeographyAssignment(group: UInt8(try b.integer(v.start + i * 2, width: 1)), weight: UInt8(try b.integer(v.start + i * 2 + 1, width: 1))) }
                try builder.append(code: code, p1: Double(bitPattern: b.integer(e + 32)), p0: Double(bitPattern: b.integer(e + 40)), pairs: pairs)
                entry = try b.pointer(e + 80)
            }
            guard seen.count == count else { throw ExplorerError("Incomplete geography hash map") }
            let label = String(bytes: raw[magic..<magic + size - 1], encoding: .ascii)
            return try builder.finish(source: source, data: data, checksum: true, magic: label, companionMatched: matched, budget: budget)
        }
    }
}
private struct GeographyHeader {
    let weights: [Double], names: [String], ids: [[UInt32]]
    static func parse(_ text: String, budget: WorkBudget) throws -> Self {
        var weights: [Double] = [], names: [String] = [], ids: [[UInt32]] = [], version: Int?
        for line in text.split(separator: "\n") {
            try budget.check()
            if line.hasPrefix("p:") { break }
            if line.hasPrefix("v:") { guard version == nil, let v = Int(line.dropFirst(2)), v == 2 else { throw ExplorerError("Unsupported geography source version") }; version = v }
            else if line.hasPrefix("f:") { guard let w = Double(line.dropFirst(2)), w.isFinite, w > 0, weights.count < 256 else { throw ExplorerError("Invalid geography weight map") }; weights.append(w) }
            else if line.hasPrefix("s:") {
                let parts = line.dropFirst(2).split(separator: ",", omittingEmptySubsequences: false)
                let values = parts.dropFirst().compactMap { UInt32($0) }
                guard parts.count > 1, !parts[0].isEmpty, values.count == parts.count - 1, names.count < 256 else { throw ExplorerError("Invalid geography scene group") }
                names.append(String(parts[0])); ids.append(values)
            } else if !line.hasPrefix("c:") { throw ExplorerError("Unsupported geography source header") }
        }
        guard version == 2 else { throw ExplorerError("Missing geography source version") }
        let result = Self(weights: weights, names: names, ids: ids); try result.validate(); return result
    }
    func validate() throws {
        guard !weights.isEmpty, weights.count <= 256, !ids.isEmpty, ids.count <= 256, ids.count == names.count,
              ids.allSatisfy({ !$0.isEmpty && $0.count <= 10_000 && !$0.contains(0) && Set($0).count == $0.count }) else { throw ExplorerError("Unsupported geography reference vectors") }
    }
}
private struct GeographyBuilder {
    let header: GeographyHeader
    var cells: [GeographyCell] = [], assignments: [GeographyAssignment] = []
    var counts: [Int]
    init(header: GeographyHeader) { self.header = header; counts = [Int](repeating: 0, count: header.ids.count) }
    mutating func append(code: UInt32, p1: Double, p0: Double, pairs: [GeographyAssignment]) throws {
        guard code < 1 << 30, cells.count < 1_000_000, p1.isFinite, p0.isFinite, (0...1).contains(p1), (0...1).contains(p0), !pairs.isEmpty, pairs.count <= 256,
              assignments.count + pairs.count <= 6_000_000, Set(pairs.map(\.group)).count == pairs.count,
              pairs.allSatisfy({ header.ids.indices.contains(Int($0.group)) && header.weights.indices.contains(Int($0.weight)) }) else { throw ExplorerError("Invalid geography cell or reference") }
        cells.append(.init(code: code, coordinate: GeoHash.bounds(code).center, popularity1: p1, popularity0: p0, assignmentStart: assignments.count, assignmentCount: pairs.count))
        assignments.append(contentsOf: pairs)
        for pair in pairs { counts[Int(pair.group)] += 1 }
    }
    mutating func finish(source: GeographySource, data: Data, checksum: Bool, magic: String?, companionMatched: Bool, budget: WorkBudget) throws -> SceneGeography {
        try budget.check(); cells.sort { $0.code < $1.code }
        guard !cells.isEmpty else { throw ExplorerError("Empty geography atlas") }
        for i in 1..<cells.count where cells[i].code == cells[i - 1].code { throw ExplorerError("Duplicate geography cell") }
        let groups = header.ids.indices.map { GeographyGroup(id: $0, name: header.names[$0].replacingOccurrences(of: "_", with: " "), sceneIDs: header.ids[$0], cellCount: counts[$0]) }
        try budget.check()
        return .init(source: source, cells: cells, groups: groups, weights: header.weights, assignments: assignments, contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), storedBytes: data.count, checksumValid: checksum, magic: magic, companionMatched: companionMatched)
    }
}
private struct GeographyIndexBytes {
    let bytes: UnsafeRawBufferPointer, budget: WorkBudget
    func integer(_ offset: Int, width: Int = 8) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - width else { throw ExplorerError("Geography pointer outside file") }
        if width == 8 { return bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
        if width == 4 { return UInt64(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
        guard width == 1 else { throw ExplorerError("Unsupported geography integer") }; return UInt64(bytes[offset])
    }
    func pointer(_ offset: Int) throws -> Int? {
        let raw = try integer(offset); if raw == 1 { return nil }
        let (result, overflow) = offset.addingReportingOverflow(Int(Int64(bitPattern: raw)))
        guard !overflow, result >= 0, result < bytes.count else { throw ExplorerError("Geography relative pointer outside file") }; return result
    }
    func count(_ offset: Int, limit: Int) throws -> Int { let n = try integer(offset); guard n <= limit else { throw ExplorerError("Geography container limit exceeded") }; return Int(n) }
    func vector(_ offset: Int, width: Int, limit: Int) throws -> (start: Int, count: Int) {
        let n = try count(offset + 16, limit: limit), capacity = try count(offset + 24, limit: max(limit, 6_000_000)), p = try pointer(offset + 8)
        guard n <= capacity, n == 0 || p != nil, (p ?? 0) <= bytes.count - n * width else { throw ExplorerError("Invalid geography vector bounds") }; return (p ?? 0, n)
    }
    func find(_ text: String) throws -> Int {
        let needle = Array(text.utf8)
        // Named objects and magic are in the initial allocator page on this ABI.
        let firstPage = Data(bytes.prefix(min(bytes.count, 65536)))
        guard let range = firstPage.range(of: Data(needle)) else { throw ExplorerError("Missing geography index object: " + text) }; return range.lowerBound
    }
    func fnv(_ range: Range<Int>) throws -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for start in stride(from: range.lowerBound, to: range.upperBound, by: 65536) {
            try budget.check()
            h = atlas_signed_fnv(h, bytes.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), min(65536, range.upperBound - start))
        }
        return h
    }
}
