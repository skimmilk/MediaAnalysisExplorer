import Foundation

public struct DashboardSource: Identifiable, Sendable {
    public var id: String { database.id }
    public let database: DaemonDatabase
    public let report: StoredDataReport?
    public let progress: [DBRow]
    public let issue: String?
    public var persistence: PersistenceHistory = .empty
    public func count(_ table: String) -> Int? { report?.tables.first { $0.id == table }?.count }
    public var resultRows: Int? {
        guard let report else { return nil }
        let results = report.tables.filter { $0.id.contains("RESULT") }
        guard results.allSatisfy({ $0.count != nil }) else { return nil }
        return results.reduce(0) { $0 + ($1.count ?? 0) }
    }
}

public struct DaemonProcess: Identifiable, Sendable {
    public var id: Int { pid }
    public let name: String
    public let pid: Int
    public let cpuPercent: Double
    public let rssKiB: Int64
    public let elapsed: String
}

public struct ProcessingDashboard: Sendable {
    public let updated: Date
    public let sources: [DashboardSource]
    public let processes: [DaemonProcess]
    public let processIssue: String?
}

public enum ProcessingDashboardReader {
    public static func read(databases: [DaemonDatabase], budget: WorkBudget) -> ProcessingDashboard {
        let sources = databases.map { database -> DashboardSource in
            var overview: StoredDataReport?
            do {
                try budget.check()
                let report = try StoredDataReader.inspect(source: database.source, budget: budget)
                overview = report
                let db = try ReadDatabase(path: database.source.analysisPath, budget: budget)
                let schema = try db.schema()
                var progress: [DBRow] = []
                if let table = schema.first(where: { $0.name == "ZBACKGROUNDANALYSISPROGRESSHISTORY" }), table.has("Z_PK", "ZACTIVITYID", "ZPROCESSEDASSETCOUNT", "ZTOTALASSETCOUNT") {
                    let recent = try db.query("SELECT \(db.projection(table)) FROM ZBACKGROUNDANALYSISPROGRESSHISTORY ORDER BY Z_PK DESC LIMIT 100")
                    var seen: Set<String> = []
                    progress = recent.filter { seen.insert([$0["ZACTIVITYID"], $0["ZANALYSISSUBTYPE"], $0["ZVERSION"]].joined(separator: ":")).inserted }
                }
                return DashboardSource(database: database, report: report, progress: progress, issue: nil, persistence: PersistenceReader.read(db: db, schema: schema))
            } catch {
                return DashboardSource(database: database, report: overview, progress: [], issue: error.localizedDescription)
            }
        }
        let process: (rows: [DaemonProcess], issue: String?)
        do {
            // -c reports process names rather than full command arguments. Only
            // these three exact daemon names survive the ephemeral sample.
            process = (try parseProcesses(command("/bin/ps", ["-Aco", "pid,pcpu,rss,etime,comm"])), nil)
        } catch { process = ([], error.localizedDescription) }
        return ProcessingDashboard(updated: Date(), sources: sources, processes: process.rows, processIssue: process.issue)
    }
    public static func parseProcesses(_ text: String) -> [DaemonProcess] {
        text.split(separator: "\n").compactMap { line in
            let v = line.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
            guard v.count == 5, ["mediaanalysisd", "photoanalysisd", "photolibraryd"].contains(v[4]),
                  let pid = Int(v[0]), let cpu = Double(v[1]), cpu.isFinite, cpu >= 0, let rss = Int64(v[2]), rss >= 0 else { return nil }
            return DaemonProcess(name: v[4], pid: pid, cpuPercent: cpu, rssKiB: rss, elapsed: v[3])
        }
    }
    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mae-process-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ExplorerError("Cannot create process sample") }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL":"C"], uniquingKeysWith: { _, value in value })
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else { process.terminate(); throw ExplorerError("Process sampling timed out") }
        guard process.terminationStatus == 0 else { throw ExplorerError("Process sampling unavailable (\(process.terminationStatus))") }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        return String(decoding: try input.read(upToCount: 1024 * 1024) ?? Data(), as: UTF8.self)
    }
}
