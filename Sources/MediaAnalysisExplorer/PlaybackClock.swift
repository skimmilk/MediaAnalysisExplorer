import Foundation
import AVFoundation
import Combine

/// Only the canvas and time readout observe this object. The metadata inspector
/// does not rebuild on playback ticks.
@MainActor final class PlaybackClock: ObservableObject {
    @Published private(set) var seconds: Double = 0
    private var registration: PlaybackRegistration?
    func follow(_ player: AVPlayer?) {
        registration = nil; seconds = 0
        guard let player else { return }
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = time.seconds.isFinite ? time.seconds : 0
                if next != self.seconds { self.seconds = next }
            }
        }
        registration = PlaybackRegistration(player: player, token: token)
    }
}

/// Keep the player and observer token together so the callback is removed
/// if a view disappears without a final playback tick.
private final class PlaybackRegistration {
    let player: AVPlayer
    let token: Any
    init(player: AVPlayer, token: Any) { self.player = player; self.token = token }
    deinit { player.removeTimeObserver(token) }
}
