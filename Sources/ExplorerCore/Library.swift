import Foundation

public struct SourceConfiguration: Sendable, Equatable {
    public var analysisPath: String
    public var photosPath: String
    public var libraryPath: String
    public var isFixture: Bool
    public init(analysisPath: String = "", photosPath: String = "", libraryPath: String = "", isFixture: Bool = false) {
        self.analysisPath = analysisPath; self.photosPath = photosPath; self.libraryPath = libraryPath; self.isFixture = isFixture
    }
    public static func library(_ url: URL) -> Self {
        Self(analysisPath: url.appendingPathComponent("private/com.apple.mediaanalysisd/MediaAnalysis/MediaAnalysis.sqlite").path,
             photosPath: url.appendingPathComponent("database/Photos.sqlite").path, libraryPath: url.path)
    }
}

public enum AssetIdentifier {
    public static func uuid(_ identifier: String) -> String? {
        let component = identifier.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard component.count == 36, let uuid = UUID(uuidString: component) else { return nil }
        return uuid.uuidString
    }
}

public struct MediaAsset: Identifiable, Sendable {
    public let id: String
    public let identifier: String
    public let fields: [String: String]
    public let displayName: String?
    public init(id: String, identifier: String, fields: [String: String], displayName: String? = nil) {
        self.id = id; self.identifier = identifier; self.fields = fields; self.displayName = displayName
    }
}
public struct MediaPage: Sendable {
    public let assets: [MediaAsset]
    public let hasNext: Bool
    public let photosWarning: String?
}
public struct ResolvedMedia: Sendable {
    public let uuid: String
    public let filename: String
    public let originalName: String
    public let originalURL: URL?
    public let availability: String
    public let location: GeoCoordinate?
    public init(uuid: String, filename: String, originalName: String, originalURL: URL?, availability: String, location: GeoCoordinate? = nil) {
        self.uuid = uuid; self.filename = filename; self.originalName = originalName; self.originalURL = originalURL; self.availability = availability; self.location = location
    }
}
public struct ResultFamily: Identifiable, Sendable {
    public var id: String { table.name }
    public let table: TableSchema
    public let count: Int
    public let rows: [DBRow]
    public init(table: TableSchema, count: Int, rows: [DBRow]) { self.table = table; self.count = count; self.rows = VisualMetadata.chronologicalRows(rows) }
}
public struct AssetDetail: Sendable {
    public let media: ResolvedMedia?
    public let linkageNote: String
    public let families: [ResultFamily]
    public let regionTimeline: RegionTimeline
    public let playbackTimeline: PlaybackTimeline
    public let persistence: PersistenceHistory
    public init(media: ResolvedMedia?, linkageNote: String, families: [ResultFamily], playbackTimeline: PlaybackTimeline? = nil, persistence: PersistenceHistory = .empty, regions: [StoredRegion]? = nil) {
        self.media = media; self.linkageNote = linkageNote; self.families = families
        self.persistence = persistence
        regionTimeline = RegionTimeline(regions: regions ?? families.flatMap(VisualMetadata.regions))
        self.playbackTimeline = playbackTimeline ?? PlaybackTimeline(families: families)
    }
    public func appending(_ rows: [DBRow], to table: String) -> Self {
        let updated = families.map { family in
            family.id == table ? ResultFamily(table: family.table, count: family.count, rows: family.rows + rows) : family
        }
        var seen: Set<String> = []
        let regions = (regionTimeline.regions + updated.flatMap(VisualMetadata.regions)).filter { seen.insert($0.id).inserted }
        return Self(media: media, linkageNote: linkageNote, families: updated, playbackTimeline: playbackTimeline, persistence: persistence, regions: regions)
    }
}

public enum LibraryReader {
    /// Resolves a picker selection independently of the paginated record list.
    /// Prefer the full local identifier; UUID linkage is accepted only when unique.
    public static func asset(identifier: String, source: SourceConfiguration, budget: WorkBudget) throws -> MediaAsset? {
        guard let uuid = AssetIdentifier.uuid(identifier) else { throw ExplorerError("The selected photo has no valid Photos asset identifier.") }
        let db = try ReadDatabase(path: source.analysisPath, budget: budget)
        guard let table = try db.schema().first(where: { $0.name == "ZASSET" }), table.has("Z_PK", "ZLOCALIDENTIFIER") else {
            throw ExplorerError("This source has no compatible analysis asset table.")
        }
        let projection = db.projection(table)
        var rows = try db.query("SELECT \(projection) FROM ZASSET WHERE ZLOCALIDENTIFIER = ? COLLATE NOCASE LIMIT 2", parameters: [identifier])
        if rows.isEmpty {
            rows = try db.query("SELECT \(projection) FROM ZASSET WHERE ZLOCALIDENTIFIER = ? COLLATE NOCASE OR ZLOCALIDENTIFIER LIKE ? COLLATE NOCASE LIMIT 2", parameters: [uuid, uuid + "/%"])
        }
        guard rows.count <= 1 else { throw ExplorerError("Multiple analysis assets match this Photos identifier; no record was selected.") }
        guard let row = rows.first else { return nil }
        return MediaAsset(id: row["Z_PK"], identifier: row["ZLOCALIDENTIFIER"], fields: row.fields)
    }

    /// Trace-observed derivative convention. Existence/readability is verified
    /// separately; a matching identifier alone does not prove image content.
    public static func thumbnailURL(identifier: String, thumbnailID: String, source: SourceConfiguration) throws -> URL {
        guard !source.libraryPath.isEmpty, let uuid = AssetIdentifier.uuid(identifier),
              thumbnailID.range(of: #"^t[0-9]{4}$"#, options: .regularExpression) != nil else { throw ExplorerError("Unsupported thumbnail reference or unavailable library root") }
        let library = URL(fileURLWithPath: source.libraryPath).resolvingSymlinksInPath()
        let root = library.appendingPathComponent("resources/derivatives/cvt").resolvingSymlinksInPath()
        guard root.path.hasPrefix(library.path + "/") else { throw ExplorerError("Derivative directory escapes the chosen library") }
        let url = root.appendingPathComponent(String(uuid.prefix(1))).appendingPathComponent(uuid).appendingPathComponent(uuid + "_cvt_" + thumbnailID + ".jpeg").resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw ExplorerError("Derivative path escapes the library's derivative directory") }
        return url
    }
    public static func assets(source: SourceConfiguration, search: String, after: Int64 = 0, budget: WorkBudget) throws -> MediaPage {
        let db = try ReadDatabase(path: source.analysisPath, budget: budget)
        guard let table = try db.schema().first(where: { $0.name == "ZASSET" }), table.has("Z_PK", "ZLOCALIDENTIFIER") else {
            throw ExplorerError("This database has no compatible ZASSET table. User-level databases can be browsed in Processing.")
        }
        var condition = "Z_PK > ?"; var values = [String(after)]; var warning: String?
        if !search.isEmpty {
            condition += " AND (ZLOCALIDENTIFIER LIKE ? ESCAPE '\\'"
            let pattern = "%" + search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            values.append(pattern)
            if !source.photosPath.isEmpty {
                do {
                    let photos = try ReadDatabase(path: source.photosPath, budget: budget)
                    let schema = try photos.schema()
                    if let asset = schema.first(where: { $0.name == "ZASSET" }), asset.has("ZUUID", "ZFILENAME") {
                        let additional = schema.first { $0.name == "ZADDITIONALASSETATTRIBUTES" }
                        let canJoin = asset.has("ZADDITIONALATTRIBUTES") && additional?.has("Z_PK", "ZORIGINALFILENAME") == true
                        let join = canJoin ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK = a.ZADDITIONALATTRIBUTES" : ""
                        let predicate = canJoin ? "a.ZFILENAME LIKE ? ESCAPE '\\' OR aa.ZORIGINALFILENAME LIKE ? ESCAPE '\\'" : "a.ZFILENAME LIKE ? ESCAPE '\\'"
                        let matches = try photos.query("SELECT a.ZUUID FROM ZASSET a \(join) WHERE \(predicate) LIMIT 501", parameters: canJoin ? [pattern, pattern] : [pattern])
                        if matches.count > 500 { warning = "Filename search capped at 500 matches; narrow the search." }
                        for row in matches.prefix(500) {
                            if let uuid = AssetIdentifier.uuid(row["ZUUID"]) {
                                condition += " OR ZLOCALIDENTIFIER = ? COLLATE NOCASE OR ZLOCALIDENTIFIER LIKE ? COLLATE NOCASE"
                                values += [uuid, uuid + "/%"]
                            }
                        }
                    } else { warning = "Photos filename search unavailable: missing UUID/filename columns." }
                } catch { warning = "Filename search unavailable: \(error.localizedDescription)" }
            }
            condition += ")"
        }
        let rows = try db.query("SELECT \(db.projection(table)) FROM ZASSET WHERE \(condition) ORDER BY Z_PK LIMIT 101", parameters: values)
        var names: [String: String] = [:]
        let uuids = rows.prefix(100).compactMap { AssetIdentifier.uuid($0["ZLOCALIDENTIFIER"]) }
        if !source.photosPath.isEmpty && !uuids.isEmpty {
            do {
                let photos = try ReadDatabase(path: source.photosPath, budget: budget)
                let schema = try photos.schema()
                if let table = schema.first(where: { $0.name == "ZASSET" }), table.has("ZUUID", "ZFILENAME") {
                    let join = table.has("ZADDITIONALATTRIBUTES") && schema.contains { $0.name == "ZADDITIONALASSETATTRIBUTES" && $0.has("Z_PK", "ZORIGINALFILENAME") }
                    let fields = join ? "COALESCE(aa.ZORIGINALFILENAME,a.ZFILENAME) AS name" : "a.ZFILENAME AS name"
                    let joined = join ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK=a.ZADDITIONALATTRIBUTES" : ""
                    let placeholders = Array(repeating: "?", count: uuids.count).joined(separator: ",")
                    for row in try photos.query("SELECT a.ZUUID, \(fields) FROM ZASSET a \(joined) WHERE a.ZUUID COLLATE NOCASE IN (\(placeholders))", parameters: uuids) {
                        names[row["ZUUID"].uppercased()] = row["name"]
                    }
                }
            } catch { warning = "Photos filenames unavailable: \(error.localizedDescription)" }
        }
        return MediaPage(assets: rows.prefix(100).map {
            MediaAsset(id: $0["Z_PK"], identifier: $0["ZLOCALIDENTIFIER"], fields: $0.fields,
                       displayName: AssetIdentifier.uuid($0["ZLOCALIDENTIFIER"]).flatMap { names[$0] })
        }, hasNext: rows.count > 100, photosWarning: warning)
    }
    public static func resolve(identifier: String, source: SourceConfiguration, budget: WorkBudget) throws -> ResolvedMedia? {
        guard let uuid = AssetIdentifier.uuid(identifier) else { throw ExplorerError("Identifier does not start with a valid UUID; the raw identifier is preserved.") }
        guard !source.photosPath.isEmpty else { return nil }
        let db = try ReadDatabase(path: source.photosPath, budget: budget)
        let schema = try db.schema()
        guard let asset = schema.first(where: { $0.name == "ZASSET" }), asset.has("ZUUID", "ZDIRECTORY", "ZFILENAME") else {
            throw ExplorerError("Photos schema is missing ZUUID, ZDIRECTORY, or ZFILENAME.")
        }
        let additional = schema.first { $0.name == "ZADDITIONALASSETATTRIBUTES" }
        let canJoin = asset.has("ZADDITIONALATTRIBUTES") && additional?.has("Z_PK", "ZORIGINALFILENAME") == true
        let join = canJoin ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK = a.ZADDITIONALATTRIBUTES" : ""
        let name = canJoin ? "aa.ZORIGINALFILENAME" : "NULL AS ZORIGINALFILENAME"
        let coordinates = asset.has("ZLATITUDE", "ZLONGITUDE") ? "a.ZLATITUDE, a.ZLONGITUDE" : "NULL AS ZLATITUDE, NULL AS ZLONGITUDE"
        guard let row = try db.query("SELECT a.ZUUID, a.ZDIRECTORY, a.ZFILENAME, \(name), \(coordinates) FROM ZASSET a \(join) WHERE a.ZUUID COLLATE NOCASE = ? LIMIT 1", parameters: [uuid]).first else { return nil }
        let directory = row["ZDIRECTORY"], filename = row["ZFILENAME"]
        var url: URL?; var availability = "Choose the original library folder to check availability."
        // Private database strings must never escape the chosen library via traversal or symlinks.
        if !source.libraryPath.isEmpty {
            let root = URL(fileURLWithPath: source.libraryPath).appendingPathComponent("originals").resolvingSymlinksInPath()
            let candidate = root.appendingPathComponent(directory).appendingPathComponent(filename).resolvingSymlinksInPath()
            if directory == "NULL" || filename == "NULL" || !candidate.path.hasPrefix(root.path + "/") {
                availability = "Unsafe or missing original path components; no file opened."
            } else {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                    if attributes[.type] as? FileAttributeType == .typeRegular {
                        url = candidate; availability = "Original exists locally (database linkage)."
                    } else { availability = "Original path is not a regular file." }
                } catch {
                    availability = "Original unavailable: \(error.localizedDescription). It may be undownloaded, moved, or inaccessible."
                }
            }
        }
        let location: GeoCoordinate?
        if let lat = Double(row["ZLATITUDE"]), let lon = Double(row["ZLONGITUDE"]), (lat != 0 || lon != 0), GeoCoordinate(latitude: lat, longitude: lon).isValid {
            location = GeoCoordinate(latitude: lat, longitude: lon)
        } else { location = nil }
        return ResolvedMedia(uuid: uuid, filename: filename, originalName: row["ZORIGINALFILENAME"] == "NULL" ? filename : row["ZORIGINALFILENAME"], originalURL: url, availability: availability, location: location)
    }
    public static func detail(asset: MediaAsset, source: SourceConfiguration, budget: WorkBudget) throws -> AssetDetail {
        let db = try ReadDatabase(path: source.analysisPath, budget: budget)
        var families: [ResultFamily] = []
        let schema = try db.schema()
        for table in schema where table.name.contains("RESULT") && table.has("ZASSET") {
            let count = Int(try db.query("SELECT count(*) AS n FROM \(ReadDatabase.quote(table.name)) WHERE ZASSET = ?", parameters: [asset.id]).first?["n"] ?? "0") ?? 0
            if count > 0 { families.append(ResultFamily(table: table, count: count, rows: try db.analysisRows(table: table, assetKey: asset.id))) }
        }
        var resolved: ResolvedMedia?; var note = "No matching Photos record. No processing cause is established."
        do {
            resolved = try resolve(identifier: asset.identifier, source: source, budget: budget)
            if resolved != nil { note = "Linked by normalized UUID through Photos records. This does not attribute CPU activity or a model cache to the asset." }
        } catch { note = error.localizedDescription }
        var timing: [ResultFamily] = []; var timingIssues: [String] = []; var remaining = 10_000
        var fullGeometry = families.flatMap(VisualMetadata.regions)
        let geometryColumns: Set<String> = ["ZX", "ZTORSOX", "ZPETSBOUNDX", "ZBESTPLAYBACKCROPX", "ZOBJECTBOUNDS", "ZFACERESULTS", "ZKEYPOINTS"]
        for family in families where family.table.has("ZSTARTTIMEVALUE", "ZSTARTTIMESCALE") || family.table.has("ZTIMESTAMPVALUE", "ZTIMESTAMPSCALE") || !geometryColumns.isDisjoint(with: family.table.columns.keys) {
            guard remaining > 0, !budget.stopped else { timingIssues.append("Timing inventory reached its row/time budget; active results may be incomplete."); break }
            do {
                let limit = min(remaining, 2000)
                let order = ReadDatabase.analysisOrder(family.table)
                let rows = try db.query("SELECT \(db.projection(family.table)) FROM \(ReadDatabase.quote(family.id)) WHERE ZASSET=? ORDER BY \(order) LIMIT \(limit)", parameters: [asset.id])
                remaining -= rows.count
                if rows.count < family.count { timingIssues.append("\(VisualMetadata.title(family.id)): timing read covers \(rows.count) of \(family.count) records.") }
                if !geometryColumns.isDisjoint(with: family.table.columns.keys) {
                    let geometry = try db.geometryRows(rows, table: family.table, assetKey: asset.id)
                    if geometry.budgetExhausted { timingIssues.append("\(VisualMetadata.title(family.id)): geometry payload byte budget exhausted.") }
                    let regions = VisualMetadata.regions(ResultFamily(table: family.table, count: family.count, rows: geometry.rows))
                    var seen: Set<String> = []
                    fullGeometry = (fullGeometry + regions).filter { seen.insert($0.id).inserted }
                }
                var payloads: [String: [String: DecodedPayload]] = [:]
                for loaded in family.rows where loaded["Z_PK"] != "NULL" { payloads[loaded["Z_PK"]] = loaded.decoded }
                let interpreted = rows.map { DBRow(id: $0.id, fields: $0.fields, decoded: payloads[$0["Z_PK"]] ?? [:]) }
                timing.append(ResultFamily(table: family.table, count: family.count, rows: interpreted))
            } catch { timingIssues.append("\(VisualMetadata.title(family.id)): timing read unavailable.") }
        }
        let spatialRecords = Set(fullGeometry.map { $0.table + ":" + $0.record })
        let persistence = PersistenceReader.read(db: db, schema: schema, assetKey: asset.id)
        return AssetDetail(media: resolved, linkageNote: note, families: families, playbackTimeline: PlaybackTimeline(families: timing, issues: timingIssues, excludingSpatial: spatialRecords), persistence: persistence, regions: fullGeometry)
    }
}
