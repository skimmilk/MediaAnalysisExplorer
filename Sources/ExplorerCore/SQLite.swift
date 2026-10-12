import Foundation
import CSQLite
import Darwin

public struct ExplorerError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Each worker owns a connection. A shared cancellation flag is the only cross-thread state.
public final class WorkBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: Date
    public init(seconds: TimeInterval = 5) { deadline = Date().addingTimeInterval(seconds) }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var stopped: Bool {
        lock.lock(); let value = cancelled; lock.unlock()
        return value || Date() > deadline
    }
    public func check() throws {
        if stopped { throw ExplorerError("Work cancelled or time limit reached. Narrow the search or retry.") }
    }
}

public struct DBRow: Identifiable, Sendable {
    public let id: Int
    public let fields: [String: String]
    public let decoded: [String: DecodedPayload]
    public init(id: Int, fields: [String: String], decoded: [String: DecodedPayload] = [:]) { self.id = id; self.fields = fields; self.decoded = decoded }
    public subscript(_ key: String) -> String { fields[key] ?? "NULL" }
}

public struct TableSchema: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let columns: [String: String]
    public init(name: String, columns: [String: String]) { self.name = name; self.columns = columns }
    public func has(_ columns: String...) -> Bool { columns.allSatisfy { self.columns[$0] != nil } }
}

public final class ReadDatabase {
    private var handle: OpaquePointer?
    public let path: String
    public let budget: WorkBudget
    public init(path: String, budget: WorkBudget = WorkBudget()) throws {
        self.path = path; self.budget = budget
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw ExplorerError("\(path)\nSQLite \(code): \(detail). Grant this app access in macOS Privacy & Security if needed.")
        }
        sqlite3_busy_timeout(handle, 500)
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<WorkBudget>.fromOpaque(pointer).takeUnretainedValue().stopped ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
    }
    deinit { if let handle { sqlite3_close(handle) } }
    public static func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    public func query(_ sql: String, parameters: [String] = []) throws -> [DBRow] {
        try budget.check()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        var rows: [DBRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            var fields: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: fields[name] = "NULL"
                case SQLITE_BLOB: fields[name] = "BLOB · \(sqlite3_column_bytes(statement, column)) bytes (undecoded)"
                default:
                    if let value = sqlite3_column_text(statement, column) { fields[name] = String(cString: value) }
                }
            }
            rows.append(DBRow(id: rows.count, fields: fields))
            if rows.count > 20_000 { throw ExplorerError("Query row limit exceeded") }
        }
        return rows
    }
    private func error() -> ExplorerError {
        ExplorerError("\(path)\nSQLite: \(String(cString: sqlite3_errmsg(handle)))")
    }
    public func modelCacheData() throws -> Data? {
        try budget.check()
        var statement: OpaquePointer?
        let sql = "SELECT CASE WHEN typeof(Z_CONTENT)='blob' AND length(Z_CONTENT)<=262144 THEN Z_CONTENT ELSE NULL END FROM Z_MODELCACHE LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw error() }
        guard sqlite3_column_type(statement, 0) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, 0) else { throw ExplorerError("Schema cache is absent or exceeds the 256 KiB read limit") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
    public func schema() throws -> [TableSchema] {
        try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { row in
            let name = row["name"]
            let columns = try query("PRAGMA table_info(\(Self.quote(name)))")
            return TableSchema(name: name, columns: Dictionary(uniqueKeysWithValues: columns.map { ($0["name"], $0["type"]) }))
        }
    }
    /// BLOB values stay in SQLite; only their byte lengths enter the UI. Sandbox tokens are omitted.
    public func projection(_ schema: TableSchema) -> String {
        schema.columns.keys.sorted().filter { !$0.uppercased().contains("TOKEN") }.map { name in
            let q = Self.quote(name)
            return "CASE WHEN typeof(\(q))='blob' THEN 'BLOB · ' || length(\(q)) || ' bytes (undecoded)' WHEN typeof(\(q))='text' AND length(\(q))>4096 THEN substr(\(q),1,4096) || '… [truncated]' ELSE \(q) END AS \(q)"
        }.joined(separator: ", ")
    }
    public func rows(table: TableSchema, offset: Int = 0, limit: Int = 100, assetKey: String? = nil) throws -> [DBRow] {
        let projection = projection(table)
        guard !projection.isEmpty else { return [] }
        let condition = assetKey == nil ? "" : "WHERE ZASSET = ?"
        let order = assetKey == nil ? (table.has("Z_PK") ? "Z_PK" : table.columns.keys.sorted().first.map(Self.quote) ?? "1") : Self.analysisOrder(table)
        return try query("SELECT \(projection) FROM \(Self.quote(table.name)) \(condition) ORDER BY \(order) LIMIT \(min(max(limit, 1), 101)) OFFSET \(max(offset, 0))", parameters: assetKey.map { [$0] } ?? [])
    }
    /// Sort normalized seconds before LIMIT/OFFSET, including mixed timescales.
    /// Invalid times sort last, matching the in-memory result presentation.
    public static func analysisOrder(_ table: TableSchema) -> String {
        let key = table.has("Z_PK") ? "Z_PK" : table.columns.keys.sorted().first.map(Self.quote) ?? "1"
        let times = [("ZSTARTTIMEVALUE", "ZSTARTTIMESCALE"), ("ZTIMESTAMPVALUE", "ZTIMESTAMPSCALE"), ("ZKEYFRAMETIMEVALUE", "ZKEYFRAMETIMESCALE")].compactMap { value, scale -> String? in
            guard table.has(value, scale) else { return nil }
            let v = Self.quote(value), s = Self.quote(scale), seconds = "(CAST(\(v) AS REAL) / \(s))"
            return "CASE WHEN typeof(\(v)) IN ('integer','real') AND typeof(\(s)) IN ('integer','real') AND \(s)>0 AND abs(CAST(\(v) AS REAL))<=1.7976931348623157e308 AND \(s)<=1.7976931348623157e308 AND abs(\(seconds))<=1.7976931348623157e308 THEN \(seconds) END"
        }
        guard !times.isEmpty else { return key }
        let time = times.count == 1 ? times[0] : "coalesce(\(times.joined(separator: ", ")))"
        return "(\(time)) IS NULL, (\(time)), \(key)"
    }
    /// Read only explicitly supported analysis payloads for the already selected
    /// page. Token/bookmark fields never enter this path. Each BLOB is <=64 KiB;
    /// the total byte budget is bounded independently of the row count.
    public func analysisRows(table: TableSchema, offset: Int = 0, assetKey: String) throws -> [DBRow] {
        let rows = try rows(table: table, offset: offset, limit: 100, assetKey: assetKey).map { DBRow(id: offset + $0.id, fields: $0.fields) }
        var byteBudget = 4 * 1024 * 1024
        return try decodeAnalysis(rows, table: table, assetKey: assetKey, byteBudget: &byteBudget)
    }
    public func analysisRecords(table: TableSchema, assetKey: String, field: String, value: String) throws -> [DBRow] {
        guard table.name.contains("RESULT"), table.has("ZASSET", "Z_PK"), table.columns[field] != nil,
              ["Z_PK", "ZFACEID", "ZEMBEDDINGID", "ZTHUMBNAILID"].contains(field) else { throw ExplorerError("Unsupported analysis reference") }
        let rows = try query("SELECT \(projection(table)) FROM \(Self.quote(table.name)) WHERE ZASSET=? AND \(Self.quote(field))=? ORDER BY \(Self.analysisOrder(table)) LIMIT 100", parameters: [assetKey, value])
        var byteBudget = 4 * 1024 * 1024
        return try decodeAnalysis(rows, table: table, assetKey: assetKey, byteBudget: &byteBudget)
    }
    public func geometryRows(_ rows: [DBRow], table: TableSchema, assetKey: String) throws -> (rows: [DBRow], budgetExhausted: Bool) {
        var result: [DBRow] = []; var byteBudget = 4 * 1024 * 1024
        for offset in stride(from: 0, to: rows.count, by: 100) {
            try budget.check()
            let page = Array(rows[offset..<min(offset + 100, rows.count)])
            result += try decodeAnalysis(page, table: table, assetKey: assetKey, allowed: ["ZOBJECTBOUNDS", "ZFACERESULTS", "ZKEYPOINTS", "ZACTIONSCONFIDENCE"], byteBudget: &byteBudget)
        }
        return (result, byteBudget == 0)
    }
    private func decodeAnalysis(_ rows: [DBRow], table: TableSchema, assetKey: String, allowed: Set<String> = AnalysisPayload.columns, byteBudget: inout Int) throws -> [DBRow] {
        let columns = table.columns.keys.filter { allowed.contains($0) }.sorted()
        guard table.name.contains("RESULT"), table.has("ZASSET", "Z_PK"), !columns.isEmpty, !rows.isEmpty else { return rows }
        let keys = rows.map { $0["Z_PK"] }
        var sourceRows: [String: DBRow] = [:]
        for row in rows { sourceRows[row["Z_PK"]] = row }
        let selection = columns.map { "CASE WHEN typeof(\(Self.quote($0)))='blob' AND length(\(Self.quote($0)))<=65536 THEN \(Self.quote($0)) ELSE NULL END" }.joined(separator: ",")
        let sql = "SELECT Z_PK,\(selection) FROM \(Self.quote(table.name)) WHERE ZASSET=? AND Z_PK IN (\(keys.map { _ in "?" }.joined(separator: ",")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in ([assetKey] + keys).enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        var decoded: [String: [String: DecodedPayload]] = [:]
        while true {
            try budget.check()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let key = sqlite3_column_text(statement, 0) else { throw error() }
            let record = String(cString: key)
            for (index, column) in columns.enumerated() {
                if column == "ZEMBEDDINGDATA", sourceRows[record]?["ZEMBEDDINGVERSION"] != "10" { continue }
                let position = Int32(index + 1)
                guard sqlite3_column_type(statement, position) == SQLITE_BLOB else { continue }
                let size = Int(sqlite3_column_bytes(statement, position))
                guard size > 0, size <= 65536, let pointer = sqlite3_column_blob(statement, position) else { continue }
                guard size <= byteBudget else { byteBudget = 0; continue }
                byteBudget -= size
                if let value = AnalysisPayload.decode(Data(bytes: pointer, count: size), column: column, table: table.name) { decoded[record, default: [:]][column] = value }
            }
        }
        return rows.map { DBRow(id: $0.id, fields: $0.fields, decoded: decoded[$0["Z_PK"]] ?? [:]) }
    }
}
