import AppKit
import AVFoundation
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: ObservableObject {
    struct InlineError: Identifiable {
        let id = UUID()
        let message: String
        let trackID: Track.ID?
    }

    @Published private(set) var tracks: [Track] = []
    @Published var selectedTrackID: Track.ID?
    @Published private(set) var isImporting = false
    @Published private(set) var inlineError: InlineError?
    @Published private(set) var audioPlayer: AudioPlayer?
    @Published private(set) var hasBootstrapped = false

    private var preferredVolume: Float = 0.8

    private static let allowedExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aif", "flac"]

    private static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [.wav, .mp3, .mpeg4Audio, .aiff]
        if let flac = UTType(filenameExtension: "flac") {
            types.append(flac)
        }
        return types
    }()

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    var playbackTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    var playbackDuration: TimeInterval {
        let activeDuration = audioPlayer?.duration ?? 0
        let selectedDuration = currentTrack?.duration ?? 0
        return max(activeDuration, selectedDuration)
    }

    var volume: Float {
        audioPlayer?.volume ?? preferredVolume
    }

    var currentTrack: Track? {
        guard let selectedTrackID else { return nil }
        return tracks.first(where: { $0.id == selectedTrackID })
    }

    var hasTracks: Bool {
        !tracks.isEmpty
    }

    func bootstrapAfterFirstFrame() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        Task { @MainActor in
            await Task.yield()
            _ = ensureAudioPlayer()
        }
    }

    func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Add"
        panel.message = "Choose audio files to add to your playlist."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedContentTypes

        guard panel.runModal() == .OK else { return }
        importTracks(from: panel.urls)
    }

    func importTracks(from urls: [URL]) {
        let accepted = filteredImportURLs(from: urls)
        guard !accepted.isEmpty else {
            presentError("No supported audio files were dropped.", trackID: nil)
            return
        }

        isImporting = true
        inlineError = nil

        Task { [accepted] in
            let imported = await Task.detached(priority: .userInitiated) {
                await Self.makeTracks(from: accepted)
            }.value

            self.isImporting = false
            self.applyImportedTracks(imported)
        }
    }

    func moveTracks(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
    }

    func playTrack(with id: Track.ID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }

        selectedTrackID = id
        inlineError = nil

        guard tracks[index].isPlayable else {
            presentError("“\(tracks[index].title)” can’t be played.", trackID: id)
            return
        }

        let player = ensureAudioPlayer()
        do {
            try player.loadTrack(at: tracks[index].url, autoplay: true)
            if tracks[index].duration == nil && player.duration > 0 {
                tracks[index].duration = player.duration
            }
        } catch {
            tracks[index].isPlayable = false
            presentError("Couldn’t play “\(tracks[index].title)”.", trackID: id)
        }
    }

    func togglePlayPause() {
        if isPlaying {
            audioPlayer?.pause()
            return
        }

        guard let targetTrack = selectedTrackForPlayback() else { return }

        if audioPlayer?.currentURL == targetTrack.url {
            ensureAudioPlayer().play()
        } else {
            playTrack(with: targetTrack.id)
        }
    }

    func playNext() {
        guard let nextIndex = adjacentPlayableIndex(step: 1) else { return }
        playTrack(with: tracks[nextIndex].id)
    }

    func playPrevious() {
        guard let previousIndex = adjacentPlayableIndex(step: -1) else { return }
        playTrack(with: tracks[previousIndex].id)
    }

    func seek(by delta: TimeInterval) {
        audioPlayer?.seek(by: delta)
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.seek(to: time)
    }

    func setVolume(_ value: Float) {
        preferredVolume = max(0, min(value, 1))
        ensureAudioPlayer().setVolume(preferredVolume)
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func removeTrack(id: Track.ID) {
        guard let removingIndex = tracks.firstIndex(where: { $0.id == id }) else { return }

        let removingSelectedTrack = selectedTrackID == id
        let removingCurrentAudio = audioPlayer?.currentURL == tracks[removingIndex].url

        tracks.remove(at: removingIndex)

        if tracks.isEmpty {
            selectedTrackID = nil
            audioPlayer?.unload()
            inlineError = nil
            return
        }

        if removingSelectedTrack {
            let nextIndex = min(removingIndex, tracks.count - 1)
            selectedTrackID = tracks[nextIndex].id
        }

        if removingCurrentAudio, let selectedTrackID {
            playTrack(with: selectedTrackID)
        }

        if inlineError?.trackID == id {
            inlineError = nil
        }
    }

    func dismissInlineError() {
        inlineError = nil
    }

    func visualizerEnergy(reduceMotion: Bool) -> Float {
        let timestamp = CACurrentMediaTime()
        let idleSpeed = reduceMotion ? 0.18 : 0.42
        let idleWave = 0.22 + (0.07 * sin(timestamp * idleSpeed))

        guard let audioPlayer else {
            return Float(max(0.05, min(idleWave, 1)))
        }

        let playbackPulse = audioPlayer.isPlaying
            ? 0.18 * sin(audioPlayer.currentTime * 3.8) + 0.06 * cos(audioPlayer.currentTime * 2.1)
            : 0

        let combined = idleWave + playbackPulse
        return Float(max(0.05, min(combined, 1)))
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !isTextInputFocused(window: event.window ?? NSApp.keyWindow) else {
            return event
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        switch event.keyCode {
        case 49 where modifiers.isEmpty:
            togglePlayPause()
            return nil
        case 123 where modifiers.isEmpty:
            seek(by: -5)
            return nil
        case 124 where modifiers.isEmpty:
            seek(by: 5)
            return nil
        case 126 where modifiers == [.command]:
            adjustVolume(by: 0.04)
            return nil
        case 125 where modifiers == [.command]:
            adjustVolume(by: -0.04)
            return nil
        default:
            return event
        }
    }

    private func ensureAudioPlayer() -> AudioPlayer {
        if let audioPlayer {
            return audioPlayer
        }

        let player = AudioPlayer()
        player.setVolume(preferredVolume)
        player.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                self?.playNext()
            }
        }

        audioPlayer = player
        return player
    }

    private func filteredImportURLs(from urls: [URL]) -> [URL] {
        var uniqueURLs = Set<URL>()
        let existingURLs = Set(tracks.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })

        var accepted: [URL] = []
        accepted.reserveCapacity(urls.count)

        for candidate in urls {
            let normalizedURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let fileExtension = normalizedURL.pathExtension.lowercased()

            guard normalizedURL.isFileURL,
                  !normalizedURL.hasDirectoryPath,
                  Self.allowedExtensions.contains(fileExtension),
                  !existingURLs.contains(normalizedURL),
                  !uniqueURLs.contains(normalizedURL) else {
                continue
            }

            uniqueURLs.insert(normalizedURL)
            accepted.append(normalizedURL)
        }

        return accepted
    }

    private func applyImportedTracks(_ imported: [Track]) {
        guard !imported.isEmpty else {
            presentError("No supported audio files were imported.", trackID: nil)
            return
        }

        let shouldAutoPlay = tracks.isEmpty && !isPlaying

        tracks.append(contentsOf: imported)

        if selectedTrackID == nil {
            selectedTrackID = tracks.first?.id
        }

        if shouldAutoPlay {
            if let firstPlayableTrack = imported.first(where: { $0.isPlayable }) {
                playTrack(with: firstPlayableTrack.id)
            } else {
                presentError("Imported files were added, but none were playable.", trackID: imported.first?.id)
            }
        }
    }

    private func selectedTrackForPlayback() -> Track? {
        if let selectedTrackID, let selectedTrack = tracks.first(where: { $0.id == selectedTrackID }) {
            return selectedTrack
        }

        if let firstPlayable = tracks.first(where: { $0.isPlayable }) {
            selectedTrackID = firstPlayable.id
            return firstPlayable
        }

        return nil
    }

    private func adjacentPlayableIndex(step: Int) -> Int? {
        guard !tracks.isEmpty else { return nil }

        let currentIndex = playbackAnchorIndex()
        let count = tracks.count

        for offset in 1...count {
            let candidate = (currentIndex + (step * offset) + (count * 4)) % count
            if tracks[candidate].isPlayable {
                return candidate
            }
        }

        return nil
    }

    private func playbackAnchorIndex() -> Int {
        if let selectedTrackID,
           let selectedIndex = tracks.firstIndex(where: { $0.id == selectedTrackID }) {
            return selectedIndex
        }

        if let currentURL = audioPlayer?.currentURL,
           let currentIndex = tracks.firstIndex(where: { $0.url == currentURL }) {
            return currentIndex
        }

        return 0
    }

    private func presentError(_ message: String, trackID: Track.ID?) {
        inlineError = InlineError(message: message, trackID: trackID)
    }

    private func isTextInputFocused(window: NSWindow?) -> Bool {
        guard let firstResponder = window?.firstResponder else { return false }

        if let textView = firstResponder as? NSTextView {
            return textView.isEditable || textView.isSelectable || textView.isFieldEditor
        }

        return firstResponder is NSTextField
    }

    private static func makeTracks(from urls: [URL]) async -> [Track] {
        await withTaskGroup(of: (Int, Track?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let track = await makeTrack(from: url)
                    return (index, track)
                }
            }

            var ordered = Array<Track?>(repeating: nil, count: urls.count)
            for await (index, track) in group {
                ordered[index] = track
            }

            return ordered.compactMap { $0 }
        }
    }

    private static func makeTrack(from url: URL) async -> Track? {
        let title = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)

        do {
            async let durationTask = asset.load(.duration)
            async let playableTask = asset.load(.isPlayable)

            let duration = try await durationTask
            let isPlayable = try await playableTask

            let seconds = duration.seconds
            let resolvedDuration = seconds.isFinite && seconds > 0 ? seconds : nil

            return Track(url: url, title: title, duration: resolvedDuration, isPlayable: isPlayable)
        } catch {
            return Track(url: url, title: title, duration: nil, isPlayable: false)
        }
    }
}
