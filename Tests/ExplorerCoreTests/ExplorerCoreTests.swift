import XCTest
import Foundation
import CSQLite
@testable import ExplorerCore

final class ExplorerCoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func database(_ name: String, _ sql: String) throws -> String {
        let path = root.appendingPathComponent(name).path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ExplorerError(String(cString: sqlite3_errmsg(db))) }
        return path
    }
    private let uuid = "CF0826AB-90AE-478A-8188-B01F0065BFD7"

    func testPickerLookupBypassesPaginationAndPrefersFullIdentifier() throws {
        let path = try database("picker.sqlite", """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
            INSERT INTO ZASSET VALUES (1, '\(uuid)/L0/002'), (201, '\(uuid.lowercased())/L0/001');
            """)
        let source = SourceConfiguration(analysisPath: path, isFixture: true)
        let asset = try XCTUnwrap(LibraryReader.asset(identifier: uuid + "/L0/001", source: source, budget: WorkBudget()))
        XCTAssertEqual(asset.id, "201")
        XCTAssertEqual(asset.identifier, uuid.lowercased() + "/L0/001")
        XCTAssertThrowsError(try LibraryReader.asset(identifier: uuid, source: source, budget: WorkBudget()), "Ambiguous UUIDs must never choose an arbitrary record")
        XCTAssertNil(try LibraryReader.asset(identifier: UUID().uuidString + "/L0/001", source: source, budget: WorkBudget()))
        XCTAssertThrowsError(try LibraryReader.asset(identifier: "bad' OR 1=1--", source: source, budget: WorkBudget()))
    }

    func testPickerLookupSupportsUniqueUUIDLinkageAndCancellation() throws {
        let path = try database("picker-uuid.sqlite", """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
            INSERT INTO ZASSET VALUES (42, '\(uuid)');
            """)
        let source = SourceConfiguration(analysisPath: path, isFixture: true)
        XCTAssertEqual(try LibraryReader.asset(identifier: uuid.lowercased() + "/L0/001", source: source, budget: WorkBudget())?.id, "42")
        let budget = WorkBudget(); budget.cancel()
        XCTAssertThrowsError(try LibraryReader.asset(identifier: uuid, source: source, budget: budget))
    }

    func testPhotosGeographyCoordinatesAreValidatedAndOptional() throws {
        for (name, lat, lon, expected) in [("valid", "37.8199", "-122.4783", true), ("invalid", "999", "200", false), ("missing", "NULL", "NULL", false), ("sentinel", "0", "0", false)] {
            let path = try database(name + ".sqlite", "CREATE TABLE ZASSET (ZUUID TEXT,ZDIRECTORY TEXT,ZFILENAME TEXT,ZLATITUDE REAL,ZLONGITUDE REAL); INSERT INTO ZASSET VALUES ('\(uuid)','A','photo.jpg',\(lat),\(lon));")
            let media = try XCTUnwrap(LibraryReader.resolve(identifier: uuid, source: SourceConfiguration(analysisPath: path, photosPath: path), budget: WorkBudget()))
            XCTAssertEqual(media.location != nil, expected)
            if expected { XCTAssertEqual(media.location, GeoCoordinate(latitude: 37.8199, longitude: -122.4783)) }
        }
    }

    func testImportedCoverageSeparatesPendingAssetsFromStoredCaptionsAndRegions() throws {
        let path = try database("coverage.sqlite", """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
            CREATE TABLE ZIMAGECAPTIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZCAPTION TEXT, ZCONFIDENCE REAL);
            CREATE TABLE ZHUMANPOSERESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZX REAL, ZY REAL, ZWIDTH REAL, ZHEIGHT REAL);
            INSERT INTO ZASSET VALUES (1, '\(uuid)/L0/001');
            INSERT INTO ZIMAGECAPTIONRESULT VALUES (1, 1, 'A person beside a dog.', 0.8);
            INSERT INTO ZHUMANPOSERESULT VALUES (1, 1, 0.1, 0.2, 0.3, 0.4);
            """)
        let receipt = TestImportReceipt(albumIdentifier: "album", date: Date(), entries: [
            TestImportEntry(filename: "present.jpg", localIdentifier: uuid + "/L0/001"),
            TestImportEntry(filename: "pending.jpg", localIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001")])
        let result = try TestCoverageReader.read(receipt: receipt, source: SourceConfiguration(analysisPath: path), budget: WorkBudget())
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].captions, ["A person beside a dog."])
        XCTAssertEqual(result[0].regionCount, 1)
        XCTAssertEqual(result[0].tables["ZIMAGECAPTIONRESULT"], 1)
        XCTAssertNil(result[1].analysisKey)
        XCTAssertTrue(result[1].tables.isEmpty)
        XCTAssertTrue(result[1].note.contains("No analysis asset yet"))
    }

    func testDaemonSourcesDefaultToActualUserLevelDatabase() {
        let sources = DaemonDatabase.known(home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.first?.source.analysisPath, "/Users/example/Library/MediaAnalysis/MediaAnalysis.sqlite")
        XCTAssertTrue(sources.allSatisfy { $0.source.analysisPath.hasSuffix("MediaAnalysis.sqlite") && !$0.source.isFixture })
        XCTAssertEqual(sources[1].source.photosPath, "/Users/example/Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
    }

    func testStoredSessionJoinsCountsAndSharedSchedules() throws {
        let path = try database("daemon.sqlite", """
            CREATE TABLE ZBACKGROUNDACTIVITYSESSIONLOG (Z_PK INTEGER PRIMARY KEY, ZTASKID INTEGER, ZSCHEDULING INTEGER, ZPAYLOAD TEXT);
            CREATE TABLE ZBACKGROUNDACTIVITYSCHEDULE (Z_PK INTEGER PRIMARY KEY, ZDURATION REAL, ZEXITSTATUS INTEGER, ZSTARTTIMESTAMP REAL);
            CREATE TABLE ZMADREQUEST (Z_PK INTEGER PRIMARY KEY, ZREQUESTDATA BLOB);
            INSERT INTO ZBACKGROUNDACTIVITYSCHEDULE VALUES (7, 18.5, -128, 813265033.7);
            INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (1, 14, 7, '{"NumberOfAssetsAnalyzed":5}');
            INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (2, 13, 7, '{"NumberOfAssetsAnalyzed":15}');
            INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (3, 14, 99, '{"OtherField":"no count"}');
            INSERT INTO ZMADREQUEST VALUES (1, zeroblob(25));
            """)
        let report = try StoredDataReader.inspect(source: SourceConfiguration(analysisPath: path), budget: WorkBudget())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.tables.first { $0.id == "ZBACKGROUNDACTIVITYSESSIONLOG" }?.count, 3)
        XCTAssertEqual(report.tables.first { $0.id == "ZMADREQUEST" }?.blobBytes, 25)
        XCTAssertEqual(report.sessions.map(\.id), ["3", "2", "1"])
        XCTAssertNil(report.sessions[0].duration); XCTAssertNil(report.sessions[0].assetsAnalyzed)
        XCTAssertEqual(report.sessions[1].assetsAnalyzed, 15)
        XCTAssertEqual(report.sessions[1].scheduleID, "7")
        XCTAssertEqual(report.sessions[2].scheduleID, "7")
        XCTAssertEqual(report.sessions[1].exitStatus, "-128")
        XCTAssertEqual(report.taskCounts.first?["Task ID"], "14")
        XCTAssertEqual(report.taskCounts.first?["Stored sessions"], "2")
    }

    func testStoredOverviewWithMissingScheduleColumnsAndProcessingGroups() throws {
        let path = try database("analysis.sqlite", """
            CREATE TABLE ZBACKGROUNDACTIVITYSESSIONLOG (Z_PK INTEGER PRIMARY KEY, ZTASKID INTEGER, ZPAYLOAD TEXT);
            CREATE TABLE ZPROCESSINGSTATUS (ZTASKID INTEGER, ZSTATUS INTEGER, ZERRORCODE INTEGER, ZATTEMPTCOUNT INTEGER);
            CREATE TABLE ZCLASSIFICATIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZSCENEID INTEGER);
            INSERT INTO ZBACKGROUNDACTIVITYSESSIONLOG VALUES (1, 2, '{"NumberOfAssetsAnalyzed":0}');
            INSERT INTO ZPROCESSINGSTATUS VALUES (10, 4, -5, 2), (10, 4, -5, 9), (11, 6, 0, 1);
            """)
        let report = try StoredDataReader.inspect(source: SourceConfiguration(analysisPath: path), budget: WorkBudget())
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.sessions.first?.assetsAnalyzed, 0)
        XCTAssertNil(report.sessions.first?.scheduleID)
        XCTAssertEqual(report.processingGroups.first?["Stored records"], "2")
        XCTAssertEqual(report.processingGroups.first?["Maximum attempts"], "9")
        XCTAssertEqual(report.processingGroups.first?["Error code"], "-5")
        XCTAssertEqual(report.tables.first { $0.id == "ZCLASSIFICATIONRESULT" }?.count, 0)
    }

    func testPayloadCountsDoNotInventValues() {
        XCTAssertEqual(StoredDataReader.analyzedCount(payload: "{\"NumberOfAssetsAnalyzed\":62}"), 62)
        for value in ["true", "-1", "1.5", "null", "\"five\""] {
            XCTAssertNil(StoredDataReader.analyzedCount(payload: "{\"NumberOfAssetsAnalyzed\":\(value)}"))
        }
        XCTAssertNil(StoredDataReader.analyzedCount(payload: "malformed"))
        XCTAssertNil(StoredDataReader.analyzedCount(payload: "{}"))
    }

    func testPermissionFailuresAreDistinctFromMissingFolders() throws {
        let path = root.appendingPathComponent("Caches")
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        let denied = FileAccessFailure(error: error, url: path)
        XCTAssertTrue(denied.isPermissionDenied)
        XCTAssertEqual(denied.path, path.path)
        XCTAssertTrue(denied.detail.contains(NSPOSIXErrorDomain))
        let missing = FileAccessFailure(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), url: path)
        XCTAssertFalse(missing.isPermissionDenied)
        var updates: [InventoryUpdate] = []
        XCTAssertThrowsError(try Inventory.scan(root: path, budget: WorkBudget()) { updates.append($0) })
        XCTAssertTrue(updates.isEmpty, "A failed root must never emit a successful empty inventory")
    }

    func testNormalizationPreservesSuffixAndRejectsMalformedValues() {
        let full = uuid.lowercased() + "/L0/001"
        XCTAssertEqual(AssetIdentifier.uuid(full), uuid)
        XCTAssertEqual(full, uuid.lowercased() + "/L0/001")
        XCTAssertNil(AssetIdentifier.uuid("not-a-uuid/L0/001"))
        XCTAssertNil(AssetIdentifier.uuid("/" + uuid))
        XCTAssertNil(AssetIdentifier.uuid(" " + uuid))
    }

    func testPhotosJoinAndMissingOriginal() throws {
        let path = try database("photos.sqlite", """
            CREATE TABLE ZASSET (Z_PK INTEGER, ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT, ZADDITIONALATTRIBUTES INTEGER);
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER, ZORIGINALFILENAME TEXT);
            INSERT INTO ZASSET VALUES (42, '\(uuid.lowercased())', 'C', '\(uuid).png', 7);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (7, 'Screenshot.png');
            """)
        let config = SourceConfiguration(photosPath: path, libraryPath: root.path)
        let missing = try XCTUnwrap(LibraryReader.resolve(identifier: uuid + "/L0/001", source: config, budget: WorkBudget()))
        XCTAssertEqual(missing.originalName, "Screenshot.png"); XCTAssertNil(missing.originalURL)
        let folder = root.appendingPathComponent("originals/C")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent(uuid + ".png")
        try Data([1, 2, 3]).write(to: original)
        let found = try LibraryReader.resolve(identifier: uuid, source: config, budget: WorkBudget())
        XCTAssertEqual(found?.originalURL, original)
    }

    func testSchemaVariantsAndUnsafePaths() throws {
        let path = try database("photos.sqlite", """
            CREATE TABLE ZASSET (ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT);
            INSERT INTO ZASSET VALUES ('\(uuid)', '..', '../outside.png');
            """)
        let result = try XCTUnwrap(LibraryReader.resolve(identifier: uuid, source: SourceConfiguration(photosPath: path, libraryPath: root.path), budget: WorkBudget()))
        XCTAssertEqual(result.originalName, "../outside.png"); XCTAssertNil(result.originalURL)
        XCTAssertTrue(result.availability.contains("Unsafe"))
        let incompatible = try database("other.sqlite", "CREATE TABLE ZASSET (OTHER TEXT);")
        XCTAssertThrowsError(try LibraryReader.resolve(identifier: uuid, source: SourceConfiguration(photosPath: incompatible), budget: WorkBudget()))
    }

    func testAssetsFilenameSearchPagingAndActualResults() throws {
        let analysis = try database("analysis.sqlite", """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZLOCALIDENTIFIER TEXT);
            CREATE TABLE ZIMAGECAPTIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZCAPTION TEXT);
            CREATE TABLE ZCLASSIFICATIONRESULT (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZSCENEID INTEGER);
            INSERT INTO ZASSET VALUES (1, '\(uuid)/L0/001');
            INSERT INTO ZIMAGECAPTIONRESULT VALUES (1, 1, 'Synthetic test caption');
            INSERT INTO ZCLASSIFICATIONRESULT VALUES (1, 1, 12345);
            WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x < 104)
            INSERT INTO ZASSET SELECT x, 'synthetic-' || x FROM n;
            """)
        let photos = try database("photos.sqlite", """
            CREATE TABLE ZASSET (ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT, ZADDITIONALATTRIBUTES INTEGER);
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER, ZORIGINALFILENAME TEXT);
            INSERT INTO ZASSET VALUES ('\(uuid)', 'C', 'file.png', 7);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (7, 'Original screenshot.png');
            """)
        let config = SourceConfiguration(analysisPath: analysis, photosPath: photos)
        let first = try LibraryReader.assets(source: config, search: "", budget: WorkBudget())
        XCTAssertEqual(first.assets.count, 100); XCTAssertTrue(first.hasNext)
        let second = try LibraryReader.assets(source: config, search: "", after: 100, budget: WorkBudget())
        XCTAssertEqual(second.assets.count, 4); XCTAssertFalse(second.hasNext)
        let search = try LibraryReader.assets(source: config, search: "Original screenshot", budget: WorkBudget())
        XCTAssertEqual(search.assets.count, 1)
        let detail = try LibraryReader.detail(asset: search.assets[0], source: config, budget: WorkBudget())
        XCTAssertEqual(detail.families.count, 2)
        XCTAssertEqual(detail.families.first { $0.id == "ZCLASSIFICATIONRESULT" }?.rows.first?["ZSCENEID"], "12345")
        let escaped = try LibraryReader.assets(source: config, search: "%' OR 1=1 --", budget: WorkBudget())
        XCTAssertTrue(escaped.assets.isEmpty)
    }

    func testReadOnlyBLOBAndTokenHandling() throws {
        let path = try database("db.sqlite", "CREATE TABLE records (Z_PK INTEGER, data BLOB, ZSANDBOXTOKEN TEXT, text TEXT); INSERT INTO records VALUES (1, zeroblob(1000000), 'SECRET', 'hello');")
        let db = try ReadDatabase(path: path)
        XCTAssertThrowsError(try db.query("DELETE FROM records"))
        let table = try XCTUnwrap(db.schema().first)
        let row = try XCTUnwrap(db.rows(table: table).first)
        XCTAssertTrue(row["data"].contains("1000000 bytes")); XCTAssertNil(row.fields["ZSANDBOXTOKEN"])
        XCTAssertEqual(row["text"], "hello")
        let budget = WorkBudget(); budget.cancel()
        XCTAssertThrowsError(try ReadDatabase(path: path, budget: budget).schema())
    }

    func testInventoryLimitsSymlinksAndStaticInspection() throws {
        let file = root.appendingPathComponent("metadata.json")
        try Data("{\"purpose\":\"synthetic\"}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        var updates: [InventoryUpdate] = []
        try Inventory.scan(root: root, budget: WorkBudget()) { updates.append($0) }
        XCTAssertEqual(updates.flatMap(\.files).count, 1); XCTAssertEqual(updates.last?.complete, true)
        let inspection = try Inventory.inspect(url: file, hash: true, budget: WorkBudget())
        XCTAssertTrue(inspection.metadata?.contains("synthetic") == true); XCTAssertEqual(inspection.sha256?.count, 64)
        updates = []
        try Inventory.scan(root: root, budget: WorkBudget(), maximumFiles: 0) { updates.append($0) }
        XCTAssertTrue(updates.last?.note.contains("Partial") == true)
    }

    func testBundledHistoricalFixtureHasOnlySuppliedLinkage() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = project.appendingPathComponent("Fixtures")
        let source = SourceConfiguration(analysisPath: fixture.appendingPathComponent("MediaAnalysis.sqlite").path,
                                         photosPath: fixture.appendingPathComponent("Photos.sqlite").path, isFixture: true)
        let page = try LibraryReader.assets(source: source, search: "Screenshot 2026-09-23", budget: WorkBudget())
        XCTAssertEqual(page.assets.count, 1)
        let asset = try XCTUnwrap(page.assets.first)
        XCTAssertEqual(asset.identifier, uuid + "/L0/001")
        XCTAssertEqual(asset.fields["ZDATEANALYZED"], "NULL")
        let detail = try LibraryReader.detail(asset: asset, source: source, budget: WorkBudget())
        XCTAssertTrue(detail.families.isEmpty)
        XCTAssertEqual(detail.media?.filename, uuid + ".png")
        XCTAssertEqual(detail.media?.originalName, "Screenshot 2026-09-23 at 9.54.53\u{202f}AM.png")
    }
}
