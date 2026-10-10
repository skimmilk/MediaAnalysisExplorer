import Foundation

public enum ProcessingRange: String, CaseIterable, Identifiable, Sendable {
    case week = "7D", month = "30D", quarter = "90D", year = "1Y", all = "All", custom = "Custom"
    public var id: String { rawValue }
    public var days: Int? { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; default: nil } }
}
public struct ProcessingBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public var assets: Int? = nil
    public var sessions: Int? = nil
    public var reported: Int? = nil
    public var changes: Int? = nil
}
public struct ProcessedAsset: Identifiable, Sendable {
    public let id: String
    public let identifier: String
    public let name: String?
    public let date: Date
}
public struct ProcessingTaskTotal: Identifiable, Sendable {
    public var id: String { task }
    public let task: String
    public let sessions: Int
    public let reported: Int?
    public let reportingSessions: Int
    public let nonzeroExits: Int
}
public struct ProcessingHistory: Sendable {
    public let start: Date
    public let end: Date
    public let granularity: String
    public let buckets: [ProcessingBucket]
    public let recentAssets: [ProcessedAsset]
    public let tasks: [ProcessingTaskTotal]
    public let families: [DBRow]
    public let undatedAssets: Int?
    public let undatedSessions: Int?
    public let reportingSessions: Int?
    public let earliestRetained: Date?
    public let issues: [String]
    public func total(_ key: KeyPath<ProcessingBucket, Int?>) -> Int? {
        guard buckets.allSatisfy({ $0[keyPath: key] != nil }) else { return nil }
        return buckets.reduce(0) { $0 + ($1[keyPath: key] ?? 0) }
    }
}

/// Aggregates the requested window in SQLite. It never uses the latest-100-row
/// session preview or repeats a shared schedule's duration for each task.
public enum ProcessingHistoryReader {
    public static func read(databases: [DaemonDatabase], range: ProcessingRange, now: Date = Date(),
                            customStart: Date = Date(), customEnd: Date = Date(),
                            calendar: Calendar = .current, budget: WorkBudget) throws -> ProcessingHistory {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var issues: [String] = []
        var connections: [String: (ReadDatabase, [TableSchema], SourceConfiguration)] = [:]
        for database in databases where ["Photos analysis", "Daemon activity"].contains(database.name) {
            do {
                let db = try ReadDatabase(path: database.source.analysisPath, budget: budget)
                connections[database.name] = (db, try db.schema(), database.source)
            } catch { issues.append(database.name + ": " + error.localizedDescription) }
        }
        func has(_ source: String, _ table: String, _ fields: String...) -> Bool {
            guard let schema = connections[source]?.1.first(where: { $0.name == table }) else { return false }
            return fields.allSatisfy { schema.columns[$0] != nil }
        }
        let assetsAvailable = has("Photos analysis", "ZASSET", "Z_PK", "ZLOCALIDENTIFIER", "ZDATEANALYZED")
        let changesAvailable = has("Photos analysis", "ATRANSACTION", "Z_PK", "ZTIMESTAMP") && has("Photos analysis", "ACHANGE", "ZTRANSACTIONID", "ZENTITY") && has("Photos analysis", "Z_PRIMARYKEY", "Z_ENT", "Z_NAME")
        let sessionsAvailable = has("Daemon activity", "ZBACKGROUNDACTIVITYSESSIONLOG", "Z_PK", "ZTASKID", "ZPAYLOAD", "ZSCHEDULING") && has("Daemon activity", "ZBACKGROUNDACTIVITYSCHEDULE", "Z_PK", "ZSTARTTIMESTAMP")
        let sessionJoin = "ZBACKGROUNDACTIVITYSESSIONLOG l LEFT JOIN ZBACKGROUNDACTIVITYSCHEDULE s ON s.Z_PK=l.ZSCHEDULING"
        let changeJoin = "ATRANSACTION t JOIN ACHANGE c ON c.ZTRANSACTIONID=t.Z_PK JOIN Z_PRIMARYKEY p ON p.Z_ENT=c.ZENTITY"
        let resultPredicate = "upper(p.Z_NAME) LIKE '%RESULT'"
        let upper = String(end.timeIntervalSinceReferenceDate)
        var earliest: [Date] = []
        let minima: [(Bool, String, String)] = [
            (assetsAvailable, "Photos analysis", "SELECT min(ZDATEANALYZED) AS stamp FROM ZASSET WHERE ZDATEANALYZED>0 AND ZDATEANALYZED<?"),
            (changesAvailable, "Photos analysis", "SELECT min(t.ZTIMESTAMP) AS stamp FROM \(changeJoin) WHERE \(resultPredicate) AND t.ZTIMESTAMP>0 AND t.ZTIMESTAMP<?"),
            (sessionsAvailable, "Daemon activity", "SELECT min(s.ZSTARTTIMESTAMP) AS stamp FROM \(sessionJoin) WHERE s.ZSTARTTIMESTAMP>0 AND s.ZSTARTTIMESTAMP<?")
        ]
        for (available, source, sql) in minima where available {
            do {
                if let stamp = Double(try connections[source]!.0.query(sql, parameters: [upper]).first?["stamp"] ?? ""), stamp.isFinite {
                    earliest.append(Date(timeIntervalSinceReferenceDate: stamp))
                }
            } catch { issues.append("Retained history boundary: " + error.localizedDescription) }
        }
        let start: Date, windowEnd: Date
        if range == .custom {
            start = calendar.startOfDay(for: customStart)
            windowEnd = min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))!)
            guard start < windowEnd else { throw ExplorerError("Choose a start date on or before the end date, no later than today.") }
        } else {
            start = range.days.map { calendar.date(byAdding: .day, value: -$0, to: end)! } ?? calendar.startOfDay(for: earliest.min() ?? now)
            windowEnd = end
        }
        let days = calendar.dateComponents([.day], from: start, to: windowEnd).day ?? 1
        let component: Calendar.Component = days <= 90 ? .day : days <= 730 ? .weekOfYear : days <= 3650 ? .month : .year
        let granularity = component == .day ? "Daily" : component == .weekOfYear ? "Weekly" : component == .month ? "Monthly" : "Yearly"
        var buckets: [ProcessingBucket] = [], cursor = start
        while cursor < windowEnd {
            guard buckets.count < 150, let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { throw ExplorerError("History window exceeds the supported calendar range.") }
            buckets.append(ProcessingBucket(start: cursor, end: min(next, windowEnd)))
            cursor = next
        }
        let bounds = [String(start.timeIntervalSinceReferenceDate), String(windowEnd.timeIntervalSinceReferenceDate)]
        func period(_ field: String) -> (String, [String]) {
            let clauses = buckets.indices.map { "WHEN \(field)>=? AND \(field)<? THEN \($0)" }.joined(separator: " ")
            return ("CASE \(clauses) END", buckets.flatMap { [String($0.start.timeIntervalSinceReferenceDate), String($0.end.timeIntervalSinceReferenceDate)] })
        }
        func aggregate(_ source: String, field: String, from: String, predicate: String = "1", expressions: String = "count(*) AS n") throws -> [DBRow] {
            let (group, parameters) = period(field)
            return try connections[source]!.0.query("SELECT \(group) AS period,\(expressions) FROM \(from) WHERE \(predicate) AND \(field)>0 AND \(field)>=? AND \(field)<? GROUP BY period", parameters: parameters + bounds)
        }
        var recentAssets: [ProcessedAsset] = [], tasks: [ProcessingTaskTotal] = [], families: [DBRow] = []
        var undatedAssets: Int?, undatedSessions: Int?, reportingSessions: Int?
        if assetsAvailable {
            do {
                let rows = try aggregate("Photos analysis", field: "ZDATEANALYZED", from: "ZASSET")
                for i in buckets.indices { buckets[i].assets = 0 }
                for row in rows { if let index = Int(row["period"]), buckets.indices.contains(index) { buckets[index].assets = Int(row["n"]) } }
                let db = connections["Photos analysis"]!.0
                undatedAssets = Int(try db.query("SELECT count(*) AS n FROM ZASSET WHERE ZDATEANALYZED IS NULL OR typeof(ZDATEANALYZED) NOT IN ('integer','real') OR ZDATEANALYZED<=0").first?["n"] ?? "")
                let recent = try db.query("SELECT Z_PK,ZLOCALIDENTIFIER,ZDATEANALYZED FROM ZASSET WHERE ZDATEANALYZED>0 AND ZDATEANALYZED>=? AND ZDATEANALYZED<? ORDER BY ZDATEANALYZED DESC,Z_PK DESC LIMIT 12", parameters: bounds)
                let names = filenames(recent.map { $0["ZLOCALIDENTIFIER"] }, source: connections["Photos analysis"]!.2, budget: budget)
                recentAssets = recent.compactMap { row in
                    guard let stamp = Double(row["ZDATEANALYZED"]), stamp.isFinite else { return nil }
                    return ProcessedAsset(id: row["Z_PK"], identifier: row["ZLOCALIDENTIFIER"], name: AssetIdentifier.uuid(row["ZLOCALIDENTIFIER"]).flatMap { names[$0] }, date: Date(timeIntervalSinceReferenceDate: stamp))
                }
            } catch { issues.append("Photo analysis dates: " + error.localizedDescription) }
        } else { issues.append("Photos latest-analysis dates unavailable.") }
        if changesAvailable {
            do {
                let rows = try aggregate("Photos analysis", field: "t.ZTIMESTAMP", from: changeJoin, predicate: resultPredicate)
                for i in buckets.indices { buckets[i].changes = 0 }
                for row in rows { if let index = Int(row["period"]), buckets.indices.contains(index) { buckets[index].changes = Int(row["n"]) } }
                families = try connections["Photos analysis"]!.0.query("SELECT p.Z_NAME AS entity,count(*) AS n FROM \(changeJoin) WHERE \(resultPredicate) AND t.ZTIMESTAMP>0 AND t.ZTIMESTAMP>=? AND t.ZTIMESTAMP<? GROUP BY p.Z_NAME ORDER BY count(*) DESC LIMIT 100", parameters: bounds)
            } catch { issues.append("Retained result changes: " + error.localizedDescription) }
        } else { issues.append("Retained result-change history unavailable.") }
        if sessionsAvailable {
            do {
                let db = connections["Daemon activity"]!.0
                let rows = try aggregate("Daemon activity", field: "s.ZSTARTTIMESTAMP", from: sessionJoin)
                for i in buckets.indices { buckets[i].sessions = 0 }
                for row in rows { if let index = Int(row["period"]), buckets.indices.contains(index) { buckets[index].sessions = Int(row["n"]) } }
                undatedSessions = Int(try db.query("SELECT count(*) AS n FROM \(sessionJoin) WHERE s.ZSTARTTIMESTAMP IS NULL OR typeof(s.ZSTARTTIMESTAMP) NOT IN ('integer','real') OR s.ZSTARTTIMESTAMP<=0").first?["n"] ?? "")
                // JSON aggregation avoids a latest-N session cap. Malformed,
                // boolean, negative and fractional counts remain unknown.
                let json = (try? db.query("SELECT json_valid('{}') AS supported").first?["supported"]) == "1"
                let count = json ? "CASE WHEN json_valid(l.ZPAYLOAD) THEN CASE WHEN json_type(l.ZPAYLOAD,'$.NumberOfAssetsAnalyzed') IN ('integer','real') AND json_extract(l.ZPAYLOAD,'$.NumberOfAssetsAnalyzed')>=0 AND json_extract(l.ZPAYLOAD,'$.NumberOfAssetsAnalyzed')=CAST(json_extract(l.ZPAYLOAD,'$.NumberOfAssetsAnalyzed') AS INTEGER) THEN CAST(json_extract(l.ZPAYLOAD,'$.NumberOfAssetsAnalyzed') AS INTEGER) END END" : "NULL"
                if json {
                    let reported = try aggregate("Daemon activity", field: "s.ZSTARTTIMESTAMP", from: sessionJoin, expressions: "coalesce(sum(\(count)),0) AS n,count(\(count)) AS known")
                    for i in buckets.indices { buckets[i].reported = 0 }
                    reportingSessions = 0
                    for row in reported {
                        if let index = Int(row["period"]), buckets.indices.contains(index) { buckets[index].reported = Int(row["n"]) }
                        reportingSessions! += Int(row["known"]) ?? 0
                    }
                    if reportingSessions == 0 && buckets.contains(where: { ($0.sessions ?? 0) > 0 }) { for i in buckets.indices { buckets[i].reported = nil } }
                } else { issues.append("Session payload aggregation unavailable in this SQLite runtime.") }
                let exits = has("Daemon activity", "ZBACKGROUNDACTIVITYSCHEDULE", "ZEXITSTATUS") ? "sum(CASE WHEN s.ZEXITSTATUS!=0 THEN 1 ELSE 0 END)" : "0"
                tasks = try db.query("SELECT l.ZTASKID AS task,count(*) AS n,sum(\(count)) AS reported,count(\(count)) AS known,\(exits) AS exits FROM \(sessionJoin) WHERE s.ZSTARTTIMESTAMP>0 AND s.ZSTARTTIMESTAMP>=? AND s.ZSTARTTIMESTAMP<? GROUP BY l.ZTASKID ORDER BY count(*) DESC LIMIT 12", parameters: bounds).map {
                    ProcessingTaskTotal(task: $0["task"], sessions: Int($0["n"]) ?? 0, reported: Int($0["reported"]), reportingSessions: Int($0["known"]) ?? 0, nonzeroExits: Int($0["exits"]) ?? 0)
                }
            } catch { issues.append("Dated daemon sessions: " + error.localizedDescription) }
        } else { issues.append("Dated daemon session history unavailable.") }
        try budget.check()
        return ProcessingHistory(start: start, end: windowEnd, granularity: granularity, buckets: buckets, recentAssets: recentAssets, tasks: tasks, families: families,
                                 undatedAssets: undatedAssets, undatedSessions: undatedSessions, reportingSessions: reportingSessions, earliestRetained: earliest.min(), issues: issues)
    }
    private static func filenames(_ identifiers: [String], source: SourceConfiguration, budget: WorkBudget) -> [String: String] {
        let uuids = identifiers.compactMap(AssetIdentifier.uuid)
        guard !source.photosPath.isEmpty, !uuids.isEmpty else { return [:] }
        do {
            let db = try ReadDatabase(path: source.photosPath, budget: budget), schema = try db.schema()
            guard let asset = schema.first(where: { $0.name == "ZASSET" }), asset.has("ZUUID", "ZFILENAME") else { return [:] }
            let joined = asset.has("ZADDITIONALATTRIBUTES") && schema.contains { $0.name == "ZADDITIONALASSETATTRIBUTES" && $0.has("Z_PK", "ZORIGINALFILENAME") }
            let fields = joined ? "COALESCE(aa.ZORIGINALFILENAME,a.ZFILENAME)" : "a.ZFILENAME"
            let join = joined ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK=a.ZADDITIONALATTRIBUTES" : ""
            let rows = try db.query("SELECT a.ZUUID,\(fields) AS name FROM ZASSET a \(join) WHERE a.ZUUID COLLATE NOCASE IN (\(Array(repeating: "?", count: uuids.count).joined(separator: ",")))", parameters: uuids)
            return rows.reduce(into: [:]) { if $1["name"] != "NULL" { $0[$1["ZUUID"].uppercased()] = $1["name"] } }
        } catch { return [:] }
    }
}
