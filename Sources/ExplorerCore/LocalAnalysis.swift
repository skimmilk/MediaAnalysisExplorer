import Foundation
import CoreGraphics

/// Explicit, empirically supported requests. Adding a pass does not require a new
/// screen; adding a presentation adapter does not change execution or raw evidence.
public struct LocalAnalysisPass: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: String
    public let mask: UInt64
    public let seconds: Int
    public static let verifiedBuild = "26A434"
    private init(_ id: String, _ title: String, _ kind: String, _ bits: [Int], seconds: Int = 180) {
        self.id = id; self.title = title; self.kind = kind
        mask = bits.reduce(0) { $0 | (UInt64(1) << $1) }; self.seconds = seconds
    }
    public static func passes(video: Bool) -> [Self] {
        if video {
            return [
                Self("video-features", "Video & audio features", "movie", [3,7,11,12,14,21,22,23,30,34]),
                Self("video-caption", "Captions & embeddings", "movie", [43,45,47]),
                Self("video-curation", "Highlights & curation", "movie", [15,16,18]),
                Self("video-attributes", "Motion & quality", "movie", [33])
            ]
        }
        return [
            Self("image-features", "Detections & image features", "image", [3,8,9,11,12,13,17,19,22,25,37]),
            Self("image-preanalysis", "Scenes & aesthetics", "preanalysis", []),
            Self("image-caption", "Caption & embeddings", "image", [48,49])
        ]
    }
}

/// The worker serializes Foundation values without unarchiving or executing
/// returned objects. Arrays retain their original count and truncation marker.
public indirect enum AnalysisValue: Sendable, Equatable, Codable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case object([String: AnalysisValue]), array([AnalysisValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> Self { object[key] ?? .null }
    public var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    public var items: [Self] {
        if case .array(let v) = self { return v }
        if case .array(let v) = self["items"] { return v }
        return []
    }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
    public var double: Double? {
        switch self { case .integer(let v): Double(v); case .number(let v): v; default: nil }
    }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }
    public var isTrue: Bool { self == .bool(true) || self == .integer(1) }
    public var isTruncated: Bool {
        self["truncated"].isTrue || self["__truncated"].isTrue
    }
    public var summary: String {
        switch self {
        case .null: "Unavailable"
        case .bool(let v): v ? "Yes" : "No"
        case .integer(let v): String(v)
        case .number(let v): String(format: "%.6g", v)
        case .string(let v): v
        case .array(let v): "\(v.count) items"
        case .object(let v):
            if self["class"].text == "NSData" { "\(self["bytes"].summary) bytes" }
            else if let count = self["count"].integer { "\(count) items" + (isTruncated ? " · truncated" : "") }
            else if self["class"].text == "NSValue", let value = self["value"].text { value }
            else { "\(v.count) fields" + (isTruncated ? " · truncated" : "") }
        }
    }
    /// CMTime dictionary emitted by the framework. Invalid, indefinite and
    /// infinite flags must never become a misleading seek position.
    public var seconds: Double? {
        guard let value = self["value"].double, let scale = self["timescale"].double, scale > 0,
              let flags = self["flags"].integer, flags & 1 != 0, flags & 28 == 0,
              (self["epoch"].integer ?? 0) == 0 else { return nil }
        let result = value / scale
        return result.isFinite ? result : nil
    }
    public var normalizedRectangle: CGRect? {
        let description = text ?? (self["class"].text == "NSValue" ? self["value"].text : nil)
        guard let description, description.count < 512 else { return nil }
        let pattern = #"^\s*\{\{\s*([-+\d.eE]+)\s*,\s*([-+\d.eE]+)\s*\},\s*\{\s*([-+\d.eE]+)\s*,\s*([-+\d.eE]+)\s*\}\}\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)) else { return nil }
        let values = (1...4).compactMap { Range(match.range(at: $0), in: description).flatMap { Double(description[$0]) } }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[0] >= 0, values[1] >= 0,
              values[2] > 0, values[3] > 0, values[0] + values[2] <= 1.00001, values[1] + values[3] <= 1.00001 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

public struct LocalAnalysisFamily: Identifiable, Sendable {
    public let passID: String
    public let name: String
    public let evidence: AnalysisValue
    public var id: String { passID + ":" + name }
    public var rows: [AnalysisValue] { evidence.items }
    public var count: Int { Int(evidence["count"].integer ?? Int64(rows.count)) }

}

public struct LocalAnalysisReport: Identifiable, Sendable {
    public let pass: LocalAnalysisPass
    public let raw: AnalysisValue
    public var id: String { pass.id }
    public init(pass: LocalAnalysisPass, raw: AnalysisValue) { self.pass = pass; self.raw = raw }
    public var succeeded: Bool {
        raw["status"].integer == 0 && raw["unavailableReason"].isNull && raw["completionError"].isNull && raw["completionReceived"].isTrue
    }
    public var failure: String? {
        if succeeded { return nil }
        return raw["unavailableReason"].text ?? raw["completionError"]["description"].text ?? "Analysis did not finish successfully (status \(raw["status"].summary)). Available partial results are shown."
    }
    public var analysis: AnalysisValue { raw["completedAnalysis"].isNull ? raw["partialAnalysis"] : raw["completedAnalysis"] }
    public var families: [LocalAnalysisFamily] {
        let root = pass.kind == "preanalysis" ? analysis : analysis["metadataRanges"]
        return root.object.keys.filter { !$0.hasPrefix("__") }.sorted().map { LocalAnalysisFamily(passID: pass.id, name: $0, evidence: root[$0]) }
    }
    public static func decodeEvent(_ data: Data) throws -> AnalysisValue {
        guard data.count <= 16 * 1024 * 1024 else { throw ExplorerError("Analysis output exceeded the limit.") }
        let value = try JSONDecoder().decode(AnalysisValue.self, from: data)
        guard ["progress", "result"].contains(value["event"].text) else { throw ExplorerError("Unrecognized worker event.") }
        return value
    }
}
