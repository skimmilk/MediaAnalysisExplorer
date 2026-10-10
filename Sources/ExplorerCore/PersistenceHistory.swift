import Foundation
import Compression
import CSQLite

public struct PersistenceEvent: Identifiable, Sendable {
    public let id: String
    public let date: Date?
    public let bundle: String
    public let process: String
    public let changes: Int
    public let entities: String
    public let types: String
}
public struct PersistenceHistory: Sendable {
    public let events: [PersistenceEvent]
    public let modelFields: [String: String]
    public let issues: [String]
    public static let empty = Self(events: [], modelFields: [:], issues: [])
}
public enum PersistenceReader {
    public static func read(db: ReadDatabase, schema: [TableSchema], assetKey: String? = nil) -> PersistenceHistory {
        var events: [PersistenceEvent] = []; var fields: [String: String] = [:]; var issues: [String] = []
        if let transactions = schema.first(where: { $0.name == "ATRANSACTION" }), transactions.has("Z_PK", "ZTIMESTAMP"),
           let changes = schema.first(where: { $0.name == "ACHANGE" }), changes.has("ZTRANSACTIONID", "ZENTITY", "ZENTITYPK", "ZCHANGETYPE"),
           let primary = schema.first(where: { $0.name == "Z_PRIMARYKEY" }), primary.has("Z_ENT", "Z_NAME") {
            do {
                var predicate = "1"; var parameters: [String] = []
                if let assetKey {
                    var matching = ["(p.Z_NAME='Asset' AND c.ZENTITYPK=?)"]; parameters.append(assetKey)
                    for table in schema where table.name.contains("RESULT") && table.has("ZASSET", "Z_PK") {
                        // Entity names are provided by Core Data, not guessed numeric IDs.
                        matching.append("(upper('Z'||p.Z_NAME)=? AND c.ZENTITYPK IN (SELECT Z_PK FROM \(ReadDatabase.quote(table.name)) WHERE ZASSET=?))")
                        parameters += [table.name, assetKey]
                    }
                    predicate = matching.joined(separator: " OR ")
                }
                let hasStrings = schema.contains { $0.name == "ATRANSACTIONSTRING" && $0.has("Z_PK", "ZNAME") }
                let bundleJoin = hasStrings && transactions.has("ZBUNDLEIDTS") ? "LEFT JOIN ATRANSACTIONSTRING b ON b.Z_PK=t.ZBUNDLEIDTS" : ""
                let processJoin = hasStrings && transactions.has("ZPROCESSIDTS") ? "LEFT JOIN ATRANSACTIONSTRING s ON s.Z_PK=t.ZPROCESSIDTS" : ""
                let bundle = bundleJoin.isEmpty ? "NULL" : "b.ZNAME", process = processJoin.isEmpty ? "NULL" : "s.ZNAME"
                let rows = try db.query("""
                    SELECT t.Z_PK,t.ZTIMESTAMP,\(bundle) AS bundle,\(process) AS process,count(*) AS changes,
                    group_concat(DISTINCT p.Z_NAME) AS entities,group_concat(DISTINCT c.ZCHANGETYPE) AS types
                    FROM ATRANSACTION t JOIN ACHANGE c ON c.ZTRANSACTIONID=t.Z_PK
                    JOIN Z_PRIMARYKEY p ON p.Z_ENT=c.ZENTITY \(bundleJoin) \(processJoin)
                    WHERE \(predicate) GROUP BY t.Z_PK ORDER BY t.Z_PK DESC LIMIT 50
                    """, parameters: parameters)
                events = rows.map { row in
                    let date = Double(row["ZTIMESTAMP"]).flatMap { $0.isFinite && $0 > 0 && $0 < 100_000_000_000 ? Date(timeIntervalSinceReferenceDate: $0) : nil }
                    return PersistenceEvent(id: row["Z_PK"], date: date, bundle: row["bundle"], process: row["process"], changes: Int(row["changes"]) ?? 0, entities: row["entities"], types: row["types"])
                }
            } catch { issues.append("Persistence history unavailable: " + error.localizedDescription) }
        }
        if schema.contains(where: { $0.name == "Z_MODELCACHE" && $0.has("Z_CONTENT") }) {
            do {
                if let data = try db.modelCacheData() {
                    let decoded = try StaticGraphDecoder.decompress(data, algorithm: COMPRESSION_ZLIB, maximumBytes: 256 * 1024)
                    let counts = try modelCounts(decoded)
                    fields = ["Schema cache format": "Raw DEFLATE → binary keyed property list; managed-object schema, not inference weights",
                              "Stored / decoded bytes": "\(data.count) / \(decoded.count)", "Schema entities": String(counts.entities), "Schema properties": String(counts.properties),
                              "Schema interpretation": "Projected archive class/name metadata only. No managed-object model or private archived classes are instantiated."]
                }
            } catch { issues.append("Schema cache interpretation unavailable: " + error.localizedDescription) }
        }
        return PersistenceHistory(events: events, modelFields: fields, issues: issues)
    }
    public static func modelCounts(_ data: Data) throws -> (entities: Int, properties: Int) {
        guard data.count <= 256 * 1024, data.prefix(8) == Data("bplist00".utf8), let original = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], original["$archiver"] as? String == "NSKeyedArchiver" else { throw ExplorerError("Unsupported managed-object model archive") }
        let xml = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        guard xml.count <= 2 * 1024 * 1024 else { throw ExplorerError("Schema archive expansion exceeds limit") }
        let normalized = String(decoding: xml, as: UTF8.self).replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>__SchemaUID__</key>")
        guard let archive = try PropertyListSerialization.propertyList(from: Data(normalized.utf8), format: nil) as? [String: Any], let objects = archive["$objects"] as? [Any], objects.count <= 10000 else { throw ExplorerError("Schema object limit exceeded") }
        var entities = 0, properties = 0
        for case let object as [String: Any] in objects {
            guard let reference = object["$class"] as? [String: Int], let index = reference["__SchemaUID__"], objects.indices.contains(index), let type = objects[index] as? [String: Any], let name = type["$classname"] as? String else { continue }
            if name == "NSEntityDescription" { entities += 1 }
            if ["NSAttributeDescription", "NSRelationshipDescription"].contains(name) { properties += 1 }
        }
        guard entities > 0 else { throw ExplorerError("No recognized schema entities") }
        return (entities, properties)
    }
}
