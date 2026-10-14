import XCTest
import Foundation
@testable import ExplorerCore

/// Protocol/adapter checks only: these never load MediaAnalysis or run a model.
final class LocalAnalysisTests: XCTestCase {
    private func value(_ json: String) throws -> AnalysisValue {
        try JSONDecoder().decode(AnalysisValue.self, from: Data(json.utf8))
    }
    func testPartialAndUnknownFamiliesRetainEvidenceAndPassProvenance() throws {
        let raw = try value(#"{"status":-18,"completedAnalysis":null,"partialAnalysis":{"metadataRanges":{"FutureResults":{"count":700,"items":[{"attributes":{"unresolved":"evidence"}}],"truncated":1}}},"completionReceived":true}"#)
        let passes = LocalAnalysisPass.passes(video: true)
        let first = LocalAnalysisReport(pass: passes[0], raw: raw), second = LocalAnalysisReport(pass: passes[1], raw: raw)
        XCTAssertFalse(first.succeeded)
        XCTAssertNotNil(first.failure)
        let family = try XCTUnwrap(first.families.first)
        XCTAssertEqual(family.count, 700)
        XCTAssertEqual(family.rows.count, 1)
        XCTAssertTrue(family.evidence.isTruncated)
        XCTAssertEqual(family.rows[0]["attributes"]["unresolved"].text, "evidence")
        XCTAssertNotEqual(family.id, second.families.first?.id)
        XCTAssertTrue(LocalAnalysisDisplay.families(first).flatMap(VisualMetadata.regions).isEmpty)
    }
    func testPreanalysisUsesItsFlatResultContainer() throws {
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"ClassificationResults":{"count":1,"items":[{"attributes":{"sceneClassification":{"123":{"Confidence":0.9}}}}]}}}"#)
        let pass = try XCTUnwrap(LocalAnalysisPass.passes(video: false).first { $0.kind == "preanalysis" })
        let report = LocalAnalysisReport(pass: pass, raw: raw)
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.families.first?.rows.first?["attributes"]["sceneClassification"]["123"]["Confidence"].double, 0.9)
    }
    func testInvalidTimesAndOutOfRangeGeometryDoNotBecomeOverlays() throws {
        let time = try value(#"{"value":73728,"timescale":12288,"flags":1,"epoch":0}"#)
        XCTAssertEqual(time.seconds, 6)
        for flags in [0,5,9,17] {
            XCTAssertNil(try value("{\"value\":1,\"timescale\":600,\"flags\":\(flags)}").seconds)
        }
        XCTAssertNil(try value(#"{"value":600,"timescale":0,"flags":1}"#).seconds)
        XCTAssertNil(AnalysisValue.string("{{0.8,0.2},{0.3,0.5}}").normalizedRectangle)
        XCTAssertNil(AnalysisValue.string("random 0.1,0.2,0.3,0.4").normalizedRectangle)
        XCTAssertNotNil(AnalysisValue.string("{{0.1, 0.2}, {0.3, 0.4}}").normalizedRectangle)
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"HumanPoseResults":{"count":1,"items":[{"attributes":{"humanBounds":"{{0.1, 0.2}, {0.3, 0.4}}","humanConfidence":0.8},"start":{"value":73728,"timescale":12288,"flags":1},"duration":{"value":12288,"timescale":12288,"flags":1}}]}}}}"#)
        let report = LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: true)[0], raw: raw)
        let timeline = RegionTimeline(regions: LocalAnalysisDisplay.families(report).flatMap(VisualMetadata.regions))
        XCTAssertEqual(timeline.visible(at: 6).count, 1)
        XCTAssertTrue(timeline.visible(at: 7).isEmpty)
    }
    func testWorkerEventsPreserveLargeIntegerMasksAndRejectForeignMessages() throws {
        let event = try LocalAnalysisReport.decodeEvent(Data(#"{"event":"result","report":{"performedAnalysisTypes":562949953421321}}"#.utf8))
        XCTAssertEqual(event["report"]["performedAnalysisTypes"].integer, 562949953421321)
        XCTAssertThrowsError(try LocalAnalysisReport.decodeEvent(Data(#"{"event":"log"}"#.utf8)))
        XCTAssertThrowsError(try LocalAnalysisReport.decodeEvent(Data(repeating: 32, count: 16 * 1024 * 1024 + 1)))
        XCTAssertTrue(LocalAnalysisPass.passes(video: false).allSatisfy { $0.kind == "preanalysis" || $0.mask != 0 })
        XCTAssertTrue(LocalAnalysisPass.passes(video: true).allSatisfy { $0.mask != 0 })
    }
    func testNativeCaptionsUseSharedDisplayRecordsWithoutPhotosKeys() throws {
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"VideoSegmentCaptionResults":{"count":1,"items":[{"attributes":{"videoCaptionText":"A person waves.","videoCaptionConfidence":0.8},"start":{"value":600,"timescale":600,"flags":1},"duration":{"value":1200,"timescale":600,"flags":1}}]}}}}"#)
        let report = LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: true)[1], raw: raw)
        let family = try XCTUnwrap(LocalAnalysisDisplay.families(report).first)
        XCTAssertEqual(family.id, "ZVIDEOSEGMENTCAPTIONRESULT")
        let row = try XCTUnwrap(family.rows.first)
        XCTAssertNil(row.fields["Z_PK"])
        XCTAssertNil(row.fields["ZASSET"])
        XCTAssertEqual(row["ZCAPTION"], "A person waves.")
        XCTAssertEqual(row.fieldOrigins["ZCAPTION"], "attributes.videoCaptionText")
        XCTAssertEqual(row.nativeEvidence?["attributes"]["videoCaptionText"].text, "A person waves.")
        let playback = PlaybackTimeline(families: [family])
        XCTAssertEqual(playback.active(at: 1).first?.caption, "A person waves.")
        XCTAssertTrue(playback.active(at: 3).isEmpty)
    }
    func testPreanalysisScenesAndAestheticsUseSharedMetadataControls() throws {
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"ClassificationResults":{"count":1,"items":[{"attributes":{"sceneClassification":{"123":{"Confidence":0.9},"456":{"Confidence":0.2}},"aesthetic":{"overallScore":0.7}}}]}}}"#)
        let pass = LocalAnalysisPass.passes(video: false)[1]
        let families = LocalAnalysisDisplay.families(LocalAnalysisReport(pass: pass, raw: raw))
        XCTAssertEqual(families.first?.id, "ZCLASSIFICATIONRESULT")
        XCTAssertEqual(families.first?.rows.count, 2)
        XCTAssertEqual(families.first?.rows.first?["ZSCENEID"], "123")
        XCTAssertEqual(families.last?.rows.first?["overallScore"], "0.7")
        XCTAssertEqual(families.last?.rows.first?.fieldOrigins["overallScore"], "attributes.aesthetic.overallScore")
    }
    func testEmptyNativeCollectionsNeverCreateDisplayRecords() throws {
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"FaceResults":{"count":0,"items":[],"truncated":false}}}}"#)
        let report = LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: false)[0], raw: raw)
        let family = try XCTUnwrap(LocalAnalysisDisplay.families(report).first)
        XCTAssertEqual(family.count, 0)
        XCTAssertTrue(family.rows.isEmpty)
        XCTAssertTrue(VisualMetadata.regions(family).isEmpty)
    }
    func testAllReportsShareOneBrowserWithoutLosingVariantsOrSources() throws {
        let first = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"ExposureResults":{"count":1,"items":[{"quality":0.8}]},"HumanPoseResults":{"count":1,"items":[{"attributes":{"humanBounds":"{{0.1,0.2},{0.3,0.4}}"}}]}}}}"#)
        let pre = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"ExposureResults":{"count":1,"items":[{"quality":0.8}]},"ClassificationResults":{"count":1,"items":[{"attributes":{"sceneClassification":{"123":{"Confidence":0.9}}}}]}}}"#)
        let caption = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"ExposureResults":{"count":1,"items":[{"quality":0.7}]},"MiCaImageCaptionResults":{"count":1,"items":[{"attributes":{"imageCaptionText":"A scene."}}]}}}}"#)
        let passes = LocalAnalysisPass.passes(video: false)
        let initial = LocalAnalysisDisplay.families([LocalAnalysisReport(pass: passes[0], raw: first)])
        let merged = LocalAnalysisDisplay.families(zip(passes, [first, pre, caption]).map { LocalAnalysisReport(pass: $0.0, raw: $0.1) })
        XCTAssertEqual(Set(merged.map(\.id)), ["ZEXPOSURERESULT", "ZHUMANPOSERESULT", "ZCLASSIFICATIONRESULT", "ZIMAGECAPTIONRESULT"])
        let exposure = try XCTUnwrap(merged.first { $0.id == "ZEXPOSURERESULT" })
        XCTAssertEqual(exposure.rows.count, 2)
        XCTAssertEqual(exposure.rows.map { $0["ZEXPOSURE"] }, ["0.8", "0.7"])
        XCTAssertEqual(exposure.rows[0].analysisSources, [passes[0].title, passes[1].title])
        XCTAssertEqual(Set(exposure.rows.map(\.id)).count, 2)
        XCTAssertEqual(initial.first { $0.id == "ZEXPOSURERESULT" }?.rows.first?.id, exposure.rows.first?.id)
        XCTAssertEqual(merged.flatMap(VisualMetadata.regions).count, 1)
        XCTAssertTrue(exposure.rows.allSatisfy { $0.fields["Z_PK"] == nil })
    }
    func testNativeSensitivityUsesThePhotosScoreDecoder() throws {
        let raw = try value(#"{"status":0,"completionReceived":true,"completedAnalysis":{"metadataRanges":{"SafetyResults":{"count":1,"items":[{"attributes":{"Sensitivity":0,"SensitivitySceneResults":{"2147481853":0.020751953125,"2147481854":0.015380859375,"999":0.25}},"start":{"value":0,"timescale":600,"flags":1},"duration":{"value":600,"timescale":600,"flags":1}}]}}}}"#)
        let family = try XCTUnwrap(LocalAnalysisDisplay.families([LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: true)[0], raw: raw)]).first)
        XCTAssertEqual(family.id, "ZSAFETYRESULT")
        let row = try XCTUnwrap(family.rows.first)
        let native = try XCTUnwrap(row.decoded["ZSENSITIVITYSCENERESULTS"])
        let scores = ["2147481853": 0.020751953125, "2147481854": 0.015380859375, "999": 0.25]
        let archive = try PropertyListSerialization.data(fromPropertyList: scores, format: .binary, options: 0)
        let stored = try XCTUnwrap(AnalysisPayload.decode(archive, column: "ZSENSITIVITYSCENERESULTS", table: "ZSAFETYRESULT"))
        XCTAssertEqual(native.fields, stored.fields)
        XCTAssertEqual(native.fields["NSFW any · ID 2147481853"], "0.020751953125")
        XCTAssertEqual(native.fields["ID 999 (unresolved)"], "0.25")
        XCTAssertEqual(row.fieldOrigins["ZSENSITIVITYSCENERESULTS"], "attributes.SensitivitySceneResults")
        XCTAssertEqual(row.nativeEvidence?["attributes"]["SensitivitySceneResults"]["999"].double, 0.25)
    }
    func testTimedSummariesShowScoresOrientationAndNativeCollectionsWithoutDatabaseIDs() throws {
        let namesAndValues: [(String, String)] = [
            ("FineSubjectMotionResults", #""quality":0.38"#),
            ("InterestingnessResults", #""quality":0.94"#),
            ("OrientationResults", #""attributes":{"orientation":3}"#),
            ("SummarizedEmbeddingResults", #""attributes":{"embeddingIds":{"count":14,"items":[10,6],"truncated":true},"representativeMapping":{"count":15,"items":[0,1]}}"#),
            ("AudioFusedVideoEmbeddingResults", #""attributes":{"embeddings":{"class":"NSData","bytes":100000,"sha256":"evidence"}}"#),
            ("FutureResults", #""attributes":{"newScores":{"count":2,"items":[0.2,0.8]}}"#)
        ]
        for (name, data) in namesAndValues {
            let raw = try value("{\"status\":0,\"completionReceived\":true,\"completedAnalysis\":{\"metadataRanges\":{\"\(name)\":{\"count\":1,\"items\":[{\(data),\"start\":{\"value\":0,\"timescale\":600,\"flags\":1},\"duration\":{\"value\":600,\"timescale\":600,\"flags\":1}}]}}}}")
            let snapshot = LocalAnalysisPresentation(reports: [LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: true)[0], raw: raw)])
            let record = try XCTUnwrap(snapshot.playbackTimeline.active(at: 0.5).first)
            XCTAssertFalse(record.summary.contains("NULL"), name)
            XCTAssertFalse(record.summary.contains("Native result #"), name)
            XCTAssertEqual(record.row.nativeEvidence?["start"]["value"].integer, 0)
            switch name {
            case "FineSubjectMotionResults": XCTAssertTrue(record.summary.contains("0.38"))
            case "InterestingnessResults": XCTAssertTrue(record.summary.contains("0.94"))
            case "OrientationResults": XCTAssertTrue(record.summary.contains("3"))
            case "SummarizedEmbeddingResults":
                XCTAssertTrue(record.summary.contains("14 items · truncated"))
                XCTAssertTrue(record.summary.contains("15 items"))
                XCTAssertEqual(record.row.fieldOrigins["ZEMBEDDINGIDS"], "attributes.embeddingIds")
            case "AudioFusedVideoEmbeddingResults": XCTAssertTrue(record.summary.contains("100000 bytes"))
            default: XCTAssertTrue(record.summary.contains("2 items"))
            }
        }
        let stored = DBRow(id: 7, fields: ["Z_PK": "42", "ZORIENTATION": "3", "ZCONFIDENCE": "NULL"])
        XCTAssertTrue(TimedResult.summarize(stored, fields: VisualMetadata.explainedFields(stored, table: "ZORIENTATIONRESULT")).contains("3"))
        XCTAssertEqual(TimedResult.summarize(DBRow(id: 7, fields: [:]), fields: [:]), "Stored record 7 · no summary values available")
    }

    func testPreparedTimelinesStayStableAcrossRepeatedHoverAndBackwardSeeks() throws {
        func time(_ seconds: Int) -> AnalysisValue { .object(["value": .integer(Int64(seconds * 600)), "timescale": .integer(600), "flags": .integer(1)]) }
        let rows = (0..<500).map { i in AnalysisValue.object([
            "start": time(i), "duration": time(1), "quality": .number(Double(i) / 500)
        ]) }
        let regions = rows.map { row -> AnalysisValue in
            var fields = row.object
            fields["attributes"] = .object(["humanBounds": .string("{{0.1,0.2},{0.3,0.4}}")])
            return .object(fields)
        }
        let raw = AnalysisValue.object(["completedAnalysis": .object(["metadataRanges": .object([
            "ActivityLevelResults": .object(["count": .integer(500), "items": .array(rows)]),
            "HumanPoseResults": .object(["count": .integer(500), "items": .array(regions)])
        ])])])
        let report = LocalAnalysisReport(pass: LocalAnalysisPass.passes(video: true)[0], raw: raw)
        let snapshot = LocalAnalysisPresentation(reports: [report])
        let revision = snapshot.playbackTimeline.revision
        for i in (0..<1000) {
            let seconds = Double((i * 137) % 500) + 0.5
            let copy = snapshot
            XCTAssertEqual(copy.playbackTimeline.revision, revision)
            XCTAssertEqual(copy.playbackTimeline.active(at: seconds).map(\.start), [floor(seconds)])
            let visible = copy.regionTimeline.visible(at: seconds)
            XCTAssertEqual(visible.count, 1)
            let region = try XCTUnwrap(visible.first)
            XCTAssertEqual(copy.regionTimeline.regionsByID[region.id]?.start, floor(seconds))
        }
        XCTAssertEqual(snapshot.regionTimeline.regionsByTable["ZHUMANPOSERESULT"]?.count, 500)
        XCTAssertEqual(snapshot.regionTimeline.orderedRegions.first?.start, 0)
        XCTAssertNotEqual(LocalAnalysisPresentation(reports: [report]).playbackTimeline.revision, revision)
    }
}
