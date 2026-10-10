import Foundation
import CryptoKit
import CBZip2

public struct SceneConcept: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let sceneID: UInt64
    public let networkID: UInt32
    public let indexed: Bool
    public let thresholds: [String: Double]
    public let parents: [String]
    public let children: [String]
    public let detectors: [String]
    public var isSyntheticRoot: Bool { name == "|_ROOT_|" && sceneID == 0 }
    public var networkName: String {
        switch networkID { case 1: "SceneNet"; case 2: "EntityNet"; case 3: "Content classification"; default: "Network \(networkID)" }
    }
}
public struct TaxonomySource: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let version: Int?
    public let isCache: Bool
    public var title: String { isCache ? url.lastPathComponent : "Installed taxonomy \(version.map(String.init) ?? "unknown")" }
    public init(url: URL, isCache: Bool) {
        self.url = url; self.isCache = isCache
        let name = url.deletingPathExtension().lastPathComponent
        version = name.hasPrefix("PFSceneTaxonomyData_") ? Int(name.dropFirst("PFSceneTaxonomyData_".count)) : nil
    }
    public static func isSceneIndex(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "PFSceneTaxonomyData.index" || (name.hasPrefix("PFSceneTaxonomyData_") && url.pathExtension == "index" && Int(url.deletingPathExtension().lastPathComponent.dropFirst("PFSceneTaxonomyData_".count)) != nil)
    }
}
public struct SceneTaxonomy: Sendable {
    public let source: TaxonomySource
    public let nodes: [String: SceneConcept]
    public let declaredDigest: String
    public let contentSHA256: String
    public let storedBytes: Int
    public let indexVersion: Int?
    public let checksumValid: Bool?
    public let comments: [String]
    public var concepts: [SceneConcept] { nodes.values.filter { !$0.isSyntheticRoot } }
    public var hierarchyEdges: Int { nodes.values.reduce(0) { $0 + $1.children.count } }
    public var detectorLinks: Int { nodes.values.reduce(0) { $0 + $1.detectors.count } }
    public func matching(query: String, network: UInt32? = nil, indexed: Bool? = nil, localization: TaxonomyLocalization? = nil) -> [SceneConcept] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return concepts.filter { node in
            guard network == nil || node.networkID == network, indexed == nil || node.indexed == indexed else { return false }
            return needle.isEmpty || [node.name, String(node.sceneID), localization?.label(node.name) ?? node.name].contains { $0.localizedCaseInsensitiveContains(needle) }
                || (localization?.synonyms(node.name) ?? []).contains { $0.localizedCaseInsensitiveContains(needle) }
        }.sorted {
            let a = localization?.label($0.name) ?? $0.name, b = localization?.label($1.name) ?? $1.name
            return a == b ? $0.name < $1.name : a.localizedStandardCompare(b) == .orderedAscending
        }
    }
    /// Counts semantic differences; synthetic root edges are stripped for source comparisons.
    public func differences(from other: SceneTaxonomy) -> Int {
        let names = Set(nodes.keys).union(other.nodes.keys).subtracting(["|_ROOT_|"])
        return names.filter { name in
            guard let a = nodes[name], let b = other.nodes[name] else { return true }
            return a.sceneID != b.sceneID || a.networkID != b.networkID || a.indexed != b.indexed || a.thresholds != b.thresholds
                || a.parents.filter { $0 != "|_ROOT_|" } != b.parents.filter { $0 != "|_ROOT_|" } || a.children != b.children || a.detectors != b.detectors
        }.count
    }
}
public struct TaxonomyLocalization: Sendable {
    public let locale: String
    public let translations: [String: String]
    public let english: [String: String]
    public let availableLocales: [String]
    public let searchable: [String: Bool]
    public func label(_ name: String) -> String {
        if name == "|_ROOT_|" { return "Taxonomy root · generated" }
        return value(name) ?? name
    }
    public func synonyms(_ name: String) -> [String] { value(name + "-synonyms")?.components(separatedBy: "|") ?? [] }
    public func usesEnglishFallback(_ name: String) -> Bool { translations[name] == nil || translations[name] == "NULL" }
    private func value(_ key: String) -> String? {
        if let value = translations[key], value != "NULL", !value.isEmpty { return value }
        if let value = english[key], value != "NULL", !value.isEmpty { return value }
        return nil
    }
    public init(locale: String, translations: [String: String], english: [String: String], availableLocales: [String], searchable: [String: Bool] = [:]) {
        self.locale = locale; self.translations = translations; self.english = english; self.availableLocales = availableLocales; self.searchable = searchable
    }
}

public enum SceneTaxonomyReader {
    public static let resourceDirectory = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PhotosFormats.framework/Versions/A/Resources")
    public static let thresholdKeys = ["searchThreshold", "precision0Point6Threshold", "highRecallThreshold", "highPrecisionThreshold", "f0Point5Threshold", "f1Threshold", "f2Threshold", "graphHighPrecisionThreshold", "graphHighRecallThreshold"]
    public static let thresholdLabels = ["Search", "Precision 0.6", "High recall", "High precision", "F0.5", "F1", "F2 · copied from high precision", "Graph high precision · minimum", "Graph high recall · minimum"]
    public static func installedSources() throws -> [TaxonomySource] {
        try FileManager.default.contentsOfDirectory(at: resourceDirectory, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "bz2" && $0.lastPathComponent.hasPrefix("PFSceneTaxonomyData_") && TaxonomySource(url: $0, isCache: false).version != nil
        }.map { TaxonomySource(url: $0, isCache: false) }.sorted { ($0.version ?? 0) > ($1.version ?? 0) }
    }
    public static func localization(locale: String = "en", budget: WorkBudget) throws -> TaxonomyLocalization {
        let bytes = try read(resourceDirectory.appendingPathComponent("scenetaxonomy.loctable"), maximum: 16 * 1024 * 1024, budget: budget)
        guard let table = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any], let english = table["en"] as? [String: String] else { throw ExplorerError("Unsupported scene localization format") }
        // Inspect only the container type here; bridging all 44 dictionaries on
        // every locale change needlessly visits hundreds of thousands of strings.
        let locales = table.keys.filter { table[$0] is NSDictionary && $0 != "LocProvenance" }.sorted()
        let searchableURL = URL(fileURLWithPath: AnalysisTaxonomy.sceneDirectory).appendingPathComponent("ENv0b_attribute__isSearchable.bplist")
        let searchable = (try? read(searchableURL, maximum: 4 * 1024 * 1024, budget: budget)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Bool] } ?? [:]
        return TaxonomyLocalization(locale: locale, translations: table[locale] as? [String: String] ?? [:], english: english, availableLocales: locales, searchable: searchable)
    }
    public static func load(_ source: TaxonomySource, budget: WorkBudget) throws -> SceneTaxonomy {
        let data = try read(source.url, maximum: source.isCache ? 16 * 1024 * 1024 : 1024 * 1024, budget: budget)
        return source.isCache ? try decodeIndex(data, source: source, budget: budget) : try decodeArchive(decompress(data), source: source, storedData: data, budget: budget)
    }
    private static func read(_ url: URL, maximum: Int, budget: WorkBudget) throws -> Data {
        try budget.check()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let before = try url.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true, let count = before.fileSize, count > 0, count <= maximum else { throw ExplorerError("Unsupported taxonomy file type or size: " + url.lastPathComponent) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: keys)
        try budget.check()
        guard data.count == count, after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else { throw ExplorerError("Taxonomy file changed while reading; contents discarded") }
        return data
    }
    public static func decompress(_ data: Data, maximum: Int = 4 * 1024 * 1024) throws -> Data {
        guard data.starts(with: [0x42, 0x5a, 0x68]), !data.isEmpty, data.count <= 1024 * 1024, maximum > 0, maximum <= 4 * 1024 * 1024 else { throw ExplorerError("Unsupported taxonomy compression or size") }
        var output = [CChar](repeating: 0, count: maximum + 1), count = UInt32(maximum + 1)
        var input = data.map { CChar(bitPattern: $0) }
        let code = BZ2_bzBuffToBuffDecompress(&output, &count, &input, UInt32(input.count), 0, 0)
        guard code == BZ_OK, count > 0, count <= maximum else { throw ExplorerError("Taxonomy archive is truncated, invalid, or exceeds the decoded limit") }
        return Data(output.prefix(Int(count)).map { UInt8(bitPattern: $0) })
    }
    private static func thresholds(_ values: [Double]) -> [String: Double] {
        var result = Dictionary(uniqueKeysWithValues: zip(thresholdKeys.prefix(6), values))
        result["f2Threshold"] = values[3]
        result["graphHighPrecisionThreshold"] = min(values[0], values[3])
        result["graphHighRecallThreshold"] = min(values[0], values[2], values[3])
        return result
    }
    public static func decodeArchive(_ data: Data, source: TaxonomySource, storedData: Data? = nil, budget: WorkBudget = WorkBudget()) throws -> SceneTaxonomy {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw ExplorerError("Taxonomy source is not bounded UTF-8 text") }
        var raw: [String: (UInt64, UInt32, Bool, [String: Double])] = [:], ids: Set<UInt64> = []
        var edges: [(String, String)] = [], detectorRecords: [String: [String]] = [:], digest: String?, comments: [String] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            if index % 128 == 0 { try budget.check() }
            guard line.count >= 2, line.dropFirst().first == ":" else { throw ExplorerError("Unsupported taxonomy record") }
            let body = String(line.dropFirst(2))
            switch line.first {
            case "s":
                guard digest == nil, body.count == 64, body.allSatisfy(\.isHexDigit) else { throw ExplorerError("Invalid taxonomy digest") }; digest = body
            case "c": comments.append(body)
            case "n":
                let parts = body.components(separatedBy: ",")
                guard parts.count == 10, let id = UInt64(parts[0]), id > 0, let network = UInt32(parts[1]), ["0", "1"].contains(parts[2]), !parts[9].isEmpty, raw[parts[9]] == nil, ids.insert(id).inserted else { throw ExplorerError("Invalid or duplicate taxonomy node") }
                let values = parts[3...8].compactMap(Double.init)
                guard values.count == 6, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }), raw.count < 10_000 else { throw ExplorerError("Unsupported taxonomy thresholds or node limit") }
                raw[parts[9]] = (id, network, parts[2] == "1", thresholds(values))
            case "e":
                let parts = body.components(separatedBy: ","); guard parts.count == 2, edges.count < 50_000 else { throw ExplorerError("Invalid taxonomy edge") }; edges.append((parts[0], parts[1]))
            case "d":
                let parts = body.components(separatedBy: ":"); guard parts.count == 2, detectorRecords[parts[0]] == nil else { throw ExplorerError("Invalid detector record") }
                detectorRecords[parts[0]] = parts[1].components(separatedBy: ",")
            default: throw ExplorerError("Unknown taxonomy record type")
            }
        }
        guard let digest, !raw.isEmpty else { throw ExplorerError("Missing taxonomy digest or nodes") }
        var parents: [String: Set<String>] = [:], children: [String: Set<String>] = [:]
        for (a, b) in edges {
            guard raw[a] != nil, raw[b] != nil, children[a, default: []].insert(b).inserted else { throw ExplorerError("Duplicate or unresolved taxonomy edge") }
            parents[b, default: []].insert(a)
        }
        for (name, targets) in detectorRecords {
            guard raw[name] != nil, targets.allSatisfy({ raw[$0] != nil }), Set(targets).count == targets.count else { throw ExplorerError("Unresolved or duplicate detector link") }
        }
        let result = Dictionary(uniqueKeysWithValues: raw.map { name, value in
            (name, SceneConcept(name: name, sceneID: value.0, networkID: value.1, indexed: value.2, thresholds: value.3, parents: (parents[name] ?? []).sorted(), children: (children[name] ?? []).sorted(), detectors: (detectorRecords[name] ?? []).sorted()))
        })
        try validate(result, budget: budget)
        let stored = storedData ?? data
        return SceneTaxonomy(source: source, nodes: result, declaredDigest: digest, contentSHA256: hash(stored), storedBytes: stored.count, indexVersion: nil, checksumValid: nil, comments: comments)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    fileprivate static func validate(_ nodes: [String: SceneConcept], budget: WorkBudget) throws {
        var degrees = nodes.mapValues { $0.parents.count }, queue = nodes.keys.filter { degrees[$0] == 0 }, index = 0
        for (name, node) in nodes {
            for child in node.children { guard nodes[child]?.parents.contains(name) == true else { throw ExplorerError("Nonreciprocal taxonomy relationship") } }
            for parent in node.parents { guard nodes[parent]?.children.contains(name) == true else { throw ExplorerError("Nonreciprocal taxonomy relationship") } }
            guard node.detectors.allSatisfy({ nodes[$0] != nil }) else { throw ExplorerError("Unresolved taxonomy detector") }
        }
        while index < queue.count {
            if index % 128 == 0 { try budget.check() }
            let name = queue[index]; index += 1
            for child in nodes[name]!.children { degrees[child]! -= 1; if degrees[child] == 0 { queue.append(child) } }
        }
        guard index == nodes.count else { throw ExplorerError("Cyclic taxonomy hierarchy") }
    }
    public static func decodeIndex(_ data: Data, source: TaxonomySource, budget: WorkBudget = WorkBudget()) throws -> SceneTaxonomy {
        var reader = TaxonomyIndexBytes(data: data, budget: budget)
        let (nodes, digest) = try reader.decode()
        try validate(nodes, budget: budget)
        return SceneTaxonomy(source: source, nodes: nodes, declaredDigest: digest, contentSHA256: hash(data), storedBytes: data.count, indexVersion: 6, checksumValid: true, comments: [])
    }
}

/// The observed little-endian, 64-bit Boost ABI only. No archived classes are instantiated.
private struct TaxonomyIndexBytes {
    let bytes: [UInt8]
    let budget: WorkBudget
    init(data: Data, budget: WorkBudget) { bytes = Array(data); self.budget = budget }
    func integer(_ offset: Int, width: Int = 8) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - width else { throw ExplorerError("Taxonomy index pointer is out of bounds") }
        return bytes[offset..<offset + width].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
    func pointer(_ offset: Int) throws -> Int? {
        let raw = try integer(offset); if raw == 1 { return nil }
        let delta = Int64(bitPattern: raw)
        guard let distance = Int(exactly: delta) else { throw ExplorerError("Taxonomy pointer overflow") }
        let (target, overflow) = offset.addingReportingOverflow(distance)
        guard !overflow, target >= 0, target < bytes.count else { throw ExplorerError("Taxonomy pointer is outside this file") }
        return target
    }
    func count(_ offset: Int, limit: Int = 10_000) throws -> Int {
        let value = try integer(offset)
        guard value <= limit else { throw ExplorerError("Taxonomy container exceeds the supported limit") }; return Int(value)
    }
    func string(_ offset: Int) throws -> String {
        let flag = try integer(offset + 8, width: 1), size: Int, start: Int
        if flag & 1 != 0 { size = Int(flag >> 1); start = offset + 9; guard size <= 22 else { throw ExplorerError("Invalid short taxonomy string") } }
        else {
            size = try count(offset + 16, limit: 1024)
            guard let pointer = try pointer(offset + 24) else { throw ExplorerError("Null taxonomy string") }; start = pointer
        }
        guard size > 0, start <= bytes.count - size - 1, bytes[start + size] == 0, let result = String(bytes: bytes[start..<start + size], encoding: .utf8) else { throw ExplorerError("Invalid taxonomy name string") }
        return result
    }
    func entries(_ table: Int, size: Int, valueSize: Int) throws -> [Int] {
        guard size > 0 else { return [] }
        let bucketCount = try count(table + 0x18, limit: 32768)
        guard bucketCount > 0, let buckets = try pointer(table + 0x38), let dummy = try pointer(buckets + bucketCount * 8) else { throw ExplorerError("Invalid taxonomy hash buckets") }
        var entry = try pointer(dummy + valueSize), seen: Set<Int> = [], output: [Int] = []
        while let value = entry {
            if output.count % 128 == 0 { try budget.check() }
            guard output.count < size, seen.insert(value).inserted else { throw ExplorerError("Cyclic or oversized taxonomy hash chain") }
            output.append(value); entry = try pointer(value + valueSize)
        }
        guard output.count == size else { throw ExplorerError("Taxonomy container count mismatch") }; return output
    }
    func members(_ table: Int, names: [Int: String]) throws -> [String] {
        let entries = try entries(table, size: count(table + 0x20), valueSize: 8)
        let result = try entries.map { entry in
            guard let target = try pointer(entry), let name = names[target] else { throw ExplorerError("Unresolved taxonomy index relationship") }; return name
        }
        guard Set(result).count == result.count else { throw ExplorerError("Duplicate taxonomy index relationship") }; return result.sorted()
    }
    func find(_ text: String) throws -> Int {
        let needle = Array(text.utf8)
        guard let range = Data(bytes).range(of: Data(needle)) else { throw ExplorerError("Missing taxonomy index region: " + text) }; return range.lowerBound
    }
    func fnv(_ range: Range<Int>) throws -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for index in range {
            if index % 16384 == 0 { try budget.check() }
            value = (value ^ UInt64(bitPattern: Int64(Int8(bitPattern: bytes[index])))) &* 0x100000001b3
        }; return value
    }
    mutating func decode() throws -> ([String: SceneConcept], String) {
        guard bytes.count >= 256, bytes.count <= 16 * 1024 * 1024, try integer(0) == 2, try integer(0x38) == UInt64(bytes.count - 8) else { throw ExplorerError("Unsupported taxonomy mapped-file header") }
        let magic = try find("PFSceneTaxonomy")
        guard magic <= bytes.count - 44, bytes[magic + 35] == 0 else { throw ExplorerError("Unsupported taxonomy magic") }
        let checksum = try (fnv(0..<magic) ^ fnv(magic + 44..<bytes.count)).byteSwapped
        guard checksum == (try integer(magic + 36)) else { throw ExplorerError("Taxonomy index checksum failed; file remains opaque") }
        let versionTag = try find("version\0")
        guard try integer(versionTag - 4, width: 4) == 6 else { throw ExplorerError("Unsupported taxonomy index version; this reader supports version 6") }
        let nameTable = try find("names\0") - 64, sceneTable = try find("scenes\0") - 64
        let nameEntries = try entries(nameTable, size: count(nameTable + 0x20), valueSize: 0x130)
        var names: [Int: String] = [:], usedNames: Set<String> = []
        for entry in nameEntries {
            let name = try string(entry)
            guard usedNames.insert(name).inserted, try pointer(entry + 0x20 + 0x48) == entry else { throw ExplorerError("Duplicate or invalid taxonomy name map") }
            names[entry + 0x20] = name
        }
        let memoryKeys = ["searchThreshold", "highPrecisionThreshold", "highRecallThreshold", "precision0Point6Threshold", "f0Point5Threshold", "f1Threshold", "f2Threshold"]
        var nodes: [String: SceneConcept] = [:], ids: [UInt64: Int] = [:], totalLinks = 0
        for (offset, name) in names {
            try budget.check()
            let id = try integer(offset), network = UInt32(try integer(offset + 8, width: 4)), flag = try integer(offset + 12, width: 1)
            guard flag <= 1 else { throw ExplorerError("Invalid taxonomy indexed flag") }
            var thresholds: [String: Double] = [:]
            for (i, key) in memoryKeys.enumerated() {
                let value = Double(bitPattern: try integer(offset + 0x10 + i * 8))
                guard value.isFinite, (0...1).contains(value) else { throw ExplorerError("Invalid taxonomy index threshold") }; thresholds[key] = value
            }
            thresholds["graphHighPrecisionThreshold"] = min(thresholds["searchThreshold"]!, thresholds["highPrecisionThreshold"]!)
            thresholds["graphHighRecallThreshold"] = min(thresholds["searchThreshold"]!, thresholds["highPrecisionThreshold"]!, thresholds["highRecallThreshold"]!)
            guard id == 0 || ids.updateValue(offset, forKey: id) == nil else { throw ExplorerError("Duplicate taxonomy scene ID") }
            let parents = try members(offset + 0x50, names: names), children = try members(offset + 0x90, names: names), detectors = try members(offset + 0xd0, names: names)
            totalLinks += parents.count + children.count + detectors.count
            guard totalLinks <= 100_000 else { throw ExplorerError("Taxonomy relationship limit exceeded") }
            nodes[name] = SceneConcept(name: name, sceneID: id, networkID: network, indexed: flag == 1, thresholds: thresholds, parents: parents, children: children, detectors: detectors)
        }
        let sceneEntries = try entries(sceneTable, size: count(sceneTable + 0x20), valueSize: 16)
        var mappedIDs: Set<UInt64> = []
        for entry in sceneEntries {
            let id = try integer(entry)
            guard mappedIDs.insert(id).inserted, ids[id] == (try pointer(entry + 8)) else { throw ExplorerError("Taxonomy scene map mismatch") }
        }
        guard mappedIDs.count == ids.count, nodes["|_ROOT_|"]?.sceneID == 0, nodes.values.filter({ $0.sceneID == 0 }).count == 1 else { throw ExplorerError("Missing taxonomy root or scene IDs") }
        let digestTag = try find("digest\0"), start = digestTag + 16
        guard start <= bytes.count - 64, let digest = String(bytes: bytes[start..<start + 64], encoding: .utf8), digest.allSatisfy(\.isHexDigit) else { throw ExplorerError("Invalid taxonomy index digest") }
        return (nodes, digest)
    }
}
