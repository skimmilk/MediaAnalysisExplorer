import SwiftUI
import AVKit

/// Host AppKit directly: the system SwiftUI VideoPlayer bridge aborts during
/// generic superclass metadata initialization on the macOS build under test.
@MainActor
struct LocalVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    var onRegionClick: ((CGPoint) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        context.coordinator.attach(view, onRegionClick: onRegionClick)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onRegionClick = onRegionClick
        if view.player !== player {
            view.player?.pause()
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.detach()
        view.player?.pause()
        view.player = nil
    }

    @MainActor final class Coordinator {
        weak var view: AVPlayerView?
        var onRegionClick: ((CGPoint) -> Bool)?
        private var monitor: Any?
        func attach(_ view: AVPlayerView, onRegionClick: ((CGPoint) -> Bool)?) {
            self.view = view; self.onRegionClick = onRegionClick
            // Native playback subviews consume mouseDown before a parent SwiftUI
            // gesture receives it. Intercept only region hits in this player.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self.map { $0.handle(event) == nil } ?? false }
                return consumed ? nil : event
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  let onRegionClick else { return event }
            let local = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(local) else { return event }
            var hit = view.hitTest(view.convert(local, to: view.superview))
            while let target = hit, target !== view {
                // Preserve native play, seek, volume, and accessibility controls.
                if target is NSControl || [.button, .slider, .popUpButton, .menuButton, .textField].contains(target.accessibilityRole()) { return event }
                hit = target.superview
            }
            let point = CGPoint(x: local.x - view.bounds.minX,
                                y: view.isFlipped ? local.y - view.bounds.minY : view.bounds.maxY - local.y)
            return onRegionClick(point) ? nil : event
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; view = nil; onRegionClick = nil
        }
    }
}
