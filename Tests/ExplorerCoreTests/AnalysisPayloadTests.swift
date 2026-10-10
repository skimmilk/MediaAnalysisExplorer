import XCTest
import Foundation
import CryptoKit
import CSQLite
@testable import ExplorerCore

final class AnalysisPayloadTests: XCTestCase {
    private func archive(_ value: Any) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
    }
    private let taxonomy = AnalysisTaxonomy(identifiers: ["people": 881], labels: ["people": "People"], actions: ["none", "other", "walking", "clapping"])

    func testActionScoreArchivesPreserveValuesAndLabelEvidence() throws {
        let decoded = try XCTUnwrap(AnalysisPayload.decode(try archive(["3": 0.44858646392822266, "99": 0.1]), column: "ZACTIONSCONFIDENCE", table: "ZHUMANACTIONCLASSIFICATIONRESULT", taxonomy: taxonomy))
        XCTAssertEqual(decoded.fields["clapping · ID 3"], "0.44858646392822266")
        XCTAssertEqual(Double(try XCTUnwrap(decoded.fields["ID 99 (unresolved)"])), 0.1)
        XCTAssertTrue(decoded.fields["Label evidence"]!.contains("compatibility unverified"))
    }
    func testActionProbabilityLabelsPreserveOriginalScoresAndSortDescending() throws {
        let decoded = try XCTUnwrap(AnalysisPayload.decode(try archive(["3": 0.44858646392822266, "2": 0.25872546434402466, "0": 0.17200981080532074]),
            column: "ZACTIONSCONFIDENCE", table: "ZHUMANACTIONCLASSIFICATIONRESULT", taxonomy: taxonomy))
        XCTAssertEqual(decoded.actionProbabilities.map(\.name), ["clapping", "walking", "none"])
        XCTAssertEqual(decoded.actionProbabilities.map(\.percentage), ["44.9%", "25.9%", "17.2%"])
        XCTAssertEqual(decoded.actionProbabilities.first?.score, 0.44858646392822266)
        let fields = ["Z_PK": "1", "ZX": "0.1", "ZY": "0.1", "ZWIDTH": "0.2", "ZHEIGHT": "0.5"]
        let row = DBRow(id: 0, fields: fields, decoded: ["ZACTIONSCONFIDENCE": decoded])
        let region = try XCTUnwrap(VisualMetadata.regions(ResultFamily(table: TableSchema(name: "ZHUMANACTIONCLASSIFICATIONRESULT", columns: [:]), count: 1, rows: [row])).first)
        XCTAssertEqual(region.overlayLabel(focused: true), "Action classification #1\nclapping 44.9%\nwalking 25.9%\nnone 17.2%")
        XCTAssertEqual(region.overlayLabel(focused: false), "Action classification #1")
        XCTAssertEqual(VisualMetadata.explainedFields(row, table: region.table)["Top stored action scores"], "clapping 44.9%; walking 25.9%; none 17.2%")
    }
    func testSensitivityScoreArchiveUsesItsOwnLabelsAndPreservesUnknownIDs() throws {
        let decoded = try XCTUnwrap(AnalysisPayload.decode(try archive(["2147481853": 0.004638671875, "2147481854": 0.0009765625,
            "2147481342": 1.25, "2147481343": -0.25, "881": 0.5]), column: "ZSENSITIVITYSCENERESULTS", table: "ZSAFETYRESULT", taxonomy: taxonomy))
        XCTAssertEqual(decoded.fields["NSFW any · ID 2147481853"], "0.004638671875")
        XCTAssertEqual(decoded.fields["NSFW explicit · ID 2147481854"], "0.0009765625")
        XCTAssertEqual(decoded.fields["SafetyNet Lite gore · ID 2147481342"], "1.25")
        XCTAssertEqual(decoded.fields["SafetyNet Lite violence · ID 2147481343"], "-0.25")
        XCTAssertEqual(decoded.fields["ID 881 (unresolved)"], "0.5")
        XCTAssertTrue(decoded.actionProbabilities.isEmpty)
        XCTAssertTrue(decoded.fields["Label evidence"]!.contains("26A434"))
        XCTAssertTrue(decoded.fields["Score interpretation"]!.contains("probability calibration unverified"))
        let fields = VisualMetadata.explainedFields(DBRow(id: 0, fields: ["ZSENSITIVITY": "0"]), table: "ZSAFETYRESULT")
        XCTAssertEqual(fields["ZSENSITIVITY"], "0")
        XCTAssertEqual(fields["Sensitivity label evidence"], decoded.fields["Label evidence"])
        XCTAssertNil(fields["Safety category limitation"])
    }
    func testActionProbabilitiesHandleTiesAndUnknownIDsWithoutDisplayingInvalidValues() throws {
        let decoded = try XCTUnwrap(AnalysisPayload.decode(try archive(["99": 0.2, "3": 0.2, "0": 0.3, "10": -0.1, "11": 1.1]),
            column: "ZACTIONSCONFIDENCE", table: "ZHUMANACTIONCLASSIFICATIONRESULT", taxonomy: taxonomy))
        XCTAssertEqual(decoded.actionProbabilities.map(\.id), ["0", "3", "99"])
        XCTAssertEqual(decoded.actionProbabilities.last?.displayText, "Action 99 20.0%")
        XCTAssertEqual(Double(try XCTUnwrap(decoded.fields["ID 10 (unresolved)"])), -0.1)
        XCTAssertEqual(Double(try XCTUnwrap(decoded.fields["ID 11 (unresolved)"])), 1.1)
    }
    func testArchivedBoundsAndKeyframeFacesBecomeTimedRegions() throws {
        let bounds = try archive(["{{0.2, 0.3}, {0.4, 0.5}}", "{{20,30},{40,50}}", "not a rectangle"])
        let decoded = try XCTUnwrap(AnalysisPayload.decode(bounds, column: "ZOBJECTBOUNDS", table: "ZMOVINGOBJECTRESULT"))
        XCTAssertEqual(decoded.rectangles.count, 1)
        let fields = ["Z_PK":"7", "ZTIMESTAMPVALUE":"1200", "ZTIMESTAMPSCALE":"600"]
        let row = DBRow(id: 0, fields: fields, decoded: ["ZOBJECTBOUNDS": decoded])
        let family = ResultFamily(table: TableSchema(name: "ZKEYFRAMERESULT", columns: [:]), count: 1, rows: [row])
        let region = try XCTUnwrap(VisualMetadata.regions(family).first)
        XCTAssertEqual(region.start, 2); XCTAssertEqual(region.rectangle.width, 0.4)
        XCTAssertFalse(region.visible(at: 3))
        let faces = try archive([["attributes": ["faceBounds": "{{0.1,0.2},{0.3,0.4}}", "faceQuality": -1.0]]])
        let face = try XCTUnwrap(AnalysisPayload.decode(faces, column: "ZFACERESULTS", table: "ZKEYFRAMERESULT"))
        XCTAssertEqual(face.rectangles.count, 1)
        XCTAssertEqual(face.rectangles[0].fields["faceQuality"], "-1")
    }
    func testPrivateArchiveClassIsReadAsDataNotInstantiated() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$version":100000,
            "$top": ["facePrint": ["CF$UID": 1]], "$objects": ["$null", ["$class":["CF$UID":2], "elementCount":128, "descriptorByteLength":512], ["$classname":"ClassThatMustNeverBeLoaded"]]], format: .binary, options: 0)
        let value = try XCTUnwrap(AnalysisPayload.decode(data, column: "ZFACEPRINT", table: "ZFACEPRINTRESULT"))
        XCTAssertEqual(value.fields["$archiveClass"], "ClassThatMustNeverBeLoaded")
        XCTAssertEqual(value.fields["elementCount"], "128")
    }
    func testInvalidCyclicAndOversizedPayloadsRemainOpaque() throws {
        let cycle = try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$top": ["root": ["CF$UID":1]], "$objects":["$null", ["NS.objects":[["CF$UID":1]]]]], format: .binary, options: 0)
        XCTAssertNil(AnalysisPayload.decode(cycle, column: "ZOBJECTBOUNDS", table: "ZMOVINGOBJECTRESULT"))
        XCTAssertNil(AnalysisPayload.decode(Data(repeating: 0, count: 65537), column: "ZOBJECTBOUNDS", table: "ZMOVINGOBJECTRESULT"))
        XCTAssertNil(AnalysisPayload.decode(Data("invalid".utf8), column: "ZFACERESULTS", table: "ZKEYFRAMERESULT"))
        XCTAssertNil(AnalysisPayload.decode(try archive(["secret":"x"]), column: "ZSANDBOXTOKEN", table: "ZKEYFRAMERESULT"))
    }
    func testEmbeddingLayoutIsBoundedAndExplicitlyInferred() throws {
        var bytes = Data(repeating: 0, count: 1024); bytes[1] = 0x3c // Float16(1), rest zero.
        let value = try XCTUnwrap(AnalysisPayload.decode(bytes, column: "ZEMBEDDINGDATA", table: "ZVIDEOEMBEDDINGRESULT"))
        XCTAssertEqual(value.fields["L2 norm"], "1.000000")
        XCTAssertTrue(value.summary.contains("Candidate"))
        bytes[1] = 0x7c // Infinity.
        XCTAssertNil(AnalysisPayload.decode(bytes, column: "ZEMBEDDINGDATA", table: "ZVIDEOEMBEDDINGRESULT"))
        XCTAssertNil(AnalysisPayload.decode(Data(repeating: 0, count: 1024), column: "ZEMBEDDINGDATA", table: "ZVIDEOEMBEDDINGRESULT"))
    }
    func testTaxonomyUsesExplicitIDsAndFlagsRemainUnresolved() {
        let fields = VisualMetadata.explainedFields(DBRow(id: 0, fields: ["ZSCENEID":"881", "ZFLAGS":"10", "ZSTARTTIMEVALUE":"149521", "ZSTARTTIMESCALE":"16000"]), table: "ZCLASSIFICATIONRESULT", taxonomy: taxonomy)
        XCTAssertEqual(fields["ZSCENEID"], "881")
        XCTAssertEqual(fields["Scene label · installed taxonomy"], "People")
        XCTAssertEqual(Double(fields["Time · seconds"]!)!, 149521.0 / 16000, accuracy: 0.000001)
        XCTAssertTrue(fields["Flag structure · meanings unresolved"]!.contains("1, 3"))
        let ambiguous = AnalysisTaxonomy(identifiers: ["a":1,"b":1], labels: [:], actions: [])
        XCTAssertNil(ambiguous.scenes[1])
    }
    func testRecoveredAnalysisTypesPreserveUnknownBitsAndFlagNamespaces() {
        let mask: UInt64 = (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7) | (1 << 45) | (1 << 63)
        let fields = VisualMetadata.explainedFields(DBRow(id: 0, fields: ["ZANALYSISTYPES": String(Int64(bitPattern: mask)), "ZFLAGS": "8"]), table: "ZASSET")
        let names = fields["Analysis types"]!
        XCTAssertTrue(names.contains("Full Face · bit 3")); XCTAssertFalse(names.contains("Face · bit 2"))
        XCTAssertTrue(names.contains("Full Scene · bit 7")); XCTAssertFalse(names.contains("Scene · bit 6"))
        XCTAssertTrue(names.contains("Video Caption · bit 45"))
        XCTAssertEqual(fields["Unknown analysis type bits"], "63")
        XCTAssertTrue(fields["Flag structure · meanings unresolved"]!.contains("set bits 3"))
        XCTAssertEqual(fields["ZANALYSISTYPES"], String(Int64(bitPattern: mask)))
        XCTAssertTrue(fields["Analysis type interpretation"]!.contains("does not prove"))
    }
    func testCapturedLandingClipDecodingAndAllClassificationPages() throws {
        guard let path = ProcessInfo.processInfo.environment["MAE_RESEARCH_DATABASE"] else { throw XCTSkip("Set MAE_RESEARCH_DATABASE to a sanitized capture for integration validation.") }
        let url = URL(fileURLWithPath: path)
        let originalHash = SHA256.hash(data: try Data(contentsOf: url))
        let source = SourceConfiguration(analysisPath: path)
        let asset = MediaAsset(id: "5", identifier: "CF715438-C5AE-4792-9F2D-E70FC1502048/L0/001", fields: [:])
        let budget = WorkBudget(seconds: 15)
        var detail = try LibraryReader.detail(asset: asset, source: source, budget: budget)
        XCTAssertEqual(detail.families.reduce(0) { $0 + $1.count }, 761)
        let action = try XCTUnwrap(detail.families.first { $0.id == "ZHUMANACTIONCLASSIFICATIONRESULT" }?.rows.first?.decoded["ZACTIONSCONFIDENCE"])
        XCTAssertNotNil(action.fields["clapping · ID 3"])
        let sensitivity = try XCTUnwrap(detail.families.first { $0.id == "ZSAFETYRESULT" }?.rows.first?.decoded["ZSENSITIVITYSCENERESULTS"])
        XCTAssertEqual(sensitivity.fields["NSFW any · ID 2147481853"], "0.004638671875")
        XCTAssertEqual(sensitivity.fields["NSFW explicit · ID 2147481854"], "0.0009765625")
        let face = try XCTUnwrap(detail.families.first { $0.id == "ZFACEPRINTRESULT" }?.rows.first?.decoded["ZFACEPRINT"])
        XCTAssertEqual(face.fields["elementCount"], "128")
        XCTAssertEqual(face.fields["descriptorByteLength"], "512")
        XCTAssertEqual(face.fields["$archiveClass"], "VNFaceprint")
        let motion = try XCTUnwrap(detail.families.first { $0.id == "ZMOVINGOBJECTRESULT" })
        XCTAssertFalse(VisualMetadata.regions(motion).isEmpty)
        let frames = try XCTUnwrap(detail.families.first { $0.id == "ZKEYFRAMERESULT" })
        XCTAssertFalse(VisualMetadata.regions(frames).isEmpty)
        let embedding = try XCTUnwrap(detail.families.first { $0.id == "ZVIDEOEMBEDDINGRESULT" }?.rows.first?.decoded["ZEMBEDDINGDATA"])
        XCTAssertEqual(embedding.fields["Components"], "512")
        let db = try ReadDatabase(path: path, budget: budget)
        while let family = detail.families.first(where: { $0.id == "ZCLASSIFICATIONRESULT" }), family.rows.count < family.count {
            let rows = try db.analysisRows(table: family.table, offset: family.rows.count, assetKey: "5")
            XCTAssertFalse(rows.isEmpty)
            if rows.isEmpty { break }
            detail = detail.appending(rows, to: family.id)
        }
        let classification = try XCTUnwrap(detail.families.first { $0.id == "ZCLASSIFICATIONRESULT" })
        XCTAssertEqual(classification.rows.count, 214)
        XCTAssertEqual(Set(classification.rows.map(\.id)).count, 214)
        XCTAssertTrue(classification.rows.contains { VisualMetadata.explainedFields($0, table: classification.id)["Scene label · installed taxonomy"] == "People" })
        XCTAssertEqual(Array(SHA256.hash(data: try Data(contentsOf: url))), Array(originalHash))
    }
}
