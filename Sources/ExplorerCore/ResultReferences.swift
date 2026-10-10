import Foundation

public struct ResultReference: Identifiable, Sendable {
    public var id: String { table + ":" + field + ":" + value }
    public let table: String
    public let field: String
    public let value: String
    public let label: String
    public init(table: String, field: String, value: String, label: String) { self.table = table; self.field = field; self.value = value; self.label = label }
}
public enum ResultReferences {
    public static func links(row: DBRow, table: String) -> [ResultReference] {
        var links: [ResultReference] = []
        func add(_ target: String, _ field: String, _ value: String, _ label: String) {
            guard value != "NULL", !value.isEmpty else { return }
            links.append(ResultReference(table: target, field: field, value: value, label: label))
        }
        if table == "ZFACEPRINTRESULT" { add("ZFACERESULT", "ZFACEID", row["ZFACEID"], "Face detection · ID " + row["ZFACEID"]) }
        if table == "ZFACERESULT" { add("ZFACEPRINTRESULT", "ZFACEID", row["ZFACEID"], "Face/torso descriptors · ID " + row["ZFACEID"]) }
        if table == "ZVIDEOEMBEDDINGRESULT" { add("ZAUDIOFUSEDVIDEOEMBEDDINGRESULT", "ZEMBEDDINGID", row["ZEMBEDDINGID"], "Fused audio/video embedding · ID " + row["ZEMBEDDINGID"]) }
        if table == "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT" { add("ZVIDEOEMBEDDINGRESULT", "ZEMBEDDINGID", row["ZEMBEDDINGID"], "Video embedding · ID " + row["ZEMBEDDINGID"]) }
        if table == "ZSUMMARIZEDEMBEDDINGRESULT" {
            for id in Set(row.decoded["ZEMBEDDINGIDS"]?.referenceValues ?? []).sorted() {
                add("ZVIDEOEMBEDDINGRESULT", "ZEMBEDDINGID", id, "Video embedding · ID " + id)
                add("ZAUDIOFUSEDVIDEOEMBEDDINGRESULT", "ZEMBEDDINGID", id, "Fused embedding · ID " + id)
            }
            for id in Set(row.decoded["ZTHUMBNAILIDS"]?.referenceValues ?? []).sorted() { add("ZVIDEOTHUMBNAILRESULT", "ZTHUMBNAILID", id, "Thumbnail analysis · " + id) }
        }
        return links
    }
}
public struct LinkedRecords: Identifiable, Sendable {
    public var id: String { reference.id }
    public let reference: ResultReference
    public let rows: [DBRow]
    public init(reference: ResultReference, rows: [DBRow]) { self.reference = reference; self.rows = rows }
}
