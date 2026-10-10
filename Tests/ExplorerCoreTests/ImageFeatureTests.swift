import XCTest
import CryptoKit
@testable import ExplorerCore

final class ImageFeatureTests: XCTestCase {
    // Native-captured public test image MAE-food-fruit-still-life.jpg, record 10
    // in the sanitized 26A434 capture. This is not a constructed decoder fixture.
    private let fruitHex = "7e09a7cb03000000d6000000de70607bf0e1a6a6c1c839a57ef97620ae00000000000000020000000000000000000000000000000100880000005c0e730dfb0c69100a13c613af128010c811f61113116c158017e6185217c312581492142f10a8128f185b1ad3177313f10ae70ab109c40ba20fbf0fec0d180c7606c400fe007c01020443074a05f602a10a87029210f91df1206e190e0abb278f065205e2001d006302690408000200e205f11f00000000510105000000000000000000000000000100000088000000000000000100000070676d69"
    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
    private func decode(_ data: Data) -> DecodedPayload? { AnalysisPayload.decode(data, column: "ZFEATUREVECTOR", table: "ZFEATUREVECTORRESULT") }
    private func checksum(_ bytes: inout Data) { bytes.replaceSubrange(12..<28, with: Data(Insecure.MD5.hash(data: Data(bytes[28...])))) }

    func testCapturedFruitProducesReadableGroupsAndPreservesRecoveredFields() throws {
        let payload = try XCTUnwrap(decode(bytes(fruitHex))), features = try XCTUnwrap(payload.imageFeatures)
        XCTAssertEqual(features.textureResponses.count, 32)
        XCTAssertEqual(Array(features.textureResponses.prefix(4)), [3676, 3443, 3323, 4201])
        XCTAssertEqual(features.leadingColors, "Orange · Red · Cyan")
        XCTAssertEqual(features.colorGroups.prefix(3).map(\.category), [.orange, .red, .cyan])
        XCTAssertEqual(features.colorGroups.prefix(3).map(\.percentage), ["42%", "23%", "15%"])
        XCTAssertEqual(features.colorGroups.reduce(0) { $0 + $1.mass }, features.colorMass)
        XCTAssertEqual(features.colorBins.count, 36)
        XCTAssertEqual(payload.fields["Descriptor version"], "2")
        XCTAssertEqual(payload.fields["EXIF timestamp · raw seconds"], "0")
        XCTAssertEqual(payload.fields["Descriptor quality · raw"], "0.0")
        XCTAssertEqual(payload.fields["Format"], "image-color-gabor-u16-68-serialization3")
        XCTAssertTrue(payload.fields["Checksum validation"]!.hasPrefix("Matches"))
        XCTAssertTrue(payload.vector.isEmpty)
        XCTAssertNil(DescriptorPayload.cosine(payload, payload))
    }

    func testNativeRGBControlsCoverAll36BinsWithCorrectReadableCategories() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("research-notes/feature-vector/color-generation-validation.json"))) as! [String: Any]
        let controls = json["controls"] as! [[String: Any]]
        let expected: [ImageColorCategory] = [.dark, .gray, .gray, .gray, .gray, .gray, .gray, .light,
            .red, .red, .red, .red, .orange, .orange, .orange, .orange, .yellow, .yellow, .yellow, .yellow,
            .green, .green, .green, .green, .cyan, .cyan, .cyan, .cyan, .blue, .blue, .blue, .blue, .purple, .purple, .purple, .purple]
        var seen: Set<Int> = []
        for control in controls {
            let bin = control["nativeBin"] as! Int; seen.insert(bin)
            var data = bytes(fruitHex)
            data.replaceSubrange(58..<194, with: Data(repeating: 0, count: 136))
            data[122 + bin * 2] = 255; data[123 + bin * 2] = 255; checksum(&data)
            let image = try XCTUnwrap(decode(data)?.imageFeatures)
            XCTAssertTrue(image.hasColorSummary)
            XCTAssertEqual(image.colorGroups.count, 1)
            XCTAssertEqual(image.colorGroups.first?.category, expected[bin], control["name"] as! String)
            XCTAssertEqual(image.colorGroups.first?.fraction, 1)
            XCTAssertEqual(image.colorGroups.first?.percentage, "100%")
            XCTAssertEqual(image.textureResponses, [UInt16](repeating: 0, count: 32))
        }
        XCTAssertEqual(controls.count, 106); XCTAssertEqual(seen, Set(0..<36))
    }

    func testCorruptAndFutureLayoutsNeverProduceAPalette() throws {
        let original = bytes(fruitHex)
        var corrupt = original; corrupt[58] ^= 1
        let mismatch = try XCTUnwrap(decode(corrupt))
        XCTAssertNil(mismatch.imageFeatures); XCTAssertTrue(mismatch.summary.contains("mismatch"))
        XCTAssertNil(decode(Data(original.dropLast())))
        for offset in [0, 4, 8, 28, 32, 36, 52, 54, 194, 198, 202, 206, 210] {
            var future = original; future[offset] ^= 1; checksum(&future)
            XCTAssertNil(decode(future), "Unsupported field at byte \(offset) was accepted")
        }
        var nonfinite = original; nonfinite.replaceSubrange(48..<52, with: [0, 0, 128, 127]); checksum(&nonfinite)
        XCTAssertNil(decode(nonfinite))
        XCTAssertNil(AnalysisPayload.decode(original, column: "ZFEATUREVECTOR", table: "ZFACEPRINTRESULT"))
    }

    func testInvalidHistogramMassKeepsTechnicalBytesButDoesNotInventColors() throws {
        for fill: UInt8 in [0, 255] {
            var data = bytes(fruitHex); data.replaceSubrange(122..<194, with: Data(repeating: fill, count: 72)); checksum(&data)
            let payload = try XCTUnwrap(decode(data)), image = try XCTUnwrap(payload.imageFeatures)
            XCTAssertFalse(image.hasColorSummary); XCTAssertTrue(image.colorGroups.isEmpty); XCTAssertEqual(image.leadingColors, "")
            XCTAssertNotNil(payload.fields["Color bins · UInt16"])
            XCTAssertEqual(payload.fields["Color histogram validation"], "Unexpected mass · color summary unavailable")
        }
        var data = bytes(fruitHex)
        let oldDark = Int(data[122]) | Int(data[123]) << 8
        let orangeOffset = 122 + 12 * 2
        let oldOrange = Int(data[orangeOffset]) | Int(data[orangeOffset + 1]) << 8
        let redistributed = oldOrange + oldDark - 1
        data[122] = 1; data[123] = 0
        data[orangeOffset] = UInt8(truncatingIfNeeded: redistributed); data[orangeOffset + 1] = UInt8(truncatingIfNeeded: redistributed >> 8)
        checksum(&data)
        let group = try XCTUnwrap(decode(data)?.imageFeatures?.colorGroups.first(where: { $0.category == .dark }))
        XCTAssertEqual(group.percentage, "<1%")
    }

    func testZeroTimeIsARealSampleAndAbsentOrInvalidTimesStayUntimed() {
        let rows = [
            DBRow(id: 2, fields: ["Z_PK": "10", "ZSTARTTIMEVALUE": "6200", "ZSTARTTIMESCALE": "200"]),
            DBRow(id: 0, fields: ["Z_PK": "9", "ZSTARTTIMEVALUE": "NULL", "ZSTARTTIMESCALE": "NULL"]),
            DBRow(id: 1, fields: ["Z_PK": "11", "ZSTARTTIMEVALUE": "0", "ZSTARTTIMESCALE": "200"]),
            DBRow(id: 3, fields: ["Z_PK": "8", "ZSTARTTIMEVALUE": "-1", "ZSTARTTIMESCALE": "200"])]
        XCTAssertEqual(ImageFeatureSamples.ordered(rows).map { $0["Z_PK"] }, ["11", "10", "8", "9"])
        XCTAssertEqual(ImageFeatureSamples.time(rows[2]), 0)
        XCTAssertNil(ImageFeatureSamples.time(rows[1])); XCTAssertNil(ImageFeatureSamples.time(rows[3]))
        XCTAssertNil(ImageFeatureSamples.time(DBRow(id: 0, fields: ["ZSTARTTIMEVALUE": "5", "ZSTARTTIMESCALE": "0"])))
        XCTAssertEqual(ImageFeatureSamples.timeLabel(0), "00:00")
        XCTAssertEqual(ImageFeatureSamples.timeLabel(31), "00:31")
        XCTAssertEqual(ImageFeatureSamples.timeLabel(61.125), "01:01.125")
        XCTAssertEqual(ImageFeatureSamples.timeLabel(59.9996), "01:00")
        XCTAssertEqual(ImageFeatureSamples.timeLabel(3601), "1:00:01")
        XCTAssertEqual(ImageFeatureSamples.timeLabel(.nan), "Time unavailable")
        XCTAssertEqual(VisualMetadata.title("ZFEATUREVECTORRESULT"), "Colors & texture")
    }
}
