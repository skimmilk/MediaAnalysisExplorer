import SwiftUI
import Charts
import AVFoundation
import ExplorerCore

struct AudioTimelineView: View {
    @ObservedObject var clock: PlaybackClock
    let timeline: PlaybackTimeline
    let player: AVPlayer?
    @State private var expanded = false
    @State private var inspected: TimedResult?
    init(clock: PlaybackClock, timeline: PlaybackTimeline, player: AVPlayer?, initiallyExpanded: Bool = false) {
        self.clock = clock; self.timeline = timeline; self.player = player
        _expanded = State(initialValue: initiallyExpanded)
    }
    private var levels: [TimedResult] { timeline.audio.levels }
    private var events: [TimedResult] { timeline.audio.events }
    private var end: Double { timeline.audio.end }
    var body: some View {
        if !levels.isEmpty || !events.isEmpty {
            DisclosureGroup("Audio & caption timeline", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !levels.isEmpty {
                        levelChart("Energy · stored loudness units", field: "ZENERGYVALUES", color: .teal)
                        levelChart("Peak · stored magnitude", field: "ZPEAKVALUES", color: .orange)
                    }
                    Chart {
                      ForEach(events) { event in
                        if let end = event.end {
                            RectangleMark(xStart: .value("Start", event.start), xEnd: .value("End", end), y: .value("Analysis", event.title), height: .ratio(0.65))
                                .foregroundStyle(event.kind == .caption ? Color.blue : Color.teal).opacity(0.65)
                        } else { PointMark(x: .value("Time", event.start), y: .value("Analysis", event.title)).foregroundStyle(.teal) }
                      }
                      RuleMark(x: .value("Playback", clock.seconds)).foregroundStyle(.orange)
                    }.chartXScale(domain: 0...end).chartYScale(domain: timeline.audio.categories).frame(height: CGFloat(max(65, timeline.audio.categories.count * 23)))
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                                    guard let frame = proxy.plotFrame else { return }
                                    let local = CGPoint(x: point.x - geometry[frame].minX, y: point.y - geometry[frame].minY)
                                    guard let seconds: Double = proxy.value(atX: local.x), let category: String = proxy.value(atY: local.y) else { return }
                                    inspected = events.filter { $0.title == category && $0.active(at: seconds) }.min { ($0.duration ?? 0) < ($1.duration ?? 0) }
                                    player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
                                }
                            }
                        }
                    InfoButton(title: "Audio timeline", text: "Click a sound or caption interval to seek. Energy and peak levels use separate scales.")
                }.padding(.top, 8)
            }.font(.caption)
            .popover(item: $inspected) { event in
                ScrollView { VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(event.title).font(.headline); Spacer(); Button("Done") { inspected = nil } }
                    if let caption = event.caption { Text(caption).textSelection(.enabled) }
                    MetadataFields(fields: event.fields)
                }.padding(14) }.frame(width: 430, height: 400)
            }
        }
    }
    private func levelChart(_ title: String, field: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Chart {
              ForEach(levels) { level in
                if let value = Double(level.row[field]), value.isFinite {
                    LineMark(x: .value("Time", level.start), y: .value("Stored value", value)).foregroundStyle(color).interpolationMethod(.stepStart)
                }
              }
              RuleMark(x: .value("Playback", clock.seconds)).foregroundStyle(.orange)
            }.chartXScale(domain: 0...end).frame(height: 85)
                .chartOverlay { proxy in GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                        guard let frame = proxy.plotFrame, let time: Double = proxy.value(atX: point.x - geometry[frame].minX) else { return }
                        inspected = levels.min { abs($0.start - time) < abs($1.start - time) }
                        player?.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
                    }
                } }
        }
    }
}
