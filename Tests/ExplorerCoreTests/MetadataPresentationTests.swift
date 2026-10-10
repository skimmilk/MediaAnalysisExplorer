import XCTest
@testable import ExplorerCore

final class MetadataPresentationTests: XCTestCase {
    func testPoseValuesRemainVisibleWhileDefinitionsMoveToNotes() {
        let fields = VisualMetadata.explainedFields(DBRow(id: 0, fields: ["ZFLAGS": String((1 << 20) | (1 << 22)), "ZKEYPOINTS": "NULL", "ZCONFIDENCE": "0.75"]), table: "ZHUMANPOSERESULT")
        let result = MetadataPresentation(fields: fields)
        XCTAssertEqual(result.values["Pose flag structure"], "Group mask: 5")
        XCTAssertEqual(result.values["Supported pose groups"], "bit 20, bit 22")
        XCTAssertEqual(result.values["Pose geometry"], "Keypoints not stored")
        XCTAssertEqual(result.values["ZCONFIDENCE"], "0.75")
        XCTAssertNil(result.values["Pose group evidence"])
        XCTAssertEqual(result.notes["Pose group evidence"], fields["Pose group evidence"])
        for key in fields.keys { XCTAssertNotNil(result.values[key] ?? result.notes[key], "Lost field \(key)") }
    }
    func testUnknownFieldsAndCaptionTextAreNeverClassifiedByTheirContent() {
        let fields = ["ZCAPTION": "This evidence is unverified. No coordinates are stored.", "ZNEWPRIVATEFIELD": "Explanation: test", "ZFLAGS": "17", "Interpretation": "Decoder format limitation"]
        let result = MetadataPresentation(fields: fields)
        XCTAssertEqual(result.values["ZCAPTION"], fields["ZCAPTION"])
        XCTAssertEqual(result.values["ZNEWPRIVATEFIELD"], fields["ZNEWPRIVATEFIELD"])
        XCTAssertEqual(result.values["ZFLAGS"], "17")
        XCTAssertNil(result.values["Interpretation"])
        XCTAssertEqual(result.notes["Interpretation"], fields["Interpretation"])
    }
    func testCacheKeepsGraphValuesAndProvidesPlainSummary() {
        let graph = CacheExplanation.describe(url: URL(fileURLWithPath: "/fixture/model.espresso.net"), metadata: "{\"layers\":[{\"type\":\"non_maximum_suppression\",\"max_boxes\":12}],\"format_version\":3}")
        XCTAssertTrue(graph.dataObservations.contains("Declared graph format version: 3"))
        XCTAssertTrue(graph.dataObservations.contains("NMS post-processing: max_boxes=12"))
        XCTAssertFalse(graph.dataObservations.contains { $0.contains("not a separate process") || $0.contains("not the complete upstream") })
        XCTAssertEqual(graph.summary, "Neural-network operations and their connections, read by Apple's Espresso runtime.")
    }
}
