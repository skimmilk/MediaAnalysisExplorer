import Foundation
import CryptoKit

/// Only captured layouts corroborated by serializer evidence are accepted.
/// ColorGabor image features and learned torso vectors have separate layouts.
public enum DescriptorPayload {
    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = Array(data[offset..<offset + 4])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
    static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32(data, offset)) | UInt64(uint32(data, offset + 4)) << 32
    }
    public static func float32(_ data: Data, count: Int) -> [Double]? {
        guard count > 0, count <= 16384, data.count == count * 4 else { return nil }
        let values = stride(from: 0, to: data.count, by: 4).map { Double(Float(bitPattern: uint32(data, $0))) }
        return values.allSatisfy(\.isFinite) ? values : nil
    }
    public static func statistics(_ vector: [Double]) -> [String: String] {
        guard !vector.isEmpty else { return [:] }
        return ["Components": String(vector.count), "L2 norm": String(format: "%.9f", sqrt(vector.reduce(0) { $0 + $1 * $1 })),
                "Range": String(format: "%.6f … %.6f", vector.min()!, vector.max()!)]
    }
    public static func cosine(_ a: DecodedPayload, _ b: DecodedPayload) -> Double? {
        guard let format = a.fields["Format"], format == b.fields["Format"], !a.vector.isEmpty, a.vector.count == b.vector.count else { return nil }
        let aa = a.vector.reduce(0) { $0 + $1 * $1 }, bb = b.vector.reduce(0) { $0 + $1 * $1 }
        guard aa > 0, bb > 0, aa.isFinite, bb.isFinite else { return nil }
        return max(-1, min(1, zip(a.vector, b.vector).reduce(0) { $0 + $1.0 * $1.1 } / sqrt(aa * bb)))
    }
    public static func decode(_ data: Data, column: String, table: String) -> DecodedPayload? {
        if column == "ZCOLORNORMALIZATIONDATA", table == "ZMOVIEHIGHLIGHTRESULT", data.count == 12 {
            var fields = ["Bytes": data.map { String(format: "%02X", $0) }.joined(separator: " ")]
            guard data[0] == 2, data[1] == 0x80, data[11] == 0 else {
                fields["Interpretation"] = "Unrecognized normalization header/reserved byte; no color transform or parameter interpretation is applied."
                return DecodedPayload(summary: "Color-normalization block · unsupported layout", fields: fields, rectangles: [])
            }
            let parameters: [(String, Double, Double)] = [("WhiteBalanceTempTintCI[0]", 4200, 6200), ("WhiteBalanceTempTintCI[1]", -20, 20),
                ("ContrastCI[0]", -0.15, 0.4), ("ExposureAndBlackPointCI[1]", -0.01, 0.01), ("ExposureAndBlackPointCI[0]", -0.01, 0.01),
                ("HighlightsCI[0]", -0.4, 0.02), ("HighKeyCI[0]", -0.2, 1.3), ("VibrancyCI[0]", -0.075, 0.15), ("ColorCastCI[0]", -0.1, 0.3)]
            for (index, parameter) in parameters.enumerated() {
                fields["Approximate " + parameter.0] = String(format: "%.6f", parameter.1 + Double(data[index + 2]) / 255 * (parameter.2 - parameter.1))
            }
            fields["Format header"] = "0x8002"
            fields["Packed revision / header score"] = "2 / 128 · header score is not a recovered classifier confidence"
            fields["Quantization uncertainty"] = parameters.map { $0.0 + ": ±" + String(format: "%.6f", ($0.2 - $0.1) / 510) }.joined(separator: "; ")
            fields["Interpretation"] = "Installed PhotosFormats packer on 26A434 maps adjustment dictionary values to clamped 8-bit ranges. Values reconstructed here are approximate after quantization; units/reader scaling remain explicit. These settings are not applied to the original preview."
            return DecodedPayload(summary: "Color-normalization adjustments · reconstructed parameters", fields: fields, rectangles: [])
        }
        let torso = column == "ZTORSOPRINT" && table == "ZHUMANACTIONCLASSIFICATIONRESULT" && data.count == 560
        let image = column == "ZFEATUREVECTOR" && table == "ZFEATUREVECTORRESULT" && data.count == 214
        guard torso || image else { return nil }
        guard uint32(data, 0) == (torso ? 0xB0D10000 : 0xCBA7097E), uint32(data, 4) == (torso ? 4 : 3), uint32(data, 8) == UInt32(data.count) else { return nil }
        let stored = Data(data[12..<28]), calculated = Data(Insecure.MD5.hash(data: Data(data[28...])))
        var fields = ["Serialization version": String(uint32(data, 4)), "Record bytes": String(data.count), "Stored MD5 checksum": stored.map { String(format: "%02x", $0) }.joined(),
                      "Checksum validation": stored == calculated ? "Matches bytes 28 through end" : "MISMATCH · descriptor not interpreted",
                      "Evidence": "Captured layouts and static Vision serializer evidence from macOS 27.0.1 (26A434); compatibility with other layouts unverified."]
        guard stored == calculated else { return DecodedPayload(summary: "Descriptor checksum mismatch", fields: fields, rectangles: []) }
        if torso {
            guard uint32(data, 28) == 0xDECAF008, uint32(data, 32) == 0x74727370, uint32(data, 36) == 512, uint32(data, 40) == 128,
                  let vector = float32(Data(data[44..<556]), count: 128) else { return nil }
            let confidence = Float(bitPattern: uint32(data, 556))
            guard confidence.isFinite, (0...1).contains(confidence) else { return nil }
            fields.merge(statistics(vector)) { _, new in new }
            fields["Descriptor confidence"] = String(format: "%.6f", confidence)
            fields["Request marker"] = "0xDECAF008 · not an ordinary model revision"
            fields["Format"] = "torso-raw-f32-128-serialization4"
            fields["Interpretation"] = "128 little-endian Float32 descriptor components and serializer-supported confidence. These are learned features, not joints or coordinate arrays. Similarity does not identify a person."
            return DecodedPayload(summary: "Torso descriptor · validated structure/checksum", fields: fields, rectangles: [], vector: vector)
        }
        guard uint64(data, 28) == 174, uint32(data, 36) == 2, uint16(data, 52) == 1, uint32(data, 54) == 136,
              uint32(data, 194) == 1, uint32(data, 198) == 136, uint32(data, 202) == 0,
              uint32(data, 206) == 1, uint32(data, 210) == 0x696D6770 else { return nil }
        let quality = Float(bitPattern: uint32(data, 48))
        guard quality.isFinite,
              let features = ImageFeatureDescriptor(textureResponses: stride(from: 58, to: 122, by: 2).map { uint16(data, $0) },
                                                    colorBins: stride(from: 122, to: 194, by: 2).map { uint16(data, $0) }) else { return nil }
        fields["Outer payload bytes"] = "174"
        fields["Inner section bytes"] = "136 · offsets 58–193"
        fields["Inner section · hex"] = data[58..<194].map { String(format: "%02x", $0) }.joined(separator: " ")
        fields["Trailer · hex"] = data[194...].map { String(format: "%02x", $0) }.joined(separator: " ")
        fields["Format"] = "image-color-gabor-u16-68-serialization3"
        fields["Descriptor version"] = "2"
        fields["Raw storage format"] = "1"
        fields["EXIF timestamp · raw seconds"] = String(Int64(bitPattern: uint64(data, 40)))
        fields["Descriptor quality · raw"] = String(quality)
        fields["Descriptor count / stride"] = "1 / 136 bytes"
        fields["Imageprint type"] = "0"
        fields["Originating request"] = "VNCreateImageprintRequest · revision 1 · code 0x696D6770 (imgp)"
        fields["Texture responses · UInt16"] = features.textureResponses.map(String.init).joined(separator: ", ")
        fields["Color bins · UInt16"] = features.colorBins.map(String.init).joined(separator: ", ")
        fields["Quantized color mass"] = String(format: "%.9f", Double(features.colorMass) / 65_535)
        fields["Color histogram validation"] = features.hasColorSummary ? "Normalized mass within 36-bin truncation loss" : "Unexpected mass · color summary unavailable"
        fields["Evidence"] = "26A434 native VNImageprint reader/getters and exact reserialization for all 57 captured rows; 106 RGB controls cover all 36 bins. Other layouts are unverified."
        fields["Interpretation"] = "32 little-endian UInt16 Gabor responses (4 scales × 8 orientations) and 36 UInt16 HSV bins. Color shares approximate the central crop after per-bin truncation; swatches represent groups, not sampled RGB values. Quality and EXIF slots are zero in the capture. EXIF zero also denotes a missing/invalid time; quality is not calibrated confidence. Texture responses are not probabilities or learned cosine-comparison vectors."
        return DecodedPayload(summary: "Color and texture descriptor · validated layout/checksum", fields: fields, rectangles: [], imageFeatures: features)
    }
}
