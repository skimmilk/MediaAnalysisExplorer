import XCTest
import CSQLite
@testable import ExplorerCore

final class ProcessingChangeMonitorTests: XCTestCase {
    func testWALCommitIsDetectedWithoutReportingUncommittedRowsOrWritingTheSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else { throw ExplorerError(String(cString: sqlite3_errmsg(writer))) }
        }
        try execute("PRAGMA journal_mode=WAL; CREATE TABLE history (value INTEGER);")
        let monitor = ProcessingChangeMonitor(databases: [DaemonDatabase(name: "Photos analysis", purpose: "test", source: SourceConfiguration(analysisPath: path))])
        let baseline = await monitor.hasChanges()
        XCTAssertTrue(baseline)
        let idle = await monitor.hasChanges()
        XCTAssertFalse(idle)
        try execute("BEGIN; INSERT INTO history VALUES (1);")
        let uncommitted = await monitor.hasChanges()
        XCTAssertFalse(uncommitted)
        try execute("COMMIT;")
        let committed = await monitor.hasChanges()
        XCTAssertTrue(committed)
        let repeated = await monitor.hasChanges()
        XCTAssertFalse(repeated)
        XCTAssertEqual(try ReadDatabase(path: path).query("SELECT count(*) AS n FROM history").first?["n"], "1")
    }

    func testUnavailableSourceIsNotCreated() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let monitor = ProcessingChangeMonitor(databases: [DaemonDatabase(name: "Photos analysis", purpose: "test", source: SourceConfiguration(analysisPath: path))])
        let changed = await monitor.hasChanges()
        XCTAssertFalse(changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
