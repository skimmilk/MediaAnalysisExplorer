import XCTest
import Foundation
import CryptoKit
import Compression
import CSQLite
@testable import ExplorerCore

final class ResearchIntegrationTests: XCTestCase {
    private func captured() throws -> ReadDatabase {
        guard let path = ProcessInfo.processInfo.environment["MAE_RESEARCH_DATABASE"] else { throw XCTSkip("Set MAE_RESEARCH_DATABASE for read-only research integration tests") }
        return try ReadDatabase(path: path, budget: WorkBudget(seconds: 20))
    }
    private func bytes(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
    func testCapturedDescriptorHeadersChecksumsVectorsAndCorruptInputs() throws {
        let db = try captured(), url = URL(fileURLWithPath: db.path)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        for (table, column, count) in [("ZHUMANACTIONCLASSIFICATIONRESULT", "ZTORSOPRINT", 46), ("ZFEATUREVECTORRESULT", "ZFEATUREVECTOR", 57)] {
            let rows = try db.query("SELECT hex(\(column)) AS bytes FROM \(table) WHERE \(column) IS NOT NULL")
            XCTAssertEqual(rows.count, count)
            for row in rows {
                let data = bytes(row["bytes"])
                let decoded = try XCTUnwrap(AnalysisPayload.decode(data, column: column, table: table))
                XCTAssertTrue(decoded.fields["Checksum validation"]!.hasPrefix("Matches"))
                if column == "ZTORSOPRINT" {
                    XCTAssertEqual(decoded.vector.count, 128)
                    XCTAssertEqual(Double(decoded.fields["L2 norm"]!)!, 1, accuracy: 0.00001)
                    XCTAssertTrue(decoded.rectangles.isEmpty)
                    XCTAssertEqual(DescriptorPayload.cosine(decoded, decoded)!, 1, accuracy: 0.000001)
                } else {
                    XCTAssertTrue(decoded.vector.isEmpty); XCTAssertEqual(decoded.fields["Inner section bytes"], "136 · offsets 58–193")
                    let image = try XCTUnwrap(decoded.imageFeatures)
                    XCTAssertEqual(image.textureResponses.count, 32); XCTAssertEqual(image.colorBins.count, 36)
                    XCTAssertTrue(image.hasColorSummary)
                    XCTAssertEqual(image.colorGroups.reduce(0) { $0 + $1.mass }, image.colorMass)
                    XCTAssertNil(DescriptorPayload.cosine(decoded, decoded))
                }
                var corrupt = data; corrupt[30] ^= 1
                let invalid = try XCTUnwrap(AnalysisPayload.decode(corrupt, column: column, table: table))
                XCTAssertTrue(invalid.vector.isEmpty); XCTAssertTrue(invalid.summary.contains("mismatch"))
                XCTAssertNil(invalid.imageFeatures)
                var future = data; future[4] = 99
                XCTAssertNil(AnalysisPayload.decode(future, column: column, table: table))
                XCTAssertNil(AnalysisPayload.decode(Data(data.dropLast()), column: column, table: table))
            }
        }
        XCTAssertEqual(Array(SHA256.hash(data: try Data(contentsOf: url))), Array(before))
    }
    func testArchivedVectorsAndReferenceQueriesStayAssetScoped() throws {
        let db = try captured(), schema = try db.schema()
        let prints = try XCTUnwrap(schema.first { $0.name == "ZFACEPRINTRESULT" })
        let faces = try XCTUnwrap(schema.first { $0.name == "ZFACERESULT" })
        let row = try XCTUnwrap(db.analysisRows(table: prints, assetKey: "5").first)
        XCTAssertEqual(row.decoded["ZFACEPRINT"]?.vector.count, 128)
        let link = try XCTUnwrap(ResultReferences.links(row: row, table: prints.name).first)
        let matches = try db.analysisRecords(table: faces, assetKey: "5", field: link.field, value: link.value)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.allSatisfy { $0["ZASSET"] == "5" && $0["ZFACEID"] == row["ZFACEID"] })
        XCTAssertThrowsError(try db.analysisRecords(table: faces, assetKey: "5", field: "ZASSET OR 1=1", value: "5"))
        let summary = try XCTUnwrap(schema.first { $0.name == "ZSUMMARIZEDEMBEDDINGRESULT" })
        let summarized = try XCTUnwrap(db.analysisRows(table: summary, assetKey: "5").first)
        XCTAssertEqual(summarized.decoded["ZEMBEDDINGIDS"]?.referenceValues.count, 17)
        XCTAssertEqual(summarized.decoded["ZREPRESENTATIVEMAPPING"]?.referenceValues.count, 18)
        XCTAssertTrue(ResultReferences.links(row: summarized, table: summary.name).contains { $0.table == "ZVIDEOTHUMBNAILRESULT" })
        let torso = row.decoded["ZTORSOPRINT"]
        if let torso { XCTAssertEqual(torso.vector.count, 128); XCTAssertNil(DescriptorPayload.cosine(torso, row.decoded["ZFACEPRINT"]!)) }
        let video = try XCTUnwrap(schema.first { $0.name == "ZVIDEOEMBEDDINGRESULT" })
        let fused = try XCTUnwrap(schema.first { $0.name == "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT" })
        let videoPayload = try XCTUnwrap(db.analysisRows(table: video, assetKey: "5").first?.decoded["ZEMBEDDINGDATA"])
        let fusedPayload = try XCTUnwrap(db.analysisRows(table: fused, assetKey: "5").first?.decoded["ZEMBEDDINGDATA"])
        XCTAssertNil(DescriptorPayload.cosine(videoPayload, fusedPayload)) // equal dimensions do not mean interchangeable spaces.
    }
    func testColorNormalizationUsesQuantizedRangesAndRejectsUnknownHeader() throws {
        let db = try captured()
        let rows = try db.query("SELECT hex(ZCOLORNORMALIZATIONDATA) AS bytes FROM ZMOVIEHIGHLIGHTRESULT WHERE ZCOLORNORMALIZATIONDATA IS NOT NULL")
        XCTAssertEqual(rows.count, 7)
        for row in rows {
            let decoded = try XCTUnwrap(AnalysisPayload.decode(bytes(row["bytes"]), column: "ZCOLORNORMALIZATIONDATA", table: "ZMOVIEHIGHLIGHTRESULT"))
            XCTAssertEqual(decoded.fields["Format header"], "0x8002")
            XCTAssertTrue((4200...6200).contains(Double(decoded.fields["Approximate WhiteBalanceTempTintCI[0]"]!)!))
            XCTAssertTrue(decoded.rectangles.isEmpty)
        }
        var lower = Data([2, 0x80] + [UInt8](repeating: 0, count: 10))
        XCTAssertEqual(AnalysisPayload.decode(lower, column: "ZCOLORNORMALIZATIONDATA", table: "ZMOVIEHIGHLIGHTRESULT")?.fields["Approximate ContrastCI[0]"], "-0.150000")
        lower[4] = 255
        XCTAssertEqual(AnalysisPayload.decode(lower, column: "ZCOLORNORMALIZATIONDATA", table: "ZMOVIEHIGHLIGHTRESULT")?.fields["Approximate ContrastCI[0]"], "0.400000")
        lower[0] = 3
        XCTAssertNil(AnalysisPayload.decode(lower, column: "ZCOLORNORMALIZATIONDATA", table: "ZMOVIEHIGHLIGHTRESULT")?.fields["Format header"])
    }
    func testSchemaDecompressionAndRetainedWriteHistoryAccounting() throws {
        let db = try captured(), schema = try db.schema()
        let compressed = try XCTUnwrap(db.modelCacheData())
        let model = try StaticGraphDecoder.decompress(compressed, algorithm: COMPRESSION_ZLIB, maximumBytes: 256 * 1024)
        XCTAssertEqual(model.count, 73913)
        let counts = try PersistenceReader.modelCounts(model)
        XCTAssertEqual(counts.entities, 62); XCTAssertEqual(counts.properties, 551)
        let history = PersistenceReader.read(db: db, schema: schema, assetKey: "5")
        XCTAssertTrue(history.issues.isEmpty, history.issues.joined(separator: "\n"))
        let commit = try XCTUnwrap(history.events.first { $0.id == "3455" })
        XCTAssertEqual(commit.changes, 761) // 760 inserted results plus one Asset update.
        XCTAssertEqual(commit.bundle, "com.apple.mediaanalysisd")
        XCTAssertEqual(commit.date!.timeIntervalSinceReferenceDate, 813285506.83944, accuracy: 0.001)
        XCTAssertTrue(history.events.contains { $0.id == "3421" }) // earlier image caption.
        XCTAssertEqual(history.modelFields["Schema entities"], "62")
        XCTAssertThrowsError(try StaticGraphDecoder.decompress(compressed, algorithm: COMPRESSION_ZLIB, maximumBytes: 100))
        XCTAssertThrowsError(try StaticGraphDecoder.decompress(Data(), algorithm: COMPRESSION_ZLIB, maximumBytes: 100))
    }
    func testInstalledCompressedGraphPreservesSignatureAndDecodedChecksum() throws {
        let path = "/System/Library/PrivateFrameworks/CoreSceneUnderstanding.framework/Versions/A/Resources/scenenet_v5_custom_classifiers/SafetyNetLight/SafetyNetLight_v1.3.0/SafetyNetLight_v1.3.0_83cm9h9a9m_4436_safetynet_quant.espresso.net"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Matching installed compressed graph unavailable") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try StaticGraphDecoder.decode(data)
        XCTAssertEqual(decoded.sha256, "7620459d01b46a68651c82fb7228649727f53f5a4246607e727590e72b6f88ee")
        let graph = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(decoded.text.utf8)) as? [String: Any])
        XCTAssertEqual((graph["layers"] as? [Any])?.count, 15)
        let inspection = try Inventory.inspect(url: URL(fileURLWithPath: path), hash: false, budget: WorkBudget())
        XCTAssertTrue(inspection.signature.hasPrefix("70 62 7a 65")); XCTAssertEqual(inspection.metadataSHA256, decoded.sha256)
        var future = data; future[4] = 1
        XCTAssertThrowsError(try StaticGraphDecoder.decode(future))
        XCTAssertThrowsError(try StaticGraphDecoder.decode(Data(data.dropLast())))
        var oversized = data; oversized[16] = 255
        XCTAssertThrowsError(try StaticGraphDecoder.decode(oversized))
    }
    func testInstalledNatureworldCompressedGraph() throws {
        try checkVisualLookUpGraph(asset: "assets_582", model: "NatureworldModel", decodedBytes: 195771, layers: 704, sha256: "87a91aa141c51ef829747ac9ba8808a442affd4477669ce23d3e3a688a20e3b1")
    }
    func testInstalledObjectDetectionCompressedGraph() throws {
        try checkVisualLookUpGraph(asset: "assets_581", model: "ObjectDetectionModel", decodedBytes: 168657, layers: 487, sha256: "5f3233606cc7f8858ab5179861cf2f8a451bcfe5e4ff60dfb47d2bbf44d3741f")
    }
    private func checkVisualLookUpGraph(asset: String, model: String, decodedBytes: Int, layers: Int, sha256: String) throws {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/VisualLookUp.framework/Versions/A/Resources/\(asset)/\(model)/model.espresso.net")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Matching installed \(model) graph unavailable") }
        let data = try Data(contentsOf: url)
        let decoded = try StaticGraphDecoder.decode(data)
        XCTAssertEqual(Data(decoded.text.utf8).count, decodedBytes)
        XCTAssertEqual(decoded.sha256, sha256)
        let graph = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(decoded.text.utf8)) as? [String: Any])
        XCTAssertEqual((graph["layers"] as? [Any])?.count, layers)
        XCTAssertEqual(graph["format_version"] as? Int, 200)
        let inspection = try Inventory.inspect(url: url, hash: false, budget: WorkBudget())
        XCTAssertNil(inspection.metadataIssue)
        XCTAssertTrue(inspection.signature.hasPrefix("70 62 7a 65"))
        XCTAssertEqual(inspection.metadata, decoded.text)
        XCTAssertEqual(inspection.metadataSHA256, sha256)
        for offset in [4, 8, 9, 12, 20] {
            var unknown = data; unknown[offset] = 2
            XCTAssertThrowsError(try StaticGraphDecoder.decode(unknown), "Unexpected header byte at \(offset) must remain unsupported")
        }
        var wrongLength = data; wrongLength[27] ^= 1
        XCTAssertThrowsError(try StaticGraphDecoder.decode(wrongLength))
        func setLength(_ value: Int, offset: Int, in bytes: inout Data) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (3 - index))) }
        }
        var oversized = data; setLength(256 * 1024 + 1, offset: 16, in: &oversized)
        XCTAssertThrowsError(try StaticGraphDecoder.decode(oversized))
        var mismatchedOutput = data; setLength(decodedBytes + 1, offset: 16, in: &mismatchedOutput)
        XCTAssertThrowsError(try StaticGraphDecoder.decode(mismatchedOutput))
        XCTAssertThrowsError(try StaticGraphDecoder.decode(Data(data.dropLast())))
        var truncatedPayload = Data(data.prefix(28 + (data.count - 28) / 2))
        setLength(truncatedPayload.count - 28, offset: 24, in: &truncatedPayload)
        XCTAssertThrowsError(try StaticGraphDecoder.decode(truncatedPayload))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testFacePositionFlagAndYawNamespacesRemainExplicit() throws {
        let db = try captured()
        for row in try db.query("SELECT ZFLAGS,ZWIDTH,ZHEIGHT FROM ZFACERESULT") {
            let mask = UInt64(row["ZFLAGS"])!
            let closeup = max(Double(row["ZWIDTH"])!, Double(row["ZHEIGHT"])!) >= 0.44999998807907104
            XCTAssertEqual(mask & 16 != 0, closeup)
        }
        let fields = AnalysisFieldInterpretation.fields(DBRow(id: 0, fields: ["ZPOSITION": "25", "ZYAW": "2", "ZFLAGS": "50"]), table: "ZFACERESULT")
        XCTAssertEqual(fields["Position regions"], "top, left, center")
        XCTAssertTrue(fields["Face flags"]!.contains("smile"))
        XCTAssertEqual(fields["Unknown face flag bits"], "0x20")
        XCTAssertTrue(fields["Yaw interpretation"]!.contains("not degrees"))
        XCTAssertNil(AnalysisFieldInterpretation.fields(DBRow(id: 0, fields: ["ZYAW": "99"]), table: "ZFACERESULT")["Yaw interpretation"])
        let pose = AnalysisFieldInterpretation.fields(DBRow(id: 0, fields: ["ZFLAGS": String(15 << 20), "ZKEYPOINTS": "NULL"]), table: "ZHUMANPOSERESULT")
        XCTAssertTrue(pose["Supported pose groups"]!.contains("bit 23: one of 13/14"))
        XCTAssertTrue(pose["Pose geometry"]!.contains("No joint"))
    }
    func testDerivativePathRejectsTraversalAndEscapingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "CF715438-C5AE-4792-9F2D-E70FC1502048/L0/001"
        let source = SourceConfiguration(libraryPath: root.path)
        let url = try LibraryReader.thumbnailURL(identifier: identifier, thumbnailID: "t0000", source: source)
        XCTAssertTrue(url.path.hasSuffix("/C/CF715438-C5AE-4792-9F2D-E70FC1502048/CF715438-C5AE-4792-9F2D-E70FC1502048_cvt_t0000.jpeg"))
        XCTAssertThrowsError(try LibraryReader.thumbnailURL(identifier: identifier, thumbnailID: "../../secret", source: source))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("resources/derivatives"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("resources/derivatives/cvt"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try LibraryReader.thumbnailURL(identifier: identifier, thumbnailID: "t0000", source: source))
    }
    func testDenseOverlappingIntervalsUseCorrectBoundariesAndSeeks() {
        let regions = (0..<10000).map { StoredRegion(id: String($0), title: "test", table: "test", record: String($0), rectangle: .zero, fields: [:], start: Double($0) / 100, duration: 100) }
        let timeline = RegionTimeline(regions: regions)
        for second in [0.0, 50, 99.99, 100, 199.99, 0, 75.123] {
            XCTAssertEqual(timeline.visible(at: second).map(\.id), regions.filter { $0.visible(at: second) }.map(\.id))
        }
    }
    func testGeometryInventoryIncludesLaterMetadataPagesAndSurvivesAppending() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY,ZLOCALIDENTIFIER TEXT);
            CREATE TABLE ZHUMANPOSERESULT (Z_PK INTEGER PRIMARY KEY,ZASSET INTEGER,ZSTARTTIMEVALUE INTEGER,ZSTARTTIMESCALE INTEGER,ZDURATIONTIMEVALUE INTEGER,ZDURATIONTIMESCALE INTEGER,ZX REAL,ZY REAL,ZWIDTH REAL,ZHEIGHT REAL);
            INSERT INTO ZASSET VALUES(1,'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001');
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<121)
            INSERT INTO ZHUMANPOSERESULT SELECT n,1,n-1,1,1,1,0.1,0.1,0.2,0.2 FROM numbers;
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        let db = try ReadDatabase(path: url.path)
        let detail = try LibraryReader.detail(asset: MediaAsset(id: "1", identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001", fields: [:]), source: SourceConfiguration(analysisPath: url.path), budget: WorkBudget(seconds: 10))
        XCTAssertEqual(detail.families.first?.rows.count, 100)
        XCTAssertEqual(detail.regionTimeline.regions.count, 121)
        XCTAssertEqual(detail.regionTimeline.visible(at: 120.5).first?.record, "121")
        XCTAssertTrue(detail.playbackTimeline.records.isEmpty) // spatial rows aren't audio/activity events.
        let table = try XCTUnwrap(detail.families.first?.table)
        let updated = detail.appending(try db.analysisRows(table: table, offset: 100, assetKey: "1"), to: table.name)
        XCTAssertEqual(updated.regionTimeline.regions.count, 121)
    }
    func testSchemaReferenceAndVocabularyUseExplicitIdentifiers() throws {
        let data = Data(#"{"entities":{"HumanPoseResult":{"properties":{"keypoints":{"NSAttributeType":1800,"NSValueTransformerName":"NSSecureUnarchiveFromData"}}}}}"#.utf8)
        let notes = try SchemaReference.project(data)
        XCTAssertTrue(notes["ZHUMANPOSERESULT:ZKEYPOINTS"]!.contains("Transformable"))
        XCTAssertTrue(notes["ZHUMANPOSERESULT:ZKEYPOINTS"]!.contains("NSSecureUnarchiveFromData"))
        let tokens = [CaptionToken(id: 11, word: "people"), CaptionToken(id: 2, word: "a")]
        XCTAssertEqual(CaptionVocabulary.matches("11", tokens: tokens).first?.word, "people")
        XCTAssertEqual(CaptionVocabulary.matches("PEOPLE", tokens: tokens).first?.id, 11)
        XCTAssertTrue(CaptionVocabulary.matches("0", tokens: tokens).isEmpty)
    }
}
