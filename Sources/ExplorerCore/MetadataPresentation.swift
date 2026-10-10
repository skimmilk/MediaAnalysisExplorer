import Foundation

/// Presentation only: source values and decoder evidence remain intact.
/// Explicit keys keep arbitrary caption text and unknown stored fields as data.
public struct MetadataPresentation: Sendable {
    public let values: [String: String]
    public let notes: [String: String]
    public init(fields: [String: String]) {
        var values = fields, notes: [String: String] = [:]
        let documentation: Set<String> = [
            "Face flag evidence", "Position evidence", "Face reference scope", "Pose group evidence",
            "Motion flag interpretation", "Statistics flag evidence", "Version interpretation",
            "Audio-level evidence", "Safety category limitation", "Sensitivity label evidence",
            "Sensitivity score interpretation", "Score interpretation", "Orientation limitation",
            "Summary reference interpretation", "Action label evidence", "Analysis type interpretation",
            "Interpretation", "Evidence", "Label evidence", "Schema interpretation", "Shot type evidence"
        ]
        for key in documentation where fields[key] != nil {
            notes[key] = values.removeValue(forKey: key)
        }
        func compact(_ key: String, _ value: String) {
            guard let full = fields[key] else { return }
            values[key] = value; notes[key] = full
        }
        if let full = fields["Pose flag structure"], let nibble = full.components(separatedBy: "nibble ").last?.components(separatedBy: ".").first {
            compact("Pose flag structure", "Group mask: " + nibble)
        }
        if let full = fields["Supported pose groups"] {
            let bits = full.components(separatedBy: "; ").compactMap { $0.hasPrefix("bit ") ? $0.components(separatedBy: ":").first : nil }
            compact("Supported pose groups", bits.isEmpty ? "None" : bits.joined(separator: ", "))
        }
        if fields["Pose geometry"] != nil { compact("Pose geometry", "Keypoints not stored") }
        if let full = fields["Yaw interpretation"] { compact("Yaw interpretation", full.components(separatedBy: ".").first ?? full) }
        for key in fields.keys where key.hasSuffix(" · reference-date interpretation") {
            compact(key, fields[key]!.components(separatedBy: " · ").first!)
        }
        for key in ["Packed revision / header score", "Request marker", "Schema cache format", "descriptorData"] {
            if let full = fields[key] { compact(key, full.components(separatedBy: " · ").first!.components(separatedBy: ";").first!) }
        }
        self.values = values; self.notes = notes
    }
}
