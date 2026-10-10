import Foundation

public struct CaptionToken: Identifiable, Sendable {
    public let id: Int
    public let word: String
}
public enum CaptionVocabulary {
    public static let path = "/System/Library/PrivateFrameworks/CoreSceneUnderstanding.framework/Versions/A/Resources/video_captioning/VideoCaptioning_v8.0.0_fxfs4chdvb-21620/VideoCaptioning_v8.0.0_fxfs4chdvb-21620.reverse_vocab.json"
    public static let installed: [CaptionToken] = {
        guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [] }
        return object.compactMap { key, word in Int(key).map { CaptionToken(id: $0, word: word) } }.sorted { $0.id < $1.id }
    }()
    public static func matches(_ query: String, tokens: [CaptionToken] = installed) -> [CaptionToken] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 80 else { return [] }
        if let id = Int(query) { return Array(tokens.filter { $0.id == id }.prefix(1)) }
        return Array(tokens.filter { $0.word.localizedCaseInsensitiveContains(query) }.prefix(50))
    }
}
