import XCTest
import Foundation
import CoreGraphics
@testable import ExplorerCore

final class DashboardTimelineTests: XCTestCase {
    private func region(_ id: String, start: Double?, duration: Double?, table: String = "face") -> StoredRegion {
        StoredRegion(id: id, title: id, table: table, record: id, rectangle: CGRect(x: 0, y: 0, width: 1, height: 1), fields: [:], start: start, duration: duration)
    }
    func testTimelineMatchesStoredIntervalsAtBoundariesAndBackwardSeeks() {
        let regions = [region("static", start: nil, duration: nil), region("a", start: 1, duration: 2),
                       region("b", start: 2, duration: 1), region("frame", start: 4, duration: nil), region("other", start: 0, duration: 8, table: "pose")]
        let timeline = RegionTimeline(regions: regions)
        for second in [0, 1, 2, 3, 3.85, 3.85001, 4, 4.14999, 4.15, 9, 2, 0, 4] {
            XCTAssertEqual(timeline.visible(at: second).map(\.id), regions.filter { $0.visible(at: second) }.map(\.id), "time \(second)")
            XCTAssertEqual(timeline.visible(at: second, hiding: ["pose"]).map(\.id), regions.filter { $0.table != "pose" && $0.visible(at: second) }.map(\.id))
        }
        XCTAssertEqual(timeline.visible(at: nil).count, regions.count)
        XCTAssertTrue(timeline.visible(at: .nan).isEmpty)
    }
    func testTimelineHandlesLargeTrackAndOutOfOrderPlayback() {
        let regions = (0..<2000).map { region(String($0), start: Double($0) / 30, duration: 0.1) }
        let timeline = RegionTimeline(regions: regions)
        for second in stride(from: 65.0, through: 0.0, by: -0.125) {
            XCTAssertEqual(timeline.visible(at: second).map(\.id), regions.filter { $0.visible(at: second) }.map(\.id))
        }
    }
    func testProcessSampleUsesExactNamesAndAllowsMultipleCores() {
        let rows = ProcessingDashboardReader.parseProcesses("""
        PID %CPU RSS ELAPSED COMMAND
        7 199.3 382496 30:00 mediaanalysisd
        8 0.0 12000 02:00 photolibraryd
        9 30.0 1000 00:05 mediaanalysisd-access
        10 nan 10 00:01 photoanalysisd
        11 1.0 -1 00:01 photoanalysisd
        """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cpuPercent, 199.3)
        XCTAssertEqual(rows[0].rssKiB, 382496)
    }
    func testDashboardAggregatesKnownStoresAndKeepsUnavailableCountsUnknown() throws {
        guard let database = ProcessInfo.processInfo.environment["MAE_RESEARCH_DATABASE"] else { throw XCTSkip("Set MAE_RESEARCH_DATABASE for captured dashboard validation.") }
        let directory = URL(fileURLWithPath: database).deletingLastPathComponent()
        let known = DaemonDatabase.known(home: URL(fileURLWithPath: "/test"))
        let sources = known.enumerated().map { index, source in
            DaemonDatabase(name: source.name, purpose: source.purpose, source: SourceConfiguration(analysisPath: directory.appendingPathComponent("database-\(index).sqlite").path))
        }
        let missing = DaemonDatabase(name: "Missing", purpose: "test", source: SourceConfiguration(analysisPath: directory.appendingPathComponent("absent.sqlite").path))
        let report = ProcessingDashboardReader.read(databases: sources + [missing], budget: WorkBudget(seconds: 15))
        XCTAssertEqual(report.sources.count, 4)
        XCTAssertEqual(report.sources[0].count("ZBACKGROUNDACTIVITYSESSIONLOG"), 2976)
        XCTAssertEqual(report.sources[1].count("ZASSET"), 14)
        XCTAssertGreaterThan(report.sources[1].resultRows ?? 0, 761)
        XCTAssertFalse(report.sources[1].progress.isEmpty)
        XCTAssertNil(report.sources[3].count("ZASSET"))
        XCTAssertNotNil(report.sources[3].issue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.source.analysisPath))
    }
}
