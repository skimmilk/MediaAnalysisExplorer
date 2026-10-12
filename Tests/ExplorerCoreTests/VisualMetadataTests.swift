import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import ExplorerCore

final class VisualMetadataTests: XCTestCase {
    private func family(_ fields: [[String: String]]) -> ResultFamily {
        ResultFamily(table: TableSchema(name: "ZHUMANPOSERESULT", columns: [:]), count: fields.count, rows: fields.enumerated().map { DBRow(id: $0.offset, fields: $0.element) })
    }
    func testCacheExplanationPreservesDeclaredOutputsAndOpaquePathKeys() {
        let url = URL(fileURLWithPath: "/cache/com.apple.e5rt.e5bundlecache/26A434/opaque/variant.bundle/H13G.bundle/main/segment_1__cpu/model.espresso.net")
        let metadata = "{\"layers\":[{\"type\":\"non_maximum_suppression\",\"top\":\"nmsBoxes,nmsScores\",\"attributes\":{\"is_output\":1}}],\"storage\":\"model.espresso.weights\"}"
        let explanation = CacheExplanation.describe(url: url, metadata: metadata)
        XCTAssertEqual(explanation.role, "Espresso graph description")
        XCTAssertEqual(explanation.pathFields["Opaque cache key"], "opaque")
        XCTAssertEqual(explanation.bundleDirectory?.path, "/cache/com.apple.e5rt.e5bundlecache/26A434/opaque/variant.bundle")
        XCTAssertTrue(explanation.observations.contains { $0.contains("nmsBoxes,nmsScores") })
        XCTAssertNil(explanation.purpose)
        XCTAssertTrue(explanation.executionBackends.isEmpty)
        XCTAssertEqual(CacheExplanation.describe(url: URL(fileURLWithPath: "/tmp/unknown.bin"), metadata: "invalid").role, "Cached file · purpose unresolved")
    }

    func testCachedGraphSourceReferencesPreserveDeclaredProvenance() {
        let source = "/System/Library/PrivateFrameworks/CoreSceneUnderstanding.framework/Resources/video_captioning/decoder.mlmodelc/model.mil"
        let metadata: [String: Any] = ["layers": [["type": "softmax_nd", "debug_info": "at \(source):508:12"], ["type": "cast", "debug_info": "at \(source):509:5"]]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!
        let result = CacheExplanation.describe(url: URL(fileURLWithPath: "/cache/model.espresso.net"), metadata: json)
        XCTAssertEqual(result.sourceReferences, [source])
        XCTAssertEqual(result.purpose, "Decodes visual features into caption word scores.")
        XCTAssertTrue(CacheExplanation.describe(url: URL(fileURLWithPath: "/cache/bnns_program.bnnsir"), metadata: nil).sourceReferences.isEmpty)
    }

    func testCachedGraphNestedMetadataIdentifiesSourceWithoutAssetAttribution() throws {
        let source = "/System/Library/PrivateFrameworks/VisualLookUp.framework/Versions/A/Resources/assets_581/ObjectDetectionModel/model.espresso.net"
        let metadata: [String: Any] = ["analyses": ["N8Espresso23analysis_debug_metadataE": [
            "name": "ObjectDetectionModel", "com.apple.EspressoFramework": ["input-file-path": source, "on-device-compilation": "true"]]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!
        let result = CacheExplanation.describe(url: URL(fileURLWithPath: "/cache/model.espresso.net"), metadata: json)
        XCTAssertEqual(result.sourceReferences, [source])
        XCTAssertTrue(result.observations.contains("Declared source model name: ObjectDetectionModel"))
        XCTAssertTrue(result.observations.contains("Declared on-device compilation: true"))
        XCTAssertEqual(result.purpose, "Detects objects and scores their categories for Visual Look Up.")
    }

    func testProjectionLetterboxingOriginsAndOverlappingHitTargets() {
        let frame = VisualMetadata.imageFrame(image: CGSize(width: 400, height: 200), container: CGSize(width: 500, height: 500))
        XCTAssertEqual(frame, CGRect(x: 0, y: 125, width: 500, height: 250))
        let regions = VisualMetadata.regions(family([
            ["Z_PK":"1","ZX":"0.2","ZY":"0.1","ZWIDTH":"0.4","ZHEIGHT":"0.5"],
            ["Z_PK":"2","ZX":"0.3","ZY":"0.2","ZWIDTH":"0.1","ZHEIGHT":"0.1"]]))
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(VisualMetadata.project(regions[0].rectangle, into: frame, bottomOrigin: false).minY, 150, accuracy: 0.00001)
        XCTAssertEqual(VisualMetadata.project(regions[0].rectangle, into: frame, bottomOrigin: true).minY, 225, accuracy: 0.00001)
        XCTAssertEqual(VisualMetadata.hit(CGPoint(x: 175, y: 190), regions: regions, frame: frame, bottomOrigin: false)?.record, "2")
        XCTAssertNil(VisualMetadata.hit(CGPoint(x: 175, y: 60), regions: regions, frame: frame, bottomOrigin: false))
    }
    func testInvalidOrPixelCoordinatesNeverBecomeGuessedRegions() {
        let invalid = [["ZX":"NaN","ZY":"0","ZWIDTH":"0.1","ZHEIGHT":"0.1"],
                       ["ZX":"40","ZY":"40","ZWIDTH":"100","ZHEIGHT":"100"],
                       ["ZX":"0.5","ZY":"0.8","ZWIDTH":"0.4","ZHEIGHT":"0.5"],
                       ["ZX":"0","ZY":"0","ZWIDTH":"0","ZHEIGHT":"1"],
                       ["ZX":"0","ZY":"0","ZWIDTH":"-1","ZHEIGHT":"1"]]
        XCTAssertTrue(VisualMetadata.regions(family(invalid)).isEmpty)
    }
    func testPinnedAndHoveredOverlaysAreAboveOthersWithoutDuplicatingRegions() {
        let regions = VisualMetadata.regions(family((1...4).map { ["Z_PK": String($0), "ZX": "0", "ZY": "0", "ZWIDTH": "1", "ZHEIGHT": "1"] }))
        XCTAssertEqual(VisualMetadata.overlayOrder(regions, hovered: regions[0].id, pinned: regions[1].id).map(\.record), ["3", "4", "2", "1"])
        XCTAssertEqual(VisualMetadata.overlayOrder(regions, hovered: nil, pinned: regions[0].id).map(\.record), ["2", "3", "4", "1"])
        XCTAssertEqual(VisualMetadata.overlayOrder(regions, hovered: regions[0].id, pinned: regions[0].id).map(\.record), ["2", "3", "4", "1"])
        XCTAssertEqual(VisualMetadata.overlayOrder(regions, hovered: "missing", pinned: nil), regions)
    }
    func testFaceAndTorsoOverlayDetailsUseOnlySetFaceFlags() throws {
        var fields = ["Z_PK": "7", "ZFLAGS": "18", "ZX": "0.1", "ZY": "0.2", "ZWIDTH": "0.1", "ZHEIGHT": "0.1",
                      "ZTORSOX": "0.1", "ZTORSOY": "0.1", "ZTORSOWIDTH": "0.2", "ZTORSOHEIGHT": "0.4"]
        func regions(_ table: String = "ZFACERESULT") -> [StoredRegion] {
            VisualMetadata.regions(ResultFamily(table: TableSchema(name: table, columns: [:]), count: 1, rows: [DBRow(id: 0, fields: fields)]))
        }
        let faceAndTorso = regions()
        XCTAssertEqual(faceAndTorso.count, 2)
        XCTAssertEqual(faceAndTorso.map(\.overlayDetails), [["smile, close-up"], ["smile, close-up"]])
        XCTAssertEqual(faceAndTorso[0].overlayLabel(focused: false), "Face #7")
        XCTAssertEqual(faceAndTorso[0].overlayLabel(focused: true), "Face #7\nsmile, close-up")
        XCTAssertEqual(faceAndTorso[1].overlayLabel(focused: true), "Face torso #7\nsmile, close-up")
        fields["ZFLAGS"] = "12"
        XCTAssertEqual(regions().first?.overlayDetails, ["both eyes closed, one/either eye closed"])
        fields["ZFLAGS"] = "50"
        XCTAssertEqual(regions().first?.overlayDetails, ["smile, close-up, unknown flags 0x20"])
        fields["ZFLAGS"] = "1"
        XCTAssertEqual(regions().first?.overlayDetails, ["unknown flags 0x1"])
        for value in ["0", "NULL", "invalid"] {
            fields["ZFLAGS"] = value
            XCTAssertTrue(try XCTUnwrap(regions().first).overlayDetails.isEmpty)
        }
        fields.removeValue(forKey: "ZFLAGS")
        XCTAssertTrue(try XCTUnwrap(regions().first).overlayDetails.isEmpty)
        fields["ZFLAGS"] = "18"
        XCTAssertTrue(try XCTUnwrap(regions("ZHUMANPOSERESULT").first).overlayDetails.isEmpty)
    }
    func testRationalTimingAndIntervalFiltering() {
        let region = VisualMetadata.regions(family([["ZX":"0","ZY":"0","ZWIDTH":"1","ZHEIGHT":"1",
            "ZSTARTTIMEVALUE":"1200","ZSTARTTIMESCALE":"600","ZDURATIONTIMEVALUE":"600","ZDURATIONTIMESCALE":"600"]])).first!
        XCTAssertFalse(region.visible(at: 1.999)); XCTAssertTrue(region.visible(at: 2)); XCTAssertFalse(region.visible(at: 3))
        XCTAssertTrue(region.visible(at: nil))
        XCTAssertNil(VisualMetadata.seconds(DBRow(id: 0, fields: ["v":"1","s":"0"]), value: "v", scale: "s"))
    }
    func testCaptionAndOpaqueDataRemainStoredValues() {
        let row = DBRow(id: 0, fields: ["Z_PK":"1", "ZASSET":"2", "ZCAPTION":"A dog sits beside a person.", "ZCONFIDENCE":"0.79", "ZKEYPOINTS":"BLOB · 160 bytes (undecoded)", "ZTEXT":"NULL"])
        let fields = VisualMetadata.meaningfulFields(row)
        XCTAssertEqual(fields["ZCAPTION"], "A dog sits beside a person.")
        XCTAssertEqual(fields["ZKEYPOINTS"], "BLOB · 160 bytes (undecoded)")
        XCTAssertNil(fields["ZASSET"]); XCTAssertNil(fields["ZTEXT"])
        XCTAssertEqual(VisualMetadata.label("ZCAPTION"), "Generated caption")
    }
    func testThumbnailSubtitleUsesOneOptionalDecimalAndWholePercentWithoutChangingFields() {
        let fields = ["ZSTARTTIMEVALUE": "1499", "ZSTARTTIMESCALE": "600", "ZQUALITY": "0.87654"]
        let row = DBRow(id: 0, fields: fields)
        XCTAssertEqual(VisualMetadata.thumbnailSubtitle(row), "At 2.5 s Quality 88%")
        XCTAssertEqual(row.fields, fields)
        XCTAssertEqual(VisualMetadata.compactSeconds(2), "2 s")
        XCTAssertEqual(VisualMetadata.compactSeconds(1.999), "2 s")
        XCTAssertEqual(VisualMetadata.compactSeconds(0), "0 s")
        XCTAssertEqual(VisualMetadata.compactSeconds(0.01), "0 s")
        XCTAssertEqual(VisualMetadata.thumbnailSubtitle(DBRow(id: 1, fields: [:])), "Time unavailable Quality unavailable")
        XCTAssertEqual(VisualMetadata.thumbnailSubtitle(DBRow(id: 2, fields: ["ZQUALITY": "NaN"])), "Time unavailable Quality unavailable")
    }
    func testOrientedImagePreviewAndDownsampling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        let url = root.appendingPathComponent("oriented.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let preview = try PreviewReader.read(url, budget: WorkBudget())
        XCTAssertFalse(preview.video); XCTAssertLessThanOrEqual(preview.height, 2000)
        XCTAssertGreaterThan(preview.height, preview.width)
        let source = CGImageSourceCreateWithData(preview.data as CFData, nil)!
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, preview.width)
        let inline = try PreviewReader.read(url, budget: WorkBudget(), maximumPixelSize: 400)
        XCTAssertLessThanOrEqual(max(inline.width, inline.height), 400)
    }
    func testImportedVideoPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["MAE_TEST_MEDIA_DIRECTORY"] else {
            throw XCTSkip("Set MAE_TEST_MEDIA_DIRECTORY to verify the downloaded video batch.")
        }
        for name in ["MAE-speech-jfk.mp4", "MAE-mission-control.mp4", "MAE-landing-cheers.mp4", "MAE-animation-music.mp4"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            let preview = try PreviewReader.read(url, budget: WorkBudget(seconds: 15))
            XCTAssertTrue(preview.video, name)
            XCTAssertGreaterThan(preview.width, 0, name)
            XCTAssertGreaterThan(preview.height, 0, name)
            XCTAssertLessThanOrEqual(max(preview.width, preview.height), 2000, name)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.data as CFData, nil), name)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
            XCTAssertEqual(image.width, preview.width, name)
            XCTAssertEqual(image.height, preview.height, name)
        }
    }
    func testManifestChecksumAndTraversalProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("test data".utf8); try data.write(to: root.appendingPathComponent("test.jpg"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func manifest(_ name: String, hash: String) throws -> TestMediaManifest {
            let json: [String: Any] = ["album":"Test", "items":[["filename":name,"source":"https://example.com","creator":"Test","license":"Test","targets":[],"sha256":hash]]]
            return try JSONDecoder().decode(TestMediaManifest.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(try manifest("test.jpg", hash: digest).validatedFiles(at: root).count, 1)
        XCTAssertThrowsError(try manifest("test.jpg", hash: "incorrect").validatedFiles(at: root))
        XCTAssertThrowsError(try manifest("../test.jpg", hash: digest).validatedFiles(at: root))
    }
}
