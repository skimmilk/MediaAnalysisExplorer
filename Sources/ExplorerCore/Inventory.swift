import Foundation
import CryptoKit

public struct InventoryFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64?
    public let modified: Date?
    public let labels: String
}
public struct InventoryUpdate: Sendable {
    public let files: [InventoryFile]
    public let visited: Int
    public let inaccessible: Int
    public let complete: Bool
    public let note: String
}
public struct FileInspection: Sendable {
    public let signature: String
    public let metadata: String?
    public let sha256: String?
    public let metadataFormat: String?
    public let metadataSHA256: String?
    public let metadataIssue: String?
    public let bnns: BNNSProgram?
    public let e5: E5Program?
    public init(signature: String, metadata: String?, sha256: String?, metadataFormat: String? = nil, metadataSHA256: String? = nil, metadataIssue: String? = nil, bnns: BNNSProgram? = nil, e5: E5Program? = nil) {
        self.signature = signature; self.metadata = metadata; self.sha256 = sha256
        self.metadataFormat = metadataFormat; self.metadataSHA256 = metadataSHA256; self.metadataIssue = metadataIssue
        self.bnns = bnns
        self.e5 = e5
    }
}
public enum Inventory {
    public static func scan(root: URL, budget: WorkBudget, maximumFiles: Int = 20_000, emit: (InventoryUpdate) -> Void) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var inaccessible = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in inaccessible += 1; return true }) else {
            throw ExplorerError("Unable to enumerate \(root.path)")
        }
        var chunk: [InventoryFile] = []; var seen: Set<String> = []; var visited = 0; var limited = false
        while let url = enumerator.nextObject() as? URL {
            if budget.stopped || visited >= maximumFiles { limited = true; break }
            visited += 1
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                // A file-resource identifier deduplicates hard links; enumeration never follows symlinks.
                let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? url.standardizedFileURL.path
                guard seen.insert(identity).inserted else { continue }
                let labels = url.pathComponents.filter { $0.hasSuffix(".bundle") || $0.range(of: "^[0-9]{2}[A-Z][0-9]+$", options: .regularExpression) != nil }.joined(separator: " / ")
                chunk.append(InventoryFile(url: url, logicalBytes: Int64(values.fileSize ?? 0), allocatedBytes: values.totalFileAllocatedSize.map(Int64.init), modified: values.contentModificationDate, labels: labels))
                if chunk.count >= 200 { emit(InventoryUpdate(files: chunk, visited: visited, inaccessible: inaccessible, complete: false, note: "Scanning…")); chunk = [] }
            } catch { inaccessible += 1 }
        }
        emit(InventoryUpdate(files: chunk, visited: visited, inaccessible: inaccessible, complete: true,
                             note: limited ? "Partial inventory: cancelled, 15-second budget, or \(maximumFiles)-entry limit reached." : "Inventory finished. Counts describe readable, unique files only."))
    }
    public static func inspect(url: URL, hash: Bool, budget: WorkBudget) throws -> FileInspection {
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard before.isRegularFile == true else { throw ExplorerError("Select a regular file") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let prefix = try file.read(upToCount: 64) ?? Data()
        let signature = prefix.map { String(format: "%02x", $0) }.joined(separator: " ")
        var metadata: String?; var metadataFormat: String?; var metadataSHA256: String?; var metadataIssue: String?
        var bnns: BNNSProgram?
        var e5: E5Program?
        if url.pathExtension.lowercased() == "e5" {
            do {
                try budget.check()
                guard let size = before.fileSize, size >= 8, size <= E5Program.byteLimit else { throw ExplorerError("E5 file is truncated or exceeds the 1 MiB limit") }
                try file.seek(toOffset: 0)
                let data = try file.read(upToCount: size + 1) ?? Data()
                guard data.count == size else { throw ExplorerError("E5 file length changed while reading") }
                let decoded = try E5Program.decode(data, budget: budget)
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ExplorerError("E5 file changed while reading; decoded metadata discarded") }
                e5 = decoded
            } catch { metadataIssue = "E5 program unavailable: " + error.localizedDescription }
        }
        if url.pathExtension.lowercased() == "bnnsir" {
            do {
                try budget.check(); try file.seek(toOffset: 0)
                let data = try file.read(upToCount: BNNSProgram.metadataLimit) ?? Data()
                let size = Int64(before.fileSize ?? 0)
                var trailer: Data?
                if let range = try BNNSProgram.trailerRange(data, fileSize: size), range.count > 0 {
                    try file.seek(toOffset: range.offset); trailer = try file.read(upToCount: range.count)
                }
                let decoded = try BNNSProgram.decode(data, fileSize: size, compilerTrailer: trailer, budget: budget)
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ExplorerError("BNNS file changed while reading; decoded metadata discarded") }
                bnns = decoded
            } catch { metadataIssue = "BNNS program unavailable: " + error.localizedDescription }
        }
        if ["json", "plist", "mil", "net", "shape"].contains(url.pathExtension.lowercased()) {
            try file.seek(toOffset: 0)
            let data = try file.read(upToCount: 256 * 1024) ?? Data()
            if data.prefix(4) == Data("pbze".utf8) {
                do {
                    guard before.fileSize == data.count else { throw ExplorerError("Compressed graph exceeds the 256 KiB input limit") }
                    let decoded = try StaticGraphDecoder.decode(data)
                    metadata = decoded.text; metadataFormat = decoded.encoding; metadataSHA256 = decoded.sha256
                } catch { metadataIssue = error.localizedDescription }
            } else if url.pathExtension == "plist", let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                metadata = String(describing: object)
            } else { metadata = String(data: data, encoding: .utf8) }
            if (before.fileSize ?? 0) > data.count { metadata = (metadata ?? "") + "\n[Metadata truncated at 256 KiB]" }
        }
        var digest: String?
        if hash {
            try file.seek(toOffset: 0); var hasher = SHA256()
            while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { try budget.check(); hasher.update(data: block) }
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ExplorerError("File changed while hashing; digest discarded.") }
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return FileInspection(signature: signature, metadata: metadata, sha256: digest, metadataFormat: metadataFormat, metadataSHA256: metadataSHA256, metadataIssue: metadataIssue, bnns: bnns, e5: e5)
    }
}
