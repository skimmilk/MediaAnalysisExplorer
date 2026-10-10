import Foundation

/// A static reference recovered from MediaAnalysisTypeDescription in the
/// installed 26A434 dyld image. This does not invoke private framework code.
/// Compatibility with other builds and completed/requested semantics remain
/// unverified. Evidence: research-notes/espresso-runtime-and-metadata-evidence.json.
public enum AnalysisTypeReference {
    public static let build = "26A434"
    public static let labels: [Int: String] = [
        2: "Face",
        3: "Full Face",
        4: "Voice",
        6: "Scene",
        7: "Full Scene",
        8: "Junk",
        9: "Blur",
        10: "Distance",
        11: "Feature",
        12: "Saliency",
        13: "Composition",
        14: "Classification",
        15: "ActivityLevel",
        16: "CurationScore",
        17: "Pets",
        18: "MovieCuration",
        19: "Exposure",
        20: "Effects",
        21: "Audio Classification",
        22: "Human pose",
        23: "Loudness Measure",
        24: "Key Frame",
        25: "Hands",
        26: "Video Stabilization Pixel",
        27: "Song detection",
        28: "Video Stabilization Gyro",
        29: "Video Interpolation",
        30: "Human action",
        31: "Iris Recommendation",
        32: "AX Caption",
        33: "ML Video Attributes",
        34: "Audio Quality",
        35: "Parallax",
        36: "Face Quality",
        37: "PetsPose",
        38: "Settling effect",
        39: "Wallpaper Export",
        40: "Path constraint stabilization",
        41: "Sound Classification",
        42: "Safety",
        43: "Video MUBackbone",
        44: "SMO",
        45: "Video Caption",
        46: "Watch Face",
        47: "Audio Embedding",
        48: "Image MUBackbone",
        49: "Image Caption",
        51: "Video Thumbnail",
        52: "Audio Transcription",
        53: "Rich Image Caption",
        54: "Rich Video Caption",
        55: "Visual Grounding",
        56: "Personal Environment",
        62: "GyroAnalytics"
    ]
    public static func describe(_ mask: UInt64) -> [String: String] {
        let bits = (0..<64).filter { mask & (UInt64(1) << $0) != 0 }
        // The description function gives full face/scene variants precedence.
        let displayed = bits.filter { !($0 == 2 && bits.contains(3)) && !($0 == 6 && bits.contains(7)) }
        let named = displayed.compactMap { bit in labels[bit].map { "\($0) · bit \(bit)" } }
        let unknown = bits.filter { labels[$0] == nil }
        var fields = ["Analysis types": named.isEmpty ? "No named analysis types set" : named.joined(separator: "; "),
                      "Analysis type interpretation": "Names recovered from MediaAnalysisTypeDescription on macOS 27.0.1 (26A434). The mask does not prove detected content or successful completion. Compatibility with other builds remains unverified."]
        fields["Analysis type mask"] = String(format: "0x%llX", mask)
        if !unknown.isEmpty { fields["Unknown analysis type bits"] = unknown.map(String.init).joined(separator: ", ") }
        return fields
    }
}
