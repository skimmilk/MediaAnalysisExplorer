import Foundation

public enum TimedResultKind: String, Sendable {
    case caption, audio, activity, measurement, representation
}
public struct TimedResult: Identifiable, Sendable {
    public let id: String
    public let table: String
    public let title: String
    public let row: DBRow
    public let fields: [String: String]
    public let kind: TimedResultKind
    public let start: Double
    public let duration: Double?
    public var end: Double? { duration.flatMap { $0 > 0 ? start + $0 : nil } }
    public var caption: String? { row.fields["ZCAPTION"].flatMap { $0 == "NULL" ? nil : $0 } }
    public func active(at seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        if let end { return seconds >= start && seconds < end }
        return abs(seconds - start) < 0.15
    }
}

/// A playback class keeps overlapping predictions together without merging their
/// confidence values or changing the stored intervals. Watched classes survive gaps.
public struct TimedResultGroup: Identifiable, Sendable {
    public var id: String { table }
    public let table: String
    public let records: [TimedResult]
    public var title: String { VisualMetadata.title(table) }
    public static func grouped(_ records: [TimedResult], watching: [String] = []) -> [Self] {
        let byTable = Dictionary(grouping: records, by: \.table)
        let watched = orderedClasses(watching)
        let tables = watched + byTable.keys.filter { !watched.contains($0) }.sorted {
            let lhs = VisualMetadata.title($0), rhs = VisualMetadata.title($1)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        return tables.map { table in
            let rows = (byTable[table] ?? []).sorted { a, b in
                if table == "ZCLASSIFICATIONRESULT" {
                    let lhs = Double(a.row["ZCONFIDENCE"]).flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
                    let rhs = Double(b.row["ZCONFIDENCE"]).flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
                    if lhs != rhs { return lhs > rhs }
                }
                return a.start == b.start ? a.id < b.id : a.start < b.start
            }
            return Self(table: table, records: rows)
        }
    }
    public static func orderedClasses(_ classes: [String]) -> [String] {
        var seen: Set<String> = []
        return classes.filter { $0.hasPrefix("Z") && $0.count <= 128 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && seen.insert($0).inserted }
    }
}

/// Includes only timed rows without a displayed spatial region. The complete
/// timing query is separate from the paged metadata-card query.
public struct PlaybackTimeline: Sendable {
    public let revision = UUID()
    public let records: [TimedResult]
    public let issues: [String]
    public let audio: AudioTimelineData
    public let classes: [String]
    private let lookup: IntervalLookup
    public init(families: [ResultFamily], issues: [String] = [], excludingSpatial: Set<String> = []) {
        self.issues = issues
        records = families.flatMap { family -> [TimedResult] in
            let spatial = Set(VisualMetadata.regions(family).map(\.record))
            return family.rows.compactMap { row in
                let record = row.fields["Z_PK"] ?? String(row.id)
                guard !spatial.contains(record), !excludingSpatial.contains(family.id + ":" + record), let start = VisualMetadata.eventTime(row) else { return nil }
                let kind: TimedResultKind
                if family.id.contains("CAPTION") { kind = .caption }
                else if Self.audioTables.contains(family.id) { kind = .audio }
                else if family.id.contains("EMBEDDING") || family.id.contains("FEATUREVECTOR") || family.id.contains("THUMBNAIL") { kind = .representation }
                else if family.id.contains("QUALITY") || family.id.contains("LOUDNESS") || family.id.contains("SCORE") || family.id.contains("INTERESTINGNESS") { kind = .measurement }
                else { kind = .activity }
                return TimedResult(id: family.id + ":" + record, table: family.id, title: VisualMetadata.title(family.id), row: row,
                                   fields: VisualMetadata.explainedFields(row, table: family.id), kind: kind, start: start,
                                   duration: VisualMetadata.seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE"))
            }
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        audio = AudioTimelineData(records: records)
        classes = Array(Set(records.map(\.table))).sorted { VisualMetadata.title($0) < VisualMetadata.title($1) }
        lookup = IntervalLookup(intervals: records.map { ($0.start, $0.duration) })
    }
    public func active(at seconds: Double) -> [TimedResult] {
        lookup.indices(at: seconds).map { records[$0] }.filter { $0.active(at: seconds) }
    }
    public static let audioTables: Set<String> = ["ZAPPLAUSERESULT", "ZBABBLERESULT", "ZCHEERINGRESULT", "ZVOICERESULT", "ZMUSICRESULT", "ZLAUGHTERRESULT", "ZSCREAMRESULT", "ZSINGINGRESULT", "ZSPEECHRESULT"]
}

public struct AudioTimelineData: Sendable {
    public let levels: [TimedResult]
    public let events: [TimedResult]
    public let categories: [String]
    public let end: Double
    public init(records: [TimedResult]) {
        levels = records.filter { $0.table == "ZLOUDNESSRESULT" }
        events = records.filter { $0.kind == .audio || $0.kind == .caption }
        categories = Array(Set(events.map(\.title))).sorted()
        end = max(1, records.map { $0.end ?? $0.start }.max() ?? 1)
    }
}
