import Foundation
import CoreGraphics

public struct PayloadRectangle: Sendable {
    public let title: String
    public let rectangle: CGRect
    public let fields: [String: String]
}

public struct ActionProbability: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let score: Double
    public var percentage: String { String(format: "%.1f%%", score * 100) }
    public var displayText: String { name + " " + percentage }
}

public struct DecodedPayload: Sendable {
    public let summary: String
    public let fields: [String: String]
    public let rectangles: [PayloadRectangle]
    public let vector: [Double]
    public let referenceValues: [String]
    public let actionProbabilities: [ActionProbability]
    public let imageFeatures: ImageFeatureDescriptor?
    public init(summary: String, fields: [String: String], rectangles: [PayloadRectangle], vector: [Double] = [], referenceValues: [String] = [], actionProbabilities: [ActionProbability] = [], imageFeatures: ImageFeatureDescriptor? = nil) {
        self.summary = summary; self.fields = fields; self.rectangles = rectangles; self.vector = vector; self.referenceValues = referenceValues; self.actionProbabilities = actionProbabilities; self.imageFeatures = imageFeatures
    }
}

/// Labels come from explicit identifier attributes, never vocabulary offsets.
public struct AnalysisTaxonomy: Sendable {
    public let scenes: [Int: String]
    public let actions: [Int: String]
    public static let sceneDirectory = "/System/Library/PrivateFrameworks/CoreSceneUnderstanding.framework/Versions/A/Resources/taxonomies/EntityNet/v0b"
    public static let actionPath = "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/Resources/action_taxonomy.plist"
    public static let installed = load()

    public init(identifiers: [String: Int], labels: [String: String], actions: [String]) {
        // Ambiguous duplicate identifiers are deliberately not resolved.
        let groups = Dictionary(grouping: identifiers.keys, by: { identifiers[$0]! })
        scenes = groups.compactMapValues { names in
            guard names.count == 1, let name = names.first else { return nil }
            return labels[name] ?? name
        }
        self.actions = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($0.offset, $0.element) })
    }
    private static func load() -> Self {
        func plist(_ path: String) -> Any? {
            guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        let ids = plist(sceneDirectory + "/ENv0b_attribute__identifier.bplist") as? [String: Int] ?? [:]
        let labels = plist(sceneDirectory + "/ENv0b_attribute__humanReadableLabel.bplist") as? [String: String] ?? [:]
        let actions = (plist(actionPath) as? [Data] ?? []).map { String(decoding: $0, as: UTF8.self) }
        return Self(identifiers: ids, labels: labels, actions: actions)
    }
}

public enum AnalysisPayload {
    public static let columns: Set<String> = ["ZOBJECTBOUNDS", "ZFACERESULTS", "ZKEYPOINTS", "ZACTIONSCONFIDENCE", "ZSENSITIVITYSCENERESULTS", "ZEMBEDDINGIDS", "ZREPRESENTATIVEMAPPING", "ZTHUMBNAILIDS", "ZFACEPRINT", "ZTORSOPRINT", "ZFEATUREVECTOR", "ZCOLORNORMALIZATIONDATA", "ZEMBEDDINGDATA"]

    public static func decode(_ data: Data, column: String, table: String, taxonomy: AnalysisTaxonomy = .installed) -> DecodedPayload? {
        guard columns.contains(column), data.count <= 64 * 1024 else { return nil }
        if let descriptor = DescriptorPayload.decode(data, column: column, table: table) { return descriptor }
        if column == "ZEMBEDDINGDATA" {
            guard ["ZVIDEOEMBEDDINGRESULT", "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT"].contains(table), data.count == 1024 else { return nil }
            let bytes = Array(data)
            let values = stride(from: 0, to: bytes.count, by: 2).map { Double(Float16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) }
            guard values.allSatisfy(\.isFinite) else { return nil }
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            guard (0.9...1.1).contains(norm) else { return nil }
            return DecodedPayload(summary: "Candidate embedding layout · 512 little-endian Float16 values",
                                  fields: ["Components": "512", "L2 norm": String(format: "%.6f", norm), "Range": String(format: "%.6f … %.6f", values.min()!, values.max()!),
                                           "Format": "candidate-\(table)-f16-512-v10", "Interpretation": "Consistent with a unit-normalized vector in the captured version-10 rows; layout inferred, semantic dimensions unknown."], rectangles: [], vector: values)
        }
        guard let value = try? ArchiveValues.read(data) else { return nil }
        var fields: [String: String] = [:]; var rectangles: [PayloadRectangle] = []; var vector: [Double] = []; var references: [String] = []
        let actionProbabilities: [ActionProbability] = []
        var summary = "Decoded property-list values · archived classes are not instantiated"
        switch column {
        case "ZKEYPOINTS":
            fields["Archived values"] = text(value)
            fields["Interpretation"] = "Schema declares an optional secure-unarchive transformable. Values are resolved only as data; geometry layout remains unverified. No joint coordinates or skeleton are inferred from arbitrary fields."
            summary = "Stored pose keypoint archive · layout unverified"
        case "ZACTIONSCONFIDENCE", "ZSENSITIVITYSCENERESULTS":
            guard let scores = value as? [String: Any] else { return nil }
            return scorePayload(scores, column: column, taxonomy: taxonomy)
        case "ZOBJECTBOUNDS":
            guard let bounds = value as? [String] else { return nil }
            fields["Bounds"] = text(bounds)
            rectangles = bounds.enumerated().compactMap { index, bound in
                rectangle(bound).map { PayloadRectangle(title: "Moving object", rectangle: $0, fields: ["Decoded bounds": bound, "Bounds index": String(index)]) }
            }
            summary = "Moving-object bounds · \(bounds.count) archived rectangles"
        case "ZFACERESULTS":
            guard let faces = value as? [[String: Any]] else { return nil }
            for (index, face) in faces.enumerated() {
                fields["Face \(index + 1)"] = text(face)
                if let attributes = face["attributes"] as? [String: Any], let bound = attributes["faceBounds"] as? String, let rect = rectangle(bound) {
                    rectangles.append(PayloadRectangle(title: "Keyframe face", rectangle: rect, fields: attributes.mapValues(text)))
                }
            }
            summary = "Keyframe face attributes · \(faces.count) archived entries"
        case "ZFACEPRINT", "ZTORSOPRINT":
            guard let printFields = value as? [String: Any] else { return nil }
            fields = printFields.mapValues(text)
            summary = column == "ZFACEPRINT" ? "Archived face descriptor" : "Archived torso descriptor"
            if let data = printFields["descriptorData"] as? Data, printFields["elementCount"] as? Int == 128,
               printFields["descriptorByteLength"] as? Int == 512, printFields["elementsType"] as? Int == 1,
               let values = DescriptorPayload.float32(data, count: 128) {
                vector = values; fields.merge(DescriptorPayload.statistics(values)) { _, new in new }
                fields["descriptorData"] = "512 raw bytes · interpreted in the component view"
                let request = printFields["request"] as? [String: Any]
                fields["Format"] = "\(column)-archive-f32-128-v\(printFields["version"] ?? "unknown")-algorithm\(printFields["algorithmVersion"] ?? "unknown")-request\(request?["code"] ?? "unknown")/\(request?["rev"] ?? "unknown")"
                fields["Interpretation"] = "Archived element count/type and byte length support Float32 components. Individual dimensions have no decoded semantic labels; descriptor similarity does not establish identity."
            }
        default:
            fields["Values"] = text(value)
            if let array = value as? [Any] {
                fields["Entries"] = String(array.count)
                references = array.compactMap { element in
                    if let string = element as? String { return string }
                    if let number = element as? NSNumber { return number.stringValue }
                    return nil
                }
            }
        }
        return DecodedPayload(summary: summary, fields: fields, rectangles: rectangles, vector: vector, referenceValues: references, actionProbabilities: actionProbabilities)
    }

    /// Native score dictionaries and archived Photos scores use the same
    /// label mapping, formatting and interpretation; no synthetic archive needed.
    public static func decodeScores(_ scores: [String: Double], column: String, taxonomy: AnalysisTaxonomy = .installed) -> DecodedPayload? {
        guard ["ZACTIONSCONFIDENCE", "ZSENSITIVITYSCENERESULTS"].contains(column),
              !scores.isEmpty, scores.count <= 1024, scores.values.allSatisfy(\.isFinite) else { return nil }
        return scorePayload(scores.mapValues { $0 as Any }, column: column, taxonomy: taxonomy)
    }
    private static func scorePayload(_ scores: [String: Any], column: String, taxonomy: AnalysisTaxonomy) -> DecodedPayload {
        var fields: [String: String] = [:]
        var actionProbabilities: [ActionProbability] = []
        var summary = ""
        for (id, score) in scores where !id.hasPrefix("$") {
            let name = Int(id).flatMap { column == "ZACTIONSCONFIDENCE" ? taxonomy.actions[$0] : SensitivityLabels.name(for: $0) }
            fields[name.map { "\($0.replacingOccurrences(of: "_", with: " ")) · ID \(id)" } ?? "ID \(id) (unresolved)"] = text(score)
            if column == "ZACTIONSCONFIDENCE", let number = score as? NSNumber,
               number.doubleValue.isFinite, (0...1).contains(number.doubleValue) {
                actionProbabilities.append(ActionProbability(id: id, name: name?.replacingOccurrences(of: "_", with: " ") ?? "Action \(id)", score: number.doubleValue))
            }
        }
        actionProbabilities.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if let a = Int($0.id), let b = Int($1.id), a != b { return a < b }
            return $0.id < $1.id
        }
        fields["Label evidence"] = column == "ZACTIONSCONFIDENCE" ? "Installed action_taxonomy.plist array index; database/model revision compatibility unverified." : SensitivityLabels.evidence
        if column == "ZSENSITIVITYSCENERESULTS" { fields["Score interpretation"] = SensitivityLabels.scoreInterpretation }
        summary = column == "ZACTIONSCONFIDENCE" ? "Action scores · \(scores.count) entries" : "Sensitivity scores · \(scores.count) entries"
        return DecodedPayload(summary: summary, fields: fields, rectangles: [], actionProbabilities: actionProbabilities)
    }

    static func rectangle(_ string: String) -> CGRect? {
        // Parse the actual archived {{x,y},{width,height}} string, without treating
        // arbitrary numbers/byte offsets as image coordinates.
        let pattern = #"^\s*\{\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\},\s*\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\}\}\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        let s = string as NSString
        let v = (1...4).compactMap { Double(s.substring(with: match.range(at: $0))) }
        guard v.count == 4, v.allSatisfy(\.isFinite), v[0] >= 0, v[1] >= 0, v[2] > 0, v[3] > 0, v[0] + v[2] <= 1.00001, v[1] + v[3] <= 1.00001 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    private static func text(_ value: Any) -> String {
        func jsonValue(_ value: Any) -> Any {
            if let data = value as? Data { return "Binary data · \(data.count) bytes (opaque)" }
            if let dict = value as? [String: Any] { return dict.mapValues(jsonValue) }
            if let array = value as? [Any] { return array.map(jsonValue) }
            return value
        }
        let normalized = jsonValue(value)
        if let string = normalized as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed]) else { return "Unsupported property-list value" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Resolve reference values as dictionaries/arrays/scalars. Never invoke
/// NSKeyedUnarchiver, load private archive classes, or execute a model.
enum ArchiveValues {
    static func read(_ data: Data) throws -> Any {
        guard data.count <= 64 * 1024 else { throw ExplorerError("Payload too large") }
        let original = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let archive = original as? [String: Any], archive["$archiver"] as? String == "NSKeyedArchiver" else { return original }
        // Foundation's XML representation exposes opaque binary UID objects as
        // CF$UID dictionaries. Rename that reserved key before reparsing so the
        // references remain ordinary data instead of becoming UID objects again.
        let xml = try PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0)
        guard xml.count <= 2 * 1024 * 1024 else { throw ExplorerError("Expanded archive too large") }
        let normalized = String(decoding: xml, as: UTF8.self).replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>__ExplorerUID__</key>")
        guard let root = try PropertyListSerialization.propertyList(from: Data(normalized.utf8), format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any], objects.count <= 20_000,
              let top = root["$top"] as? [String: Any], let entry = top["root"] ?? (top.count == 1 ? top.values.first : nil) else { throw ExplorerError("Unsupported archive structure") }
        var visited = 0
        func reference(_ value: Any) -> Int? {
            guard let d = value as? [String: Any], d.count == 1 else { return nil }
            return d["__ExplorerUID__"] as? Int
        }
        func resolve(_ value: Any, depth: Int = 0, stack: Set<Int> = []) throws -> Any {
            visited += 1
            guard depth < 32, visited <= 20_000 else { throw ExplorerError("Archive complexity limit") }
            if let index = reference(value) {
                guard objects.indices.contains(index), !stack.contains(index) else { throw ExplorerError("Invalid or cyclic archive reference") }
                if index == 0, objects[index] as? String == "$null" { return NSNull() }
                return try resolve(objects[index], depth: depth + 1, stack: stack.union([index]))
            }
            if let array = value as? [Any] { return try array.map { try resolve($0, depth: depth + 1, stack: stack) } }
            if let d = value as? [String: Any] {
                if let keys = d["NS.keys"] as? [Any], let values = d["NS.objects"] as? [Any] {
                    guard keys.count == values.count else { throw ExplorerError("Archive dictionary mismatch") }
                    var result: [String: Any] = [:]
                    for (key, value) in zip(keys, values) {
                        guard let key = try resolve(key, depth: depth + 1, stack: stack) as? String, result[key] == nil else { throw ExplorerError("Invalid archived dictionary key") }
                        result[key] = try resolve(value, depth: depth + 1, stack: stack)
                    }
                    return result
                }
                if let values = d["NS.objects"] as? [Any] { return try resolve(values, depth: depth + 1, stack: stack) }
                var result: [String: Any] = [:]
                for (key, value) in d where key != "$class" { result[key] = try resolve(value, depth: depth + 1, stack: stack) }
                if let c = d["$class"], let index = reference(c), objects.indices.contains(index), let type = objects[index] as? [String: Any], let name = type["$classname"] as? String { result["$archiveClass"] = name }
                return result
            }
            return value
        }
        return try resolve(entry)
    }
}
