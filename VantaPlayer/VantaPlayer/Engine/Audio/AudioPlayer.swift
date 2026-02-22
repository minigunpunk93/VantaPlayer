import AVFoundation
import Combine
import Foundation

final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var volume: Float = 0.8

    private(set) var currentURL: URL?
    var onPlaybackEnded: (() -> Void)?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var hasReportedPlaybackEnd = false

    init() {
        let timer = Timer(timeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            self?.handleProgressTick()
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0, min(newVolume, 1))
        volume = clamped
        player?.volume = clamped
    }

    func loadTrack(at url: URL, autoplay: Bool = true) throws {
        let nextPlayer = try AVAudioPlayer(contentsOf: url)
        nextPlayer.prepareToPlay()
        nextPlayer.volume = volume

        player = nextPlayer
        currentURL = url
        currentTime = 0
        duration = max(nextPlayer.duration, 0)
        hasReportedPlaybackEnd = false

        if autoplay {
            isPlaying = nextPlayer.play()
        } else {
            isPlaying = false
        }
    }

    func play() {
        guard let player else { return }
        hasReportedPlaybackEnd = false
        isPlaying = player.play()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        currentTime = player.currentTime
    }

    func stop() {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        isPlaying = false
        currentTime = 0
        duration = player.duration
        hasReportedPlaybackEnd = false
    }

    func unload() {
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        hasReportedPlaybackEnd = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to targetTime: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(targetTime, player.duration))
        player.currentTime = clamped
        currentTime = clamped
        hasReportedPlaybackEnd = false
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    private func handleProgressTick() {
        guard let player else { return }

        let wasPlaying = isPlaying
        let nowPlaying = player.isPlaying
        let safeDuration = max(player.duration, 0)
        let safeTime = max(0, min(player.currentTime, safeDuration))

        isPlaying = nowPlaying
        currentTime = safeTime
        duration = safeDuration

        if nowPlaying {
            hasReportedPlaybackEnd = false
        } else if wasPlaying,
                  !hasReportedPlaybackEnd,
                  safeDuration > 0,
                  safeTime >= safeDuration - 0.05 {
            hasReportedPlaybackEnd = true
            onPlaybackEnded?()
        }
    }
}
