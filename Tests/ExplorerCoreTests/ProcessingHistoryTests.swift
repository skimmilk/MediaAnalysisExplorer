import XCTest
import CSQLite
@testable import ExplorerCore

final class ProcessingHistoryTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Chicago")!
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func stamp(_ text: String) -> String { String(date(text).timeIntervalSinceReferenceDate) }
    private func database(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ExplorerError(String(cString: sqlite3_errmsg(db))) }
    }
    func testCalendarBoundsMissingCountsSharedSchedulesAndFullHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos.sqlite"), daemon = root.appendingPathComponent("daemon.sqlite")
        let start = stamp("2026-10-03T00:00:00-05:00"), inside = stamp("2026-10-04T12:00:00-05:00"), end = stamp("2026-10-10T00:00:00-05:00")
        try database(photos, """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY,ZLOCALIDENTIFIER TEXT,ZDATEANALYZED TIMESTAMP);
        INSERT INTO ZASSET VALUES (1,'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001',\(start));
        INSERT INTO ZASSET VALUES (2,'BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001',\(inside));
        INSERT INTO ZASSET VALUES (3,'boundary',\(end)),(4,'unset',0),(5,'missing',NULL),(6,'old',\(Double(start)! - 1));
        CREATE TABLE ATRANSACTION (Z_PK INTEGER PRIMARY KEY,ZTIMESTAMP REAL);
        CREATE TABLE ACHANGE (ZTRANSACTIONID INTEGER,ZENTITY INTEGER);
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER,Z_NAME TEXT);
        INSERT INTO Z_PRIMARYKEY VALUES (1,'HumanPoseResult'),(2,'Asset');
        INSERT INTO ATRANSACTION VALUES (1,\(inside)),(2,\(end));
        \((0..<150).map { _ in "INSERT INTO ACHANGE VALUES (1,1);" }.joined())
        INSERT INTO ACHANGE VALUES (1,2),(2,1);
        """)
        let payloads = ["{\"NumberOfAssetsAnalyzed\":3}", "{\"NumberOfAssetsAnalyzed\":4}", "bad JSON", "{\"NumberOfAssetsAnalyzed\":true}", "{\"NumberOfAssetsAnalyzed\":1.5}", "{\"NumberOfAssetsAnalyzed\":-2}", "{}", "{\"NumberOfAssetsAnalyzed\":2.0}"]
        let rows = payloads.enumerated().map { "INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (\($0.offset+1),7,1,'\($0.element)');" }.joined()
        try database(daemon, """
        CREATE TABLE ZBACKGROUNDACTIVITYSCHEDULE (Z_PK INTEGER PRIMARY KEY,ZSTARTTIMESTAMP TIMESTAMP,ZEXITSTATUS INTEGER,ZDURATION REAL);
        CREATE TABLE ZBACKGROUNDACTIVITYSESSIONLOG (Z_PK INTEGER PRIMARY KEY,ZTASKID INTEGER,ZSCHEDULING INTEGER,ZPAYLOAD TEXT);
        INSERT INTO ZBACKGROUNDACTIVITYSCHEDULE VALUES (1,\(inside),9,10),(2,\(end),0,10);
        \(rows)
        \((10..<260).map { "INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (\($0),8,1,'{\"NumberOfAssetsAnalyzed\":1}');" }.joined())
        INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (300,7,999,'{}'),(301,7,2,'{\"NumberOfAssetsAnalyzed\":100}');
        """)
        let sources = [DaemonDatabase(name: "Photos analysis", purpose: "test", source: SourceConfiguration(analysisPath: photos.path)), DaemonDatabase(name: "Daemon activity", purpose: "test", source: SourceConfiguration(analysisPath: daemon.path))]
        let result = try ProcessingHistoryReader.read(databases: sources, range: .week, now: date("2026-10-09T20:00:00-05:00"), calendar: calendar, budget: WorkBudget(seconds: 10))
        XCTAssertTrue(result.issues.isEmpty, result.issues.joined(separator: "; "))
        XCTAssertEqual(result.start, date("2026-10-03T00:00:00-05:00")); XCTAssertEqual(result.buckets.count, 7)
        XCTAssertEqual(result.total(\.assets), 2)
        XCTAssertEqual(result.total(\.changes), 150)
        XCTAssertEqual(result.total(\.sessions), 258)
        XCTAssertEqual(result.total(\.reported), 259)
        XCTAssertEqual(result.reportingSessions, 253)
        XCTAssertEqual(result.undatedAssets, 2); XCTAssertEqual(result.undatedSessions, 1)
        XCTAssertEqual(result.recentAssets.map(\.id), ["2","1"])
        XCTAssertEqual(result.tasks.first?.sessions, 250)
        XCTAssertEqual(result.tasks.first?.nonzeroExits, 250)
        XCTAssertEqual(result.families.first?["entity"], "HumanPoseResult")
        XCTAssertEqual(result.buckets[0].assets, 1)
        XCTAssertEqual(result.buckets[1].reported, 259)
    }
    func testDSTAndAbsentStoresKeepUnknownMetrics() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let result = try ProcessingHistoryReader.read(databases: [DaemonDatabase(name: "Photos analysis", purpose: "test", source: SourceConfiguration(analysisPath: missing.path))], range: .week, now: date("2026-11-03T10:00:00-06:00"), calendar: calendar, budget: WorkBudget())
        XCTAssertEqual(result.buckets.count, 7)
        XCTAssertTrue(result.buckets.contains { $0.end.timeIntervalSince($0.start) == 25 * 3600 })
        XCTAssertNil(result.total(\.assets)); XCTAssertNil(result.total(\.sessions)); XCTAssertNil(result.total(\.changes)); XCTAssertFalse(result.issues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertThrowsError(try ProcessingHistoryReader.read(databases: [], range: .custom, now: date("2026-10-09T10:00:00-05:00"), customStart: date("2026-10-10T00:00:00-05:00"), customEnd: date("2026-10-09T00:00:00-05:00"), calendar: calendar, budget: WorkBudget()))
    }
    func testCapturedRangesAggregateRetainedDataWithoutPreviewLimits() throws {
        guard let path = ProcessInfo.processInfo.environment["MAE_RESEARCH_DATABASE"] else { throw XCTSkip("Set MAE_RESEARCH_DATABASE for actual retained history checks") }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let sources = DaemonDatabase.known(home: directory).enumerated().map { index, value in DaemonDatabase(name: value.name, purpose: value.purpose, source: SourceConfiguration(analysisPath: directory.appendingPathComponent("database-\(index).sqlite").path)) }
        let now = date("2026-10-09T23:00:00-05:00")
        let all = try ProcessingHistoryReader.read(databases: sources, range: .all, now: now, calendar: calendar, budget: WorkBudget(seconds: 15))
        XCTAssertTrue(all.issues.isEmpty, all.issues.joined(separator: "; "))
        XCTAssertEqual(all.total(\.assets), 14)
        XCTAssertGreaterThan(all.total(\.sessions) ?? 0, 100)
        XCTAssertGreaterThan(all.total(\.changes) ?? 0, 761)
        let db = try ReadDatabase(path: directory.appendingPathComponent("database-0.sqlite").path)
        let expected = Int(try db.query("SELECT count(*) AS n FROM ZBACKGROUNDACTIVITYSESSIONLOG l JOIN ZBACKGROUNDACTIVITYSCHEDULE s ON s.Z_PK=l.ZSCHEDULING WHERE s.ZSTARTTIMESTAMP>0 AND s.ZSTARTTIMESTAMP<?", parameters: [String(all.end.timeIntervalSinceReferenceDate)]).first!["n"])
        XCTAssertEqual(all.total(\.sessions), expected)
        for range in [ProcessingRange.week, .month, .quarter, .year] {
            let data = try ProcessingHistoryReader.read(databases: sources, range: range, now: now, calendar: calendar, budget: WorkBudget(seconds: 15))
            XCTAssertTrue(data.issues.isEmpty)
            XCTAssertLessThanOrEqual(data.total(\.assets)!, all.total(\.assets)!)
            XCTAssertLessThanOrEqual(data.total(\.sessions)!, all.total(\.sessions)!)
            XCTAssertEqual(data.buckets.last?.end, data.end)
            XCTAssertGreaterThan(data.buckets.count, 0)
        }
    }
}
