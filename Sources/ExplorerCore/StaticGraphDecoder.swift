import Foundation
import Compression
import CryptoKit

public struct DecodedGraphText: Sendable {
    public let text: String
    public let sha256: String
    public let encoding: String
}
public enum StaticGraphDecoder {
    /// Single-block envelopes observed in installed SafetyNetLight and
    /// VisualLookUp's NatureworldModel/ObjectDetectionModel. The header word's
    /// semantics are unknown; only these two verified byte variants are accepted.
    /// Unknown headers, multi-block files and oversized output stay unsupported.
    public static func decode(_ data: Data) throws -> DecodedGraphText {
        guard data.count >= 32, data.count <= 256 * 1024, data.prefix(4) == Data("pbze".utf8) else { throw ExplorerError("Unsupported compressed graph signature or size") }
        let supportedVariant = data[8] == 0x40 || data[8] == 0x01
        guard supportedVariant, data[4..<8].allSatisfy({ $0 == 0 }), data[9..<16].allSatisfy({ $0 == 0 }), data[20..<24].allSatisfy({ $0 == 0 }), Data(data[28..<32]) == Data("bvx2".utf8) else { throw ExplorerError("Unsupported pbze envelope/version; original bytes remain intact") }
        func bigEndian(_ offset: Int) -> Int { data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        let outputBytes = bigEndian(16), inputBytes = bigEndian(24)
        guard outputBytes > 0, outputBytes <= 256 * 1024, inputBytes == data.count - 28 else { throw ExplorerError("Compressed graph lengths exceed limits or do not match the single-block envelope") }
        let output = try decompress(Data(data[28...]), algorithm: COMPRESSION_LZFSE, maximumBytes: outputBytes, exactBytes: outputBytes)
        guard let text = String(data: output, encoding: .utf8), (try? JSONSerialization.jsonObject(with: output)) is [String: Any] else { throw ExplorerError("Decoded graph is not UTF-8 JSON") }
        return DecodedGraphText(text: text, sha256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined(), encoding: "pbze single-block LZFSE · \(data.count) stored / \(output.count) decoded bytes")
    }
    public static func decompress(_ data: Data, algorithm: compression_algorithm, maximumBytes: Int, exactBytes: Int? = nil) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 1024 * 1024, !data.isEmpty, data.count <= 256 * 1024 else { throw ExplorerError("Decompression limit exceeded") }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        let count = bytes.withUnsafeMutableBufferPointer { target in
            data.withUnsafeBytes { source in
                compression_decode_buffer(target.baseAddress!, target.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        guard count > 0, count <= maximumBytes, exactBytes == nil || count == exactBytes else { throw ExplorerError("Compressed data is invalid, truncated, or exceeds the output limit") }
        return Data(bytes.prefix(count))
    }
}
