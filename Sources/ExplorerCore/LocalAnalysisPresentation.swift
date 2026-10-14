import Foundation

/// Prepared once when reports change, off the UI thread. Hover, playback and
/// seeking reuse these immutable records and interval indexes.
public struct LocalAnalysisPresentation: Sendable {
    public let families: [ResultFamily]
    public let regionTimeline: RegionTimeline
    public let playbackTimeline: PlaybackTimeline

    public init(reports: [LocalAnalysisReport]) {
        families = LocalAnalysisDisplay.families(reports)
        regionTimeline = RegionTimeline(regions: families.flatMap(VisualMetadata.regions))
        playbackTimeline = PlaybackTimeline(families: families)
    }
    public static let empty = Self(reports: [])
}
