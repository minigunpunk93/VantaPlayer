import AVFoundation
import Combine
import Foundation

final class AudioEnginePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var volume: Float = 0.8
    @Published private(set) var currentTrackID: Track.ID?
    @Published private(set) var currentURL: URL?

    var onPlaybackEnded: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackMixer = AVAudioMixerNode()

    private var currentFile: AVAudioFile?
    private var progressTimer: Timer?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    private var scheduleGeneration: UInt64 = 0

    init() {
        configureEngineGraph()
        configureProgressTimer()
    }

    deinit {
        progressTimer?.invalidate()
        engine.stop()
    }

    func setVolume(_ newVolume: Float) {
        let clampedVolume = max(0, min(newVolume, 1))
        volume = clampedVolume
        playbackMixer.outputVolume = clampedVolume
    }

    func loadTrack(_ track: Track, autoplay: Bool = true, startTime: TimeInterval = 0) throws {
        let audioFile = try AVAudioFile(forReading: track.url)
        currentFile = audioFile
        currentTrackID = track.id
        currentURL = track.url
        duration = fileDuration(for: audioFile)

        let startFrame = frame(for: startTime, in: audioFile)
        pausedFrame = startFrame
        currentTime = seconds(for: startFrame, in: audioFile)

        try scheduleSegment(from: startFrame, autoplay: autoplay)
    }

    func play() {
        guard let currentFile else { return }

        if pausedFrame >= currentFile.length {
            seek(to: 0)
        }

        do {
            try startEngineIfNeeded()
        } catch {
            isPlaying = false
            return
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        isPlaying = true
    }

    func pause() {
        guard currentFile != nil else { return }
        pausedFrame = currentPlaybackFrame()
        playerNode.pause()
        isPlaying = false
        currentTime = secondsForCurrentPausedFrame()
    }

    func stop() {
        guard currentFile != nil else { return }

        scheduleGeneration &+= 1
        playerNode.stop()
        pausedFrame = 0
        scheduledStartFrame = 0
        currentTime = 0
        isPlaying = false
    }

    func unload() {
        scheduleGeneration &+= 1
        playerNode.stop()

        currentFile = nil
        currentTrackID = nil
        currentURL = nil

        pausedFrame = 0
        scheduledStartFrame = 0

        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to targetTime: TimeInterval) {
        guard let currentFile else { return }

        let targetFrame = frame(for: targetTime, in: currentFile)
        pausedFrame = targetFrame
        currentTime = seconds(for: targetFrame, in: currentFile)

        do {
            try scheduleSegment(from: targetFrame, autoplay: isPlaying)
        } catch {
            isPlaying = false
        }
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    private func configureEngineGraph() {
        engine.attach(playerNode)
        engine.attach(playbackMixer)

        engine.connect(playerNode, to: playbackMixer, format: nil)
        engine.connect(playbackMixer, to: engine.mainMixerNode, format: nil)

        playbackMixer.outputVolume = volume
    }

    private func configureProgressTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.handleProgressTick()
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleSegment(from frame: AVAudioFramePosition, autoplay: Bool) throws {
        guard let currentFile else { return }

        try startEngineIfNeeded()

        let clampedFrame = max(0, min(frame, currentFile.length))
        let remainingFrames = max(0, currentFile.length - clampedFrame)

        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        playerNode.stop()

        guard remainingFrames > 0 else {
            pausedFrame = currentFile.length
            currentTime = duration
            isPlaying = false
            return
        }

        let maxFrameCount = AVAudioFramePosition(UInt32.max)
        let frameCount = AVAudioFrameCount(min(remainingFrames, maxFrameCount))
        scheduledStartFrame = clampedFrame
        pausedFrame = clampedFrame

        playerNode.scheduleSegment(
            currentFile,
            startingFrame: clampedFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSegmentCompletion(generation: generation)
            }
        }

        if autoplay {
            playerNode.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    @MainActor
    private func handleSegmentCompletion(generation: UInt64) {
        guard generation == scheduleGeneration,
              let currentFile else {
            return
        }

        pausedFrame = currentFile.length
        currentTime = duration
        isPlaying = false
        onPlaybackEnded?()
    }

    private func handleProgressTick() {
        guard let currentFile else { return }

        let currentFrame = currentPlaybackFrame()
        pausedFrame = currentFrame
        currentTime = seconds(for: currentFrame, in: currentFile)

        if isPlaying != playerNode.isPlaying {
            isPlaying = playerNode.isPlaying
        }
    }

    private func currentPlaybackFrame() -> AVAudioFramePosition {
        guard let currentFile else { return 0 }

        if playerNode.isPlaying,
           let nodeRenderTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeRenderTime) {
            let absoluteFrame = scheduledStartFrame + AVAudioFramePosition(playerTime.sampleTime)
            return max(0, min(absoluteFrame, currentFile.length))
        }

        return max(0, min(pausedFrame, currentFile.length))
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func fileDuration(for file: AVAudioFile) -> TimeInterval {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return max(0, Double(file.length) / sampleRate)
    }

    private func frame(for time: TimeInterval, in file: AVAudioFile) -> AVAudioFramePosition {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }

        let clampedTime = max(0, min(time, fileDuration(for: file)))
        return AVAudioFramePosition(clampedTime * sampleRate)
    }

    private func seconds(for frame: AVAudioFramePosition, in file: AVAudioFile) -> TimeInterval {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return max(0, min(Double(frame) / sampleRate, fileDuration(for: file)))
    }

    private func secondsForCurrentPausedFrame() -> TimeInterval {
        guard let currentFile else { return 0 }
        return seconds(for: pausedFrame, in: currentFile)
    }
}
