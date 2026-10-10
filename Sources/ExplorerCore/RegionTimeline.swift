import Foundation

/// Immutable interval index built on the database worker. Playback queries
/// inspect only the current interval's candidates, including after a seek.
public struct RegionTimeline: Sendable {
    public let regions: [StoredRegion]
    private let lookup: IntervalLookup
    public init(regions: [StoredRegion]) {
        self.regions = regions
        lookup = IntervalLookup(intervals: regions.map { ($0.start, $0.duration) })
    }
    public func visible(at seconds: Double?, hiding: Set<String> = []) -> [StoredRegion] {
        lookup.indices(at: seconds).map { regions[$0] }.filter { !hiding.contains($0.table) && $0.visible(at: seconds) }
    }
}

/// Shared immutable lookup for spatial regions and non-spatial timed results.
struct IntervalLookup: Sendable {
    private struct Interval: Sendable { let start: Double; let end: Double; let index: Int }
    private struct Node: Sendable {
        let center: Double
        let byStart: [Interval]
        let byEnd: [Interval]
        let left: Int?
        let right: Int?
    }
    private let nodes: [Node]
    private let root: Int?
    private let untimed: [Int]
    private let count: Int
    init(intervals: [(Double?, Double?)]) {
        count = intervals.count
        var staticIndices: [Int] = []; var timed: [Interval] = []
        for (index, interval) in intervals.enumerated() {
            guard let start = interval.0, start.isFinite else { staticIndices.append(index); continue }
            let duration = interval.1 ?? 0
            let begin = duration > 0 ? start : start - 0.15
            let end = duration > 0 ? start + duration : start + 0.15
            guard begin.isFinite, end.isFinite, end > begin else { continue }
            timed.append(Interval(start: begin, end: end, index: index))
        }
        untimed = staticIndices
        var tree: [Node] = []
        func build(_ intervals: [Interval]) -> Int? {
            guard !intervals.isEmpty else { return nil }
            let sorted = intervals.sorted { $0.start < $1.start }
            let center = sorted[sorted.count / 2].start
            var left: [Interval] = [], right: [Interval] = [], overlap: [Interval] = []
            for interval in sorted {
                if interval.end <= center { left.append(interval) }
                else if interval.start > center { right.append(interval) }
                else { overlap.append(interval) }
            }
            let leftIndex = build(left), rightIndex = build(right)
            let index = tree.count
            tree.append(Node(center: center, byStart: overlap, byEnd: overlap.sorted { $0.end > $1.end }, left: leftIndex, right: rightIndex))
            return index
        }
        root = build(timed); nodes = tree
    }
    func indices(at seconds: Double?) -> [Int] {
        guard let seconds else { return Array(0..<count) }
        guard seconds.isFinite else { return [] }
        var result = untimed; var next = root
        while let index = next {
            let node = nodes[index]
            if seconds < node.center {
                for interval in node.byStart {
                    if interval.start > seconds { break }
                    result.append(interval.index)
                }
                next = node.left
            } else {
                for interval in node.byEnd {
                    if interval.end <= seconds { break }
                    result.append(interval.index)
                }
                next = node.right
            }
        }
        return result.sorted()
    }
}
