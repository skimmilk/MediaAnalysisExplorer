import XCTest
import Foundation
import CSQLite
@testable import ExplorerCore

final class PlaybackTimelineTests: XCTestCase {
    private func family(_ name: String, _ fields: [[String: String]]) -> ResultFamily {
        ResultFamily(table: TableSchema(name: name, columns: [:]), count: fields.count,
                     rows: fields.enumerated().map { DBRow(id: $0.offset, fields: $0.element) })
    }
    private func interval(_ id: String, _ start: Int, _ duration: Int) -> [String: String] {
        ["Z_PK": id, "ZSTARTTIMEVALUE": String(start), "ZSTARTTIMESCALE": "600",
         "ZDURATIONTIMEVALUE": String(duration), "ZDURATIONTIMESCALE": "600"]
    }
    func testCaptionAndAudioIntervalsFollowBoundariesAndBackwardSeeks() {
        var caption = interval("1", 600, 1200); caption["ZCAPTION"] = "People applaud."
        let timeline = PlaybackTimeline(families: [family("ZVIDEOSEGMENTCAPTIONRESULT", [caption, interval("2", 1200, 600)]),
                                                  family("ZAPPLAUSERESULT", [interval("1", 1200, 1200)])])
        XCTAssertEqual(timeline.active(at: 1).first?.caption, "People applaud.")
        XCTAssertEqual(timeline.active(at: 2).filter { $0.kind == .caption }.count, 2)
        XCTAssertEqual(timeline.active(at: 2).filter { $0.kind == .audio }.map(\.title), ["Applause"])
        XCTAssertEqual(timeline.active(at: 3).map(\.kind), [.audio])
        XCTAssertTrue(timeline.active(at: 4).isEmpty)
        for second in [0.0, 1, 2, 3, 4, 2.5, 1.5, 0, 3.99] {
            XCTAssertEqual(timeline.active(at: second).map(\.id), timeline.records.filter { $0.active(at: second) }.map(\.id))
        }
        XCTAssertTrue(timeline.active(at: .nan).isEmpty)
        XCTAssertTrue(timeline.active(at: .infinity).isEmpty)
    }
    func testUntimedInvalidAndSpatialRowsDoNotBecomeAudioOrCaptionIntervals() {
        var spatial = interval("1", 0, 600)
        spatial.merge(["ZX": "0.1", "ZY": "0.1", "ZWIDTH": "0.2", "ZHEIGHT": "0.2"]) { _, new in new }
        var invalid = interval("2", 0, 600); invalid["ZSTARTTIMESCALE"] = "0"
        let point = ["Z_PK": "3", "ZTIMESTAMPVALUE": "1200", "ZTIMESTAMPSCALE": "600"]
        let timeline = PlaybackTimeline(families: [family("ZHUMANPOSERESULT", [spatial]),
            family("ZVIDEOCAPTIONRESULT", [["Z_PK": "1", "ZCAPTION": "Whole video"]]),
            family("ZBABBLERESULT", [invalid, point])])
        XCTAssertEqual(timeline.records.count, 1)
        XCTAssertEqual(timeline.active(at: 2).first?.title, "Babble")
        XCTAssertTrue(timeline.active(at: 1.8).isEmpty)
        XCTAssertTrue(timeline.active(at: 2.2).isEmpty)
        XCTAssertTrue(PlaybackTimeline(families: [family("ZBABBLERESULT", [point])], excludingSpatial: ["ZBABBLERESULT:3"]).records.isEmpty)
    }
    func testGroupedScenesPreserveOverlappingIntervalsAndWatchGaps() throws {
        var first = interval("1", 0, 1200); first["ZCONFIDENCE"] = "0.2"
        var second = interval("2", 600, 1200); second["ZCONFIDENCE"] = "0.9"
        var third = interval("3", 600, 600); third["ZCONFIDENCE"] = "NaN"
        let timeline = PlaybackTimeline(families: [family("ZCLASSIFICATIONRESULT", [first, second, third]),
                                                   family("ZLOUDNESSRESULT", [interval("1", 0, 600)])])
        let watches = ["ZAPPLAUSERESULT", "ZCLASSIFICATIONRESULT"]
        let groups = TimedResultGroup.grouped(timeline.active(at: 1.5), watching: watches)
        XCTAssertEqual(groups.map(\.table), watches)
        XCTAssertTrue(groups[0].records.isEmpty)
        XCTAssertEqual(groups[1].records.map { $0.row["Z_PK"] }, ["2", "1", "3"])
        XCTAssertEqual(groups[1].records.map(\.duration), [2, 2, 1])
        XCTAssertEqual(TimedResultGroup.grouped(timeline.active(at: 2), watching: watches)[1].records.map { $0.row["Z_PK"] }, ["2"])
        XCTAssertTrue(TimedResultGroup.grouped(timeline.active(at: 3), watching: watches).allSatisfy { $0.records.isEmpty })
        XCTAssertEqual(TimedResultGroup.grouped(timeline.active(at: 0.5), watching: watches).map(\.table), watches + ["ZLOUDNESSRESULT"])
        XCTAssertEqual(TimedResultGroup.orderedClasses(watches + watches + ["../bad", "", "Zbad-table"]), watches)
        for time in [1.5, 3, 0.5, 2, 1.5] {
            let grouped = TimedResultGroup.grouped(timeline.active(at: time))
            XCTAssertEqual(Set(grouped.flatMap(\.records).map(\.id)), Set(timeline.active(at: time).map(\.id)))
            XCTAssertEqual(Set(grouped.map(\.table)).count, grouped.count)
        }
    }
    func testTimingReadIncludesLaterPagesAndPreservesIndexWhenMetadataIsAppended() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let inserts = (1...121).map { "INSERT INTO ZVIDEOSEGMENTCAPTIONRESULT VALUES (\($0),1,\($0 - 1),1,1,1,'Caption \($0)');" }.joined()
        let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
        CREATE TABLE ZVIDEOSEGMENTCAPTIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZSTARTTIMEVALUE INTEGER, ZSTARTTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZDURATIONTIMESCALE INTEGER, ZCAPTION TEXT);
        INSERT INTO ZASSET VALUES (1,'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001');
        \(inserts)
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let source = SourceConfiguration(analysisPath: url.path)
        let asset = MediaAsset(id: "1", identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001", fields: [:])
        let detail = try LibraryReader.detail(asset: asset, source: source, budget: WorkBudget(seconds: 10))
        XCTAssertEqual(detail.families.first?.rows.count, 100)
        XCTAssertEqual(detail.playbackTimeline.records.count, 121)
        XCTAssertEqual(detail.playbackTimeline.active(at: 120.5).first?.caption, "Caption 121")
        XCTAssertTrue(detail.playbackTimeline.issues.isEmpty)
        let table = try XCTUnwrap(detail.families.first?.table)
        let rest = try ReadDatabase(path: url.path).analysisRows(table: table, offset: 100, assetKey: "1")
        let updated = detail.appending(rest, to: table.name)
        XCTAssertEqual(updated.families.first?.rows.count, 121)
        XCTAssertEqual(updated.playbackTimeline.revision, detail.playbackTimeline.revision)
        XCTAssertEqual(updated.playbackTimeline.active(at: 120.5).first?.caption, "Caption 121")
    }
    func testCapturedLandingClipIncludesAllClassificationsAndActiveCaptionApplause() throws {
        guard let path = ProcessInfo.processInfo.environment["MAE_RESEARCH_DATABASE"] else { throw XCTSkip("Set MAE_RESEARCH_DATABASE for captured interval validation.") }
        let detail = try LibraryReader.detail(asset: MediaAsset(id: "5", identifier: "CF715438-C5AE-4792-9F2D-E70FC1502048/L0/001", fields: [:]),
                                              source: SourceConfiguration(analysisPath: path), budget: WorkBudget(seconds: 15))
        let timeline = detail.playbackTimeline
        XCTAssertTrue(timeline.issues.isEmpty, timeline.issues.joined(separator: "; "))
        XCTAssertEqual(timeline.records.filter { $0.table == "ZCLASSIFICATIONRESULT" }.count, 214)
        XCTAssertEqual(timeline.records.filter { $0.kind == .caption }.count, 18)
        XCTAssertTrue(timeline.active(at: 9.5).contains { $0.kind == .caption && $0.caption != nil })
        let applause = try XCTUnwrap(timeline.active(at: 9.5).first { $0.table == "ZAPPLAUSERESULT" })
        XCTAssertEqual(applause.start, 149521.0 / 16000, accuracy: 0.000001)
        XCTAssertEqual(applause.duration!, 4.8, accuracy: 0.000001)
        XCTAssertFalse(timeline.active(at: applause.end!).contains { $0.id == applause.id })
        XCTAssertFalse(timeline.active(at: 9).contains { $0.id == applause.id })
        XCTAssertTrue(timeline.active(at: 9.5).contains { $0.id == applause.id })
        let db = try ReadDatabase(path: path, budget: WorkBudget(seconds: 15))
        for key in ["2", "5", "6", "7"] {
            let identifier = try XCTUnwrap(db.query("SELECT ZLOCALIDENTIFIER FROM ZASSET WHERE Z_PK=?", parameters: [key]).first?["ZLOCALIDENTIFIER"])
            let video = try LibraryReader.detail(asset: MediaAsset(id: key, identifier: identifier, fields: [:]), source: SourceConfiguration(analysisPath: path), budget: WorkBudget(seconds: 15))
            for family in video.families where PlaybackTimeline.audioTables.contains(family.id) {
                let events = video.playbackTimeline.records.filter { $0.table == family.id }
                XCTAssertEqual(events.count, family.count, "\(key): \(family.id)")
                for event in events {
                    let inside = event.start + (event.duration ?? 0) / 2
                    XCTAssertTrue(video.playbackTimeline.active(at: inside).contains { $0.id == event.id })
                    if let end = event.end { XCTAssertFalse(video.playbackTimeline.active(at: end).contains { $0.id == event.id }) }
                }
            }
        }
    }
    func testActionOverlayProbabilitiesIncludeRecordsBeyondTheMetadataPage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
        CREATE TABLE ZHUMANACTIONCLASSIFICATIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZSTARTTIMEVALUE INTEGER, ZSTARTTIMESCALE INTEGER, ZDURATIONTIMEVALUE INTEGER, ZDURATIONTIMESCALE INTEGER, ZX FLOAT, ZY FLOAT, ZWIDTH FLOAT, ZHEIGHT FLOAT, ZACTIONSCONFIDENCE BLOB);
        INSERT INTO ZASSET VALUES (1,'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001');
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let payload = try NSKeyedArchiver.archivedData(withRootObject: ["3": 0.44858646392822266], requiringSecureCoding: true)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO ZHUMANACTIONCLASSIFICATIONRESULT VALUES (?,1,?,1,1,1,0.1,0.1,0.3,0.5,?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for id in 1...121 {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, Int32(id)); sqlite3_bind_int(statement, 2, Int32(id - 1))
            payload.withUnsafeBytes { bytes in _ = sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), transient) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        let detail = try LibraryReader.detail(asset: MediaAsset(id: "1", identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001", fields: [:]),
            source: SourceConfiguration(analysisPath: url.path), budget: WorkBudget(seconds: 10))
        XCTAssertEqual(detail.families.first?.rows.count, 100)
        XCTAssertEqual(detail.regionTimeline.regions.count, 121)
        let later = try XCTUnwrap(detail.regionTimeline.visible(at: 120.5).first)
        XCTAssertEqual(later.record, "121")
        XCTAssertEqual(later.actionProbabilities.first?.percentage, "44.9%")
        XCTAssertEqual(later.actionProbabilities.first?.score, 0.44858646392822266)
    }
}
