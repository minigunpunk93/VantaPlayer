import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
final class PlayerViewModel: ObservableObject {
    struct InlineError: Identifiable {
        let id = UUID()
        let message: String
        let trackID: Track.ID?
    }

    struct ImportProgress: Sendable {
        let completed: Int
        let total: Int
        let label: String

        var fraction: Double? {
            total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : nil
        }
    }

    @Published private(set) var tracks: [Track] = []
    @Published var selectedTrackID: Track.ID?
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var isRestoringSession = false
    @Published private(set) var inlineError: InlineError?
    @Published private(set) var hasBootstrapped = false

    private var preferredVolume: Float = 0.8
    private var playbackPositions: [Track.ID: TimeInterval] = [:]
    private var trackIndexByID: [Track.ID: Int] = [:]

    private let bookmarksStore = BookmarksStore()
    private let sessionStore: SessionStore

    private var audioPlayer: AudioEnginePlayer?

    private var playerCancellables: Set<AnyCancellable> = []
    private var importTask: Task<Void, Never>?
    private var queuePersistenceTask: Task<Void, Never>?
    private var playbackPersistenceTask: Task<Void, Never>?

    private var shouldAutoplayOnImport = false
    private var didAutoplayDuringImport = false
    private var activeImportGeneration = 0
    private var lastPersistedSecond = -1

    #if canImport(MediaPlayer)
    private var remoteCommandsConfigured = false
    private var remoteCommandTargets: [Any] = []
    private var lastNowPlayingUpdate = Date.distantPast
    private var nowPlayingArtworkCache: [Track.ID: MPMediaItemArtwork] = [:]
    #endif

    private static let allowedExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aif", "flac"]

    private static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [.wav, .mp3, .mpeg4Audio, .aiff]
        if let flac = UTType(filenameExtension: "flac") {
            types.append(flac)
        }
        return types
    }()

    init() {
        sessionStore = SessionStore(bookmarksStore: bookmarksStore)
    }

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
        guard let selectedTrackID,
              let index = trackIndex(for: selectedTrackID) else {
            return nil
        }
        return tracks[index]
    }

    var hasTracks: Bool {
        !tracks.isEmpty
    }

    var importProgressLabel: String? {
        importProgress?.label
    }

    var importProgressFraction: Double? {
        importProgress?.fraction
    }

    func bootstrapAfterFirstFrame() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        Task { @MainActor in
            await Task.yield()
            _ = ensureAudioStack()
            configureRemoteCommandsIfNeeded()
            await restoreSession()
        }
    }

    func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio Files"
        panel.prompt = "Import"
        panel.message = "Choose one or more audio files."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedContentTypes

        guard panel.runModal() == .OK else { return }
        importTracks(from: panel.urls)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Folder"
        panel.prompt = "Import"
        panel.message = "Choose a folder to scan for audio files."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        importFolder(from: folderURL)
    }

    func importTracks(from urls: [URL]) {
        let acceptedURLs = filteredImportURLs(from: urls)
        guard !acceptedURLs.isEmpty else {
            presentError("No supported audio files were imported.", trackID: nil)
            return
        }

        let generation = beginImport(label: "Importing 0/\(acceptedURLs.count)", total: acceptedURLs.count)

        importTask = Task { [acceptedURLs, generation] in
            var importedCount = 0
            var firstImportedTrackID: Track.ID?

            for (index, url) in acceptedURLs.enumerated() {
                if Task.isCancelled { break }
                guard generation == activeImportGeneration else { return }

                let track = await Task.detached(priority: .userInitiated) {
                    await TrackImportWorker.makeTrack(from: url)
                }.value

                if appendImportedTrack(track) {
                    importedCount += 1
                    if firstImportedTrackID == nil {
                        firstImportedTrackID = track.id
                    }
                }

                importProgress = ImportProgress(
                    completed: index + 1,
                    total: acceptedURLs.count,
                    label: "Importing \(index + 1)/\(acceptedURLs.count)"
                )
            }

            finishImport(
                discoveredCount: acceptedURLs.count,
                importedCount: importedCount,
                firstTrackID: firstImportedTrackID,
                generation: generation
            )
        }
    }

    func importFolder(from folderURL: URL) {
        let normalizedFolder = normalizedURL(folderURL)
        let didStartScope = bookmarksStore.beginAccess(to: normalizedFolder)
        let existingURLs = Set(tracks.map { normalizedURL($0.url) })
        let stream = TrackImportWorker.folderAudioFilesStream(
            rootURL: normalizedFolder,
            allowedExtensions: Self.allowedExtensions,
            excluding: existingURLs
        )

        let generation = beginImport(label: "Scanning folder…", total: 0)

        importTask = Task { [generation] in
            defer {
                if didStartScope {
                    bookmarksStore.endAccess(to: normalizedFolder)
                }
            }

            var discoveredCount = 0
            var importedCount = 0
            var firstImportedTrackID: Track.ID?

            for await url in stream {
                if Task.isCancelled { break }
                guard generation == activeImportGeneration else { return }

                discoveredCount += 1
                importProgress = ImportProgress(
                    completed: importedCount,
                    total: discoveredCount,
                    label: "Importing \(importedCount)/\(discoveredCount)"
                )

                let track = await Task.detached(priority: .userInitiated) {
                    await TrackImportWorker.makeTrack(from: url)
                }.value

                if appendImportedTrack(track) {
                    importedCount += 1
                    if firstImportedTrackID == nil {
                        firstImportedTrackID = track.id
                    }
                }

                importProgress = ImportProgress(
                    completed: importedCount,
                    total: discoveredCount,
                    label: "Importing \(importedCount)/\(discoveredCount)"
                )
            }

            finishImport(
                discoveredCount: discoveredCount,
                importedCount: importedCount,
                firstTrackID: firstImportedTrackID,
                generation: generation
            )
        }
    }

    func moveTracks(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        rebuildTrackIndexCache()
        scheduleQueueSave()
    }

    func playTrack(with id: Track.ID) {
        playTrack(with: id, autoplay: true, explicitStartTime: nil)
    }

    func togglePlayPause() {
        if isPlaying {
            audioPlayer?.pause()
            refreshNowPlayingInfo(force: true)
            schedulePlaybackSave()
            return
        }

        guard let targetTrack = selectedTrackForPlayback() else { return }

        if audioPlayer?.currentTrackID == targetTrack.id {
            ensureAudioStack().play()
            refreshNowPlayingInfo(force: true)
            schedulePlaybackSave()
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
        schedulePlaybackSave()
        refreshNowPlayingInfo(force: true)
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.seek(to: time)
        schedulePlaybackSave()
        refreshNowPlayingInfo(force: true)
    }

    func setVolume(_ value: Float) {
        preferredVolume = max(0, min(value, 1))
        audioPlayer?.setVolume(preferredVolume)
        schedulePlaybackSave()
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func removeTrack(id: Track.ID) {
        guard let removingIndex = trackIndex(for: id) else { return }

        let removedTrack = tracks[removingIndex]
        let removingSelectedTrack = selectedTrackID == id
        let removingCurrentAudio = audioPlayer?.currentTrackID == id

        tracks.remove(at: removingIndex)
        rebuildTrackIndexCache()
        playbackPositions.removeValue(forKey: id)
        bookmarksStore.endAccess(to: removedTrack.url)
        #if canImport(MediaPlayer)
        nowPlayingArtworkCache.removeValue(forKey: id)
        #endif

        if tracks.isEmpty {
            selectedTrackID = nil
            audioPlayer?.unload()
            inlineError = nil
            scheduleQueueSave()
            schedulePlaybackSave()
            refreshNowPlayingInfo(force: true)
            return
        }

        if removingSelectedTrack {
            let nextIndex = min(removingIndex, tracks.count - 1)
            selectedTrackID = tracks[nextIndex].id
        }

        if removingCurrentAudio {
            if let selectedTrackID {
                playTrack(with: selectedTrackID)
            } else {
                audioPlayer?.unload()
            }
        }

        if inlineError?.trackID == id {
            inlineError = nil
        }

        scheduleQueueSave()
        schedulePlaybackSave()
        refreshNowPlayingInfo(force: true)
    }

    func dismissInlineError() {
        inlineError = nil
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

    private func ensureAudioStack() -> AudioEnginePlayer {
        if let audioPlayer {
            return audioPlayer
        }

        let player = AudioEnginePlayer()
        player.setVolume(preferredVolume)
        player.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                self?.playNext()
            }
        }

        player.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &playerCancellables)

        player.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self, weak player] currentTime in
                guard let self else { return }
                if let trackID = player?.currentTrackID {
                    playbackPositions[trackID] = currentTime
                }
                maybePersistPlaybackPosition(currentTime: currentTime)
                refreshNowPlayingInfo()
            }
            .store(in: &playerCancellables)

        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshNowPlayingInfo(force: true)
            }
            .store(in: &playerCancellables)

        player.$currentTrackID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshNowPlayingInfo(force: true)
            }
            .store(in: &playerCancellables)

        audioPlayer = player

        return player
    }

    private func playTrack(with id: Track.ID, autoplay: Bool, explicitStartTime: TimeInterval?) {
        guard let index = trackIndex(for: id) else { return }

        selectedTrackID = id
        inlineError = nil

        guard tracks[index].isPlayable else {
            presentError("“\(tracks[index].title)” can’t be played.", trackID: id)
            return
        }

        let player = ensureAudioStack()
        let startTime = explicitStartTime ?? playbackPositions[id] ?? 0

        do {
            try player.loadTrack(tracks[index], autoplay: autoplay, startTime: startTime)
            playbackPositions[id] = player.currentTime

            var didMutateQueue = false
            if tracks[index].duration == nil && player.duration > 0 {
                tracks[index].duration = player.duration
                didMutateQueue = true
            }
            if tracks[index].unplayableReason != nil {
                didMutateQueue = true
            }
            tracks[index].unplayableReason = nil

            if didMutateQueue {
                scheduleQueueSave()
            }
            schedulePlaybackSave()
            refreshNowPlayingInfo(force: true)
        } catch {
            let wasPlayable = tracks[index].isPlayable
            let previousReason = tracks[index].unplayableReason
            tracks[index].isPlayable = false
            tracks[index].unplayableReason = "Failed to decode audio"
            presentError("Couldn’t decode “\(tracks[index].title)”.", trackID: id)
            if wasPlayable || previousReason != tracks[index].unplayableReason {
                scheduleQueueSave()
            }
            schedulePlaybackSave()
            refreshNowPlayingInfo(force: true)
        }
    }

    @discardableResult
    private func beginImport(label: String, total: Int) -> Int {
        importTask?.cancel()
        activeImportGeneration &+= 1
        let generation = activeImportGeneration
        isImporting = true
        importProgress = ImportProgress(completed: 0, total: total, label: label)
        inlineError = nil
        shouldAutoplayOnImport = tracks.isEmpty && !isPlaying
        didAutoplayDuringImport = false
        return generation
    }

    private func finishImport(discoveredCount: Int, importedCount: Int, firstTrackID: Track.ID?, generation: Int) {
        guard generation == activeImportGeneration else { return }
        isImporting = false
        importProgress = nil

        if discoveredCount == 0 {
            presentError("No supported audio files were found.", trackID: nil)
            return
        }

        if importedCount == 0 {
            presentError("No new files were imported.", trackID: nil)
            return
        }

        if shouldAutoplayOnImport && !didAutoplayDuringImport {
            if let firstTrackID {
                playTrack(with: firstTrackID)
            } else {
                presentError("Imported files were added, but none were playable.", trackID: nil)
            }
        }

        shouldAutoplayOnImport = false
        didAutoplayDuringImport = false
        scheduleQueueSave()
        schedulePlaybackSave()
    }

    @discardableResult
    private func appendImportedTrack(_ incomingTrack: Track) -> Bool {
        let normalized = normalizedURL(incomingTrack.url)
        guard !tracks.contains(where: { normalizedURL($0.url) == normalized }) else {
            return false
        }

        var track = incomingTrack
        if track.bookmarkData == nil {
            track.bookmarkData = try? bookmarksStore.makeBookmark(for: track.url)
        }
        _ = bookmarksStore.beginAccess(to: track.url)

        tracks.append(track)
        trackIndexByID[track.id] = tracks.count - 1
        if selectedTrackID == nil {
            selectedTrackID = track.id
        }

        if shouldAutoplayOnImport && !didAutoplayDuringImport && track.isPlayable {
            didAutoplayDuringImport = true
            playTrack(with: track.id)
        }

        return true
    }

    private func restoreSession() async {
        isRestoringSession = true

        let restoredSession = await Task.detached(priority: .utility) { [sessionStore] in
            sessionStore.restore()
        }.value

        isRestoringSession = false
        guard let restoredSession else { return }

        tracks = restoredSession.tracks
        rebuildTrackIndexCache()
        for track in tracks {
            _ = bookmarksStore.beginAccess(to: track.url)
        }
        #if canImport(MediaPlayer)
        nowPlayingArtworkCache.removeAll(keepingCapacity: true)
        #endif

        playbackPositions = restoredSession.playbackPositions
        preferredVolume = max(0, min(restoredSession.volume, 1))
        selectedTrackID = restoredSession.selectedTrackID ?? tracks.first?.id

        let player = ensureAudioStack()
        player.setVolume(preferredVolume)

        let anchorTrackID = restoredSession.playingTrackID ?? selectedTrackID
        if let anchorTrackID,
           let anchorIndex = trackIndex(for: anchorTrackID) {
            let startTime = playbackPositions[anchorTrackID] ?? 0
            playTrack(with: tracks[anchorIndex].id, autoplay: restoredSession.wasPlaying, explicitStartTime: startTime)
        } else {
            refreshNowPlayingInfo(force: true)
        }
    }

    private func selectedTrackForPlayback() -> Track? {
        if let selectedTrackID,
           let selectedTrackIndex = trackIndex(for: selectedTrackID) {
            return tracks[selectedTrackIndex]
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
           let selectedIndex = trackIndex(for: selectedTrackID) {
            return selectedIndex
        }

        if let currentTrackID = audioPlayer?.currentTrackID,
           let currentIndex = trackIndex(for: currentTrackID) {
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

    private func filteredImportURLs(from urls: [URL]) -> [URL] {
        var uniqueURLs = Set<URL>()
        let existingURLs = Set(tracks.map { normalizedURL($0.url) })

        var accepted: [URL] = []
        accepted.reserveCapacity(urls.count)

        for candidate in urls {
            let normalized = normalizedURL(candidate)
            let fileExtension = normalized.pathExtension.lowercased()

            guard normalized.isFileURL,
                  !normalized.hasDirectoryPath,
                  Self.allowedExtensions.contains(fileExtension),
                  !existingURLs.contains(normalized),
                  !uniqueURLs.contains(normalized) else {
                continue
            }

            uniqueURLs.insert(normalized)
            accepted.append(normalized)
        }

        return accepted
    }

    private func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func trackIndex(for id: Track.ID) -> Int? {
        if let cachedIndex = trackIndexByID[id],
           tracks.indices.contains(cachedIndex),
           tracks[cachedIndex].id == id {
            return cachedIndex
        }

        rebuildTrackIndexCache()
        return trackIndexByID[id]
    }

    private func rebuildTrackIndexCache() {
        trackIndexByID.removeAll(keepingCapacity: true)
        trackIndexByID.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            trackIndexByID[track.id] = index
        }
    }

    private func maybePersistPlaybackPosition(currentTime: TimeInterval) {
        let roundedSecond = Int(currentTime)
        guard roundedSecond != lastPersistedSecond else { return }
        lastPersistedSecond = roundedSecond
        schedulePlaybackSave()
    }

    private func scheduleQueueSave() {
        queuePersistenceTask?.cancel()
        let snapshot = SessionStore.QueueSnapshot(tracks: tracks)

        queuePersistenceTask = Task.detached(priority: .utility) { [sessionStore] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            sessionStore.saveQueue(snapshot: snapshot)
        }
    }

    private func schedulePlaybackSave() {
        playbackPersistenceTask?.cancel()
        let snapshot = makePlaybackSnapshot()

        playbackPersistenceTask = Task.detached(priority: .utility) { [sessionStore] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            sessionStore.savePlayback(snapshot: snapshot)
        }
    }

    private func makePlaybackSnapshot() -> SessionStore.PlaybackSnapshot {
        var positions = playbackPositions
        if let currentTrackID = audioPlayer?.currentTrackID {
            positions[currentTrackID] = audioPlayer?.currentTime ?? positions[currentTrackID] ?? 0
        }

        return SessionStore.PlaybackSnapshot(
            selectedTrackID: selectedTrackID,
            playingTrackID: audioPlayer?.currentTrackID ?? selectedTrackID,
            playbackPositions: positions,
            volume: volume,
            wasPlaying: isPlaying
        )
    }

    private func configureRemoteCommandsIfNeeded() {
        #if canImport(MediaPlayer)
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true

        remoteCommandTargets.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayPause()
            }
            return .success
        })

        remoteCommandTargets.append(commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying {
                self.togglePlayPause()
            }
            return .success
        })

        remoteCommandTargets.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        })

        remoteCommandTargets.append(commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playNext()
            return .success
        })

        remoteCommandTargets.append(commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playPrevious()
            return .success
        })
        #endif
    }

    private func refreshNowPlayingInfo(force: Bool = false) {
        #if canImport(MediaPlayer)
        let now = Date()
        if !force, now.timeIntervalSince(lastNowPlayingUpdate) < 0.2 {
            return
        }
        lastNowPlayingUpdate = now

        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTrack.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let artist = currentTrack.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = currentTrack.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        let resolvedDuration = playbackDuration
        if resolvedDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = resolvedDuration
        }

        if let artwork = cachedArtwork(for: currentTrack) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if #available(macOS 10.13, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
        #endif
    }

    #if canImport(MediaPlayer)
    private func cachedArtwork(for track: Track) -> MPMediaItemArtwork? {
        if let cachedArtwork = nowPlayingArtworkCache[track.id] {
            return cachedArtwork
        }

        guard let artworkData = track.artworkData,
              let artworkImage = NSImage(data: artworkData) else {
            return nil
        }

        let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        nowPlayingArtworkCache[track.id] = artwork
        return artwork
    }
    #endif
}

private enum TrackImportWorker {
    nonisolated static func makeTrack(from url: URL) async -> Track {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        let fallbackTitle = normalized.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: normalized)

        do {
            async let durationTask = asset.load(.duration)
            async let playableTask = asset.load(.isPlayable)
            async let metadataTask = asset.load(.commonMetadata)

            let duration = try await durationTask
            let isPlayable = try await playableTask
            let metadata = try await metadataTask

            let seconds = duration.seconds
            let resolvedDuration = seconds.isFinite && seconds > 0 ? seconds : nil

            async let titleTask = metadataString(for: .commonKeyTitle, in: metadata)
            async let artistTask = metadataString(for: .commonKeyArtist, in: metadata)
            async let albumTask = metadataString(for: .commonKeyAlbumName, in: metadata)
            async let artworkTask = metadataArtworkData(in: metadata)

            let title = await titleTask ?? fallbackTitle
            let artist = await artistTask
            let album = await albumTask
            let artworkData = await artworkTask

            return Track(
                url: normalized,
                title: title,
                artist: artist,
                album: album,
                duration: resolvedDuration,
                artworkData: artworkData,
                bookmarkData: nil,
                isPlayable: isPlayable,
                unplayableReason: isPlayable ? nil : "Unsupported codec or format"
            )
        } catch {
            return Track(
                url: normalized,
                title: fallbackTitle,
                artist: nil,
                album: nil,
                duration: nil,
                artworkData: nil,
                bookmarkData: nil,
                isPlayable: false,
                unplayableReason: "Metadata read failed"
            )
        }
    }

    nonisolated static func folderAudioFilesStream(
        rootURL: URL,
        allowedExtensions: Set<String>,
        excluding existing: Set<URL>
    ) -> AsyncStream<URL> {
        func normalize(_ url: URL) -> URL {
            url.standardizedFileURL.resolvingSymlinksInPath()
        }

        let normalizedRoot = normalize(rootURL)
        let normalizedExisting = Set(existing.map(normalize))

        return AsyncStream { continuation in
            let scanner = Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                let keys: [URLResourceKey] = [.isRegularFileKey]

                guard let enumerator = fileManager.enumerator(
                    at: normalizedRoot,
                    includingPropertiesForKeys: keys,
                    options: options
                ) else {
                    continuation.finish()
                    return
                }

                var visited = Set<URL>()

                while let candidateURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }

                    let normalizedCandidate = normalize(candidateURL)
                    let extensionLowercased = normalizedCandidate.pathExtension.lowercased()
                    guard allowedExtensions.contains(extensionLowercased) else { continue }

                    guard !normalizedExisting.contains(normalizedCandidate),
                          !visited.contains(normalizedCandidate) else {
                        continue
                    }

                    guard (try? normalizedCandidate.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                        continue
                    }

                    visited.insert(normalizedCandidate)
                    continuation.yield(normalizedCandidate)
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                scanner.cancel()
            }
        }
    }

    private nonisolated static func metadataString(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey == key }),
              let loadedValue = try? await item.load(.stringValue) else {
            return nil
        }

        let value = loadedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private nonisolated static func metadataArtworkData(in metadata: [AVMetadataItem]) async -> Data? {
        guard let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }) else {
            return nil
        }

        if let dataValue = try? await item.load(.dataValue),
           !dataValue.isEmpty {
            return dataValue
        }

        if let value = try? await item.load(.value),
           let dictionaryValue = value as? [AnyHashable: Any],
           let dataValue = dictionaryValue["data"] as? Data,
           !dataValue.isEmpty {
            return dataValue
        }

        return nil
    }
}
