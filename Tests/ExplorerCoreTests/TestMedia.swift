import Foundation
@testable import ExplorerCore
import CryptoKit

public struct TestMediaItem: Codable, Sendable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let source: String
    public let creator: String
    public let license: String
    public let targets: [String]
    public let sha256: String
}
public struct TestMediaManifest: Codable, Sendable {
    public let album: String
    public let items: [TestMediaItem]
    public func validatedFiles(at directory: URL) throws -> [URL] {
        guard !items.isEmpty, items.count <= 100, Set(items.map(\.filename)).count == items.count else { throw ExplorerError("Invalid test manifest item count or duplicate names.") }
        let root = directory.resolvingSymlinksInPath()
        return try items.map { item in
            guard item.filename == (item.filename as NSString).lastPathComponent, !item.filename.hasPrefix(".") else { throw ExplorerError("Unsafe test media filename.") }
            let url = root.appendingPathComponent(item.filename).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ExplorerError("Test media must be a regular file inside the batch.") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == item.sha256 else { throw ExplorerError("Checksum mismatch for \(item.filename).") }
            return url
        }
    }
}
public struct TestImportEntry: Codable, Sendable {
    public let filename: String
    public let localIdentifier: String
    public init(filename: String, localIdentifier: String) { self.filename = filename; self.localIdentifier = localIdentifier }
}
public struct TestImportReceipt: Codable, Sendable {
    public let albumIdentifier: String
    public let date: Date
    public let entries: [TestImportEntry]
    public init(albumIdentifier: String, date: Date, entries: [TestImportEntry]) { self.albumIdentifier = albumIdentifier; self.date = date; self.entries = entries }
}
public struct TestCoverage: Codable, Sendable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let localIdentifier: String
    public let analysisKey: String?
    public let tables: [String: Int]
    public let regionCount: Int
    public let captions: [String]
    public let note: String
}
public enum TestCoverageReader {
    public static func read(receipt: TestImportReceipt, source: SourceConfiguration, budget: WorkBudget) throws -> [TestCoverage] {
        let db = try ReadDatabase(path: source.analysisPath, budget: budget)
        let schema = try db.schema()
        guard schema.contains(where: { $0.name == "ZASSET" && $0.has("ZLOCALIDENTIFIER", "Z_PK") }) else { throw ExplorerError("Choose Photos analysis to check test results.") }
        return try receipt.entries.map { item in
            guard let uuid = AssetIdentifier.uuid(item.localIdentifier) else { throw ExplorerError("Invalid imported Photos identifier.") }
            let found = try db.query("SELECT \(db.projection(schema.first { $0.name == "ZASSET" }!)) FROM ZASSET WHERE ZLOCALIDENTIFIER = ? COLLATE NOCASE OR ZLOCALIDENTIFIER = ? COLLATE NOCASE OR ZLOCALIDENTIFIER LIKE ? COLLATE NOCASE LIMIT 1", parameters: [item.localIdentifier, uuid, uuid + "/%"])
            guard let row = found.first else {
                return TestCoverage(filename: item.filename, localIdentifier: item.localIdentifier, analysisKey: nil, tables: [:], regionCount: 0, captions: [], note: "No analysis asset yet. Photos import does not force the daemon to process it.")
            }
            let detail = try LibraryReader.detail(asset: MediaAsset(id: row["Z_PK"], identifier: row["ZLOCALIDENTIFIER"], fields: row.fields), source: source, budget: budget)
            return TestCoverage(filename: item.filename, localIdentifier: item.localIdentifier, analysisKey: row["Z_PK"],
                                tables: Dictionary(uniqueKeysWithValues: detail.families.map { ($0.id, $0.count) }),
                                regionCount: detail.families.flatMap(VisualMetadata.regions).count,
                                captions: detail.families.flatMap(\.rows).compactMap { $0.fields["ZCAPTION"].flatMap { $0 == "NULL" ? nil : $0 } },
                                note: detail.families.isEmpty ? "Asset exists; no stored result rows yet." : "Stored rows found; overlay coordinates still require visual alignment review.")
        }
    }
}
