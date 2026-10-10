import SwiftUI
import AppKit
import AVFoundation
import ExplorerCore

struct RegionCanvas: View {
    @ObservedObject var clock: PlaybackClock
    let timeline: RegionTimeline
    let preview: MediaPreview
    let image: NSImage
    let player: AVPlayer?
    let hidden: Set<String>
    let overlays: Bool
    let bottomOrigin: Bool
    @Binding var hovered: String?
    @Binding var selected: String?
    @State private var pointer: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let frame = VisualMetadata.imageFrame(image: CGSize(width: preview.width, height: preview.height), container: geometry.size)
            let visible = overlays ? timeline.visible(at: preview.video ? clock.seconds : nil, hiding: hidden) : []
            let ordered = VisualMetadata.overlayOrder(visible, hovered: hovered, pinned: selected)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35)
                if preview.video, let player {
                    LocalVideoPlayer(player: player, onRegionClick: { point in
                        pin(CGPoint(x: frame.minX + point.x, y: frame.minY + point.y), regions: visible, frame: frame)
                    }).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                } else {
                    Image(nsImage: image).resizable().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                }
                Canvas(rendersAsynchronously: true) { context, _ in
                    for region in ordered {
                        let rect = VisualMetadata.project(region.rectangle, into: frame, bottomOrigin: bottomOrigin)
                        let focused = region.id == selected || region.id == hovered
                        let color = regionColor(region.table)
                        context.fill(Path(rect), with: .color(color.opacity(focused ? 0.22 : 0.02)))
                        context.stroke(Path(rect), with: .color(color), lineWidth: focused ? 3 : 1.5)
                        let label = context.resolve(Text(region.overlayLabel(focused: false)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        let size = label.measure(in: CGSize(width: 250, height: CGFloat.greatestFiniteMagnitude))
                        let background = CGRect(x: rect.minX, y: rect.minY, width: size.width + 8, height: size.height + 8)
                        context.fill(Path(background), with: .color(color.opacity(0.9)))
                        context.draw(label, in: CGRect(x: rect.minX + 4, y: rect.minY + 4, width: 250, height: size.height))
                        if focused, !region.overlayDetails.isEmpty {
                            let details = context.resolve(Text(region.overlayDetails.joined(separator: "\n"))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                            let detailSize = details.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                            let detailBackground = CGRect(x: rect.minX, y: background.maxY, width: ceil(detailSize.width) + 8, height: ceil(detailSize.height) + 8)
                            context.fill(Path(detailBackground), with: .color(.black.opacity(0.85)))
                            context.draw(details, in: detailBackground.insetBy(dx: 4, dy: 4))
                        }
                    }
                }.allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point; updateHover(point, regions: visible, frame: frame)
                case .ended: pointer = nil; if hovered != nil { hovered = nil }
                }
            }
            .onChange(of: clock.seconds) { _, _ in
                if let pointer { updateHover(pointer, regions: visible, frame: frame) }
            }
            .onTapGesture { point in _ = pin(point, regions: visible, frame: frame) }
        }
    }
    private func updateHover(_ point: CGPoint, regions: [StoredRegion], frame: CGRect) {
        let hit = VisualMetadata.hit(point, regions: regions, frame: frame, bottomOrigin: bottomOrigin)?.id
        if hovered != hit { hovered = hit }
    }
    private func pin(_ point: CGPoint, regions: [StoredRegion], frame: CGRect) -> Bool {
        guard let hit = VisualMetadata.hit(point, regions: regions, frame: frame, bottomOrigin: bottomOrigin) else { return false }
        selected = hit.id; hovered = nil
        return true
    }
}

struct PlaybackReadout: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        Text(String(format: "%.2f s · stored detections at recorded intervals", clock.seconds))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

struct RegionCountReadout: View {
    @ObservedObject var clock: PlaybackClock
    let timeline: RegionTimeline
    let hidden: Set<String>
    let video: Bool
    var body: some View {
        Text("\(timeline.visible(at: video ? clock.seconds : nil, hiding: hidden).count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
