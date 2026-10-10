import Foundation
import CoreFoundation

public struct DaemonDatabase: Identifiable, Sendable {
    public var id: String { source.analysisPath }
    public let name: String
    public let purpose: String
    public let source: SourceConfiguration
    public init(name: String, purpose: String, source: SourceConfiguration) { self.name = name; self.purpose = purpose; self.source = source }
    public static func known(home: URL) -> [Self] {
        [Self(name: "Daemon activity", purpose: "Background sessions, schedules, requests, and Spotlight queue",
              source: SourceConfiguration(analysisPath: home.appendingPathComponent("Library/MediaAnalysis/MediaAnalysis.sqlite").path)),
         Self(name: "Photos analysis", purpose: "Asset analysis, result records, retries, and progress",
              source: .library(home.appendingPathComponent("Pictures/Photos Library.photoslibrary"))),
         Self(name: "Syndication analysis", purpose: "Analysis for the Syndication Photos library",
              source: .library(home.appendingPathComponent("Library/Photos/Libraries/Syndication.photoslibrary")))]
    }
}

public struct StoredTable: Identifiable, Sendable {
    public var id: String { schema.name }
    public let schema: TableSchema
    public let count: Int?
    public let blobBytes: Int64?
    public let issue: String?
    public var description: String {
        switch schema.name {
        case "ZBACKGROUNDACTIVITYSESSIONLOG": "Per-task session payloads; reported numbers of analyzed assets"
        case "ZBACKGROUNDACTIVITYSCHEDULE": "Recorded run duration, exit status, QoS, PID, and timestamps"
        case "ZMADREQUEST": "Requesting app, source/asset IDs, asset URLs, attempts, and result-directory references"
        case "ZSPOTLIGHTENTRY": "Spotlight work queue, source app, URL, media type, and retry/status records"
        case "ZASSET": "Analysis identifiers, raw dates, flags, quality, and analysis-version fields"
        case "ZPROCESSINGSTATUS": "Attempts, task/status IDs, error code/line, and retry timestamps"
        case "ZMOMENTSSCHEDULEDASSET": "Scheduled asset IDs, task IDs, and request timestamps"
        case "ZBACKGROUNDANALYSISPROGRESSHISTORY": "Historical processed/total counts and analysis subtype/version"
        case "ZIMAGECAPTIONRESULT", "ZVIDEOCAPTIONRESULT", "ZVIDEOSEGMENTCAPTIONRESULT": "Generated captions, confidence, and segment timing where stored"
        case "ZWORDLEVELTRANSCRIPTIONRESULT", "ZSENTENCELEVELTRANSCRIPTIONRESULT": "Transcription words or sentence boundaries and timing"
        case "ZCLASSIFICATIONRESULT": "Raw scene IDs, confidence, and timing; label meanings unvalidated"
        case "ZRESULT": "Typed opaque analysis payloads; raw result-type IDs retained"
        case "Z_MODELCACHE": "Managed-object schema cache; recognized compressed archives are projected as metadata, without model instantiation"
        case "Z_METADATA", "Z_PRIMARYKEY": "Core Data database metadata"
        default: schema.name.contains("RESULT") ? "Stored analysis results; undocumented fields and BLOBs retained as raw data" : "Stored database records; private schema semantics unvalidated"
        }
    }
}

public struct StoredSession: Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let assetsAnalyzed: Int?
    public let scheduleID: String?
    public let duration: Double?
    public let exitStatus: String?
    public let rawStart: String?
    public let rawPayload: String
    public let payloadTruncated: Bool
}

public struct StoredDataReport: Sendable {
    public let tables: [StoredTable]
    public let sessions: [StoredSession]
    public let taskCounts: [DBRow]
    public let processingGroups: [DBRow]
    public let issues: [String]
    public var complete: Bool { tables.allSatisfy { $0.count != nil && $0.issue == nil } && issues.isEmpty }
}

public enum StoredDataReader {
    public static func analyzedCount(payload: String) -> Int? {
        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["NumberOfAssetsAnalyzed"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let count = Int(number.stringValue), count >= 0 else { return nil }
        return count
    }
    public static func inspect(source: SourceConfiguration, budget: WorkBudget) throws -> StoredDataReport {
        let db = try ReadDatabase(path: source.analysisPath, budget: budget)
        let schema = try db.schema()
        var tables: [StoredTable] = []; var issues: [String] = []
        for table in schema {
            var count: Int?; var blobBytes: Int64?; var issue: String?
            do {
                let name = ReadDatabase.quote(table.name)
                count = Int(try db.query("SELECT count(*) AS n FROM \(name)").first?["n"] ?? "")
                let blobs = table.columns.filter { $0.value.uppercased().contains("BLOB") && !$0.key.uppercased().contains("TOKEN") }.keys.sorted()
                if !blobs.isEmpty {
                    let expression = blobs.map { "coalesce(length(\(ReadDatabase.quote($0))),0)" }.joined(separator: " + ")
                    blobBytes = Int64(try db.query("SELECT coalesce(sum(\(expression)),0) AS n FROM \(name)").first?["n"] ?? "")
                }
            } catch { issue = error.localizedDescription }
            tables.append(StoredTable(schema: table, count: count, blobBytes: blobBytes, issue: issue))
        }
        var sessions: [StoredSession] = []; var tasks: [DBRow] = []; var processing: [DBRow] = []
        if let logs = schema.first(where: { $0.name == "ZBACKGROUNDACTIVITYSESSIONLOG" }), logs.has("Z_PK", "ZTASKID", "ZPAYLOAD") {
            do {
                let schedules = schema.first { $0.name == "ZBACKGROUNDACTIVITYSCHEDULE" }
                let canJoin = logs.has("ZSCHEDULING") && schedules?.has("Z_PK") == true
                func field(_ column: String) -> String { canJoin && schedules?.has(column) == true ? "s.\(ReadDatabase.quote(column))" : "NULL" }
                let join = canJoin ? "LEFT JOIN ZBACKGROUNDACTIVITYSCHEDULE s ON s.Z_PK = l.ZSCHEDULING" : ""
                let rows = try db.query("""
                    SELECT l.Z_PK AS key, l.ZTASKID AS task, substr(l.ZPAYLOAD,1,4096) AS payload,
                    length(l.ZPAYLOAD) > 4096 AS truncated,
                    \(canJoin ? "s.Z_PK" : "NULL") AS schedule,
                    \(field("ZDURATION")) AS duration, \(field("ZEXITSTATUS")) AS exit,
                    \(field("ZSTARTTIMESTAMP")) AS start
                    FROM ZBACKGROUNDACTIVITYSESSIONLOG l \(join) ORDER BY l.Z_PK DESC LIMIT 100
                    """)
                sessions = rows.map { row in
                    func optional(_ key: String) -> String? { row[key] == "NULL" ? nil : row[key] }
                    let truncated = row["truncated"] == "1"
                    return StoredSession(id: row["key"], taskID: row["task"], assetsAnalyzed: truncated ? nil : analyzedCount(payload: row["payload"]),
                                         scheduleID: optional("schedule"), duration: Double(row["duration"]), exitStatus: optional("exit"),
                                         rawStart: optional("start"), rawPayload: row["payload"], payloadTruncated: truncated)
                }
                tasks = try db.query("SELECT ZTASKID AS 'Task ID', count(*) AS 'Stored sessions' FROM ZBACKGROUNDACTIVITYSESSIONLOG GROUP BY ZTASKID ORDER BY count(*) DESC LIMIT 100")
            } catch { issues.append("Session summaries unavailable: \(error.localizedDescription)") }
        }
        if let statuses = schema.first(where: { $0.name == "ZPROCESSINGSTATUS" }), statuses.has("ZTASKID", "ZSTATUS", "ZERRORCODE") {
            do {
                let attempts = statuses.has("ZATTEMPTCOUNT") ? ", max(ZATTEMPTCOUNT) AS 'Maximum attempts'" : ""
                processing = try db.query("SELECT ZTASKID AS 'Task ID', ZSTATUS AS 'Status ID', ZERRORCODE AS 'Error code', count(*) AS 'Stored records' \(attempts) FROM ZPROCESSINGSTATUS GROUP BY ZTASKID, ZSTATUS, ZERRORCODE ORDER BY count(*) DESC LIMIT 100")
            } catch { issues.append("Processing groups unavailable: \(error.localizedDescription)") }
        }
        return StoredDataReport(tables: tables, sessions: sessions, taskCounts: tasks, processingGroups: processing, issues: issues)
    }
}
