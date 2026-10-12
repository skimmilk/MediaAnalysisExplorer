import Foundation

/// Persistent read-only connections let SQLite report commits from other clients,
/// including WAL commits. Polling this marker does not scan the result tables.
public actor ProcessingChangeMonitor {
    private let paths: [String]
    private var connections: [String: ReadDatabase] = [:]
    private var versions: [String: String] = [:]
    private var retryAfter: [String: Date] = [:]
    public init(databases: [DaemonDatabase]) {
        paths = databases.map { $0.source.analysisPath }
    }
    public func hasChanges() -> Bool {
        var changed = false
        for path in paths {
            guard !Task.isCancelled else { return false }
            if let retry = retryAfter[path], retry > Date() { continue }
            do {
                let db: ReadDatabase
                if let existing = connections[path], !existing.budget.stopped { db = existing }
                else {
                    db = try ReadDatabase(path: path, budget: WorkBudget(seconds: 3660))
                    connections[path] = db
                    versions.removeValue(forKey: path)
                }
                guard let version = try db.query("PRAGMA data_version").first?["data_version"] else { continue }
                // Refresh on the initial sample too, closing the gap between the
                // previous history read and the start of a launch session.
                if versions[path] != version { changed = true }
                versions[path] = version
                retryAfter.removeValue(forKey: path)
            } catch {
                connections.removeValue(forKey: path)
                versions.removeValue(forKey: path)
                // Protected or missing sources must not be reopened four times a second.
                retryAfter[path] = Date().addingTimeInterval(5)
            }
        }
        return changed
    }
}
