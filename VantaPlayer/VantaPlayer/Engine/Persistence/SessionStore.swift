import Foundation

final class SessionStore: @unchecked Sendable {
    nonisolated struct Snapshot: Sendable {
        let tracks: [Track]
        let selectedTrackID: Track.ID?
        let playingTrackID: Track.ID?
        let playbackPositions: [Track.ID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    nonisolated struct QueueSnapshot: Sendable {
        let tracks: [Track]
    }

    nonisolated struct PlaybackSnapshot: Sendable {
        let selectedTrackID: Track.ID?
        let playingTrackID: Track.ID?
        let playbackPositions: [Track.ID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    nonisolated struct RestoredSession: Sendable {
        let tracks: [Track]
        let selectedTrackID: Track.ID?
        let playingTrackID: Track.ID?
        let playbackPositions: [Track.ID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    private nonisolated struct PersistedTrack: Codable {
        let id: UUID
        let path: String
        let bookmarkData: Data?
        let title: String
        let artist: String?
        let album: String?
        let duration: TimeInterval?
        let artworkData: Data?
        let isPlayable: Bool
    }

    private nonisolated struct PersistedQueue: Codable {
        let queue: [PersistedTrack]
    }

    private nonisolated struct PersistedPlayback: Codable {
        let selectedTrackID: UUID?
        let playingTrackID: UUID?
        let playbackPositions: [UUID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    // Legacy combined payload used before split queue/playback persistence.
    private nonisolated struct PersistedSession: Codable {
        let queue: [PersistedTrack]
        let selectedTrackID: UUID?
        let playingTrackID: UUID?
        let playbackPositions: [UUID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    private nonisolated enum Keys {
        static let queue = "VantaPlayer.session.queue.v1"
        static let playback = "VantaPlayer.session.playback.v1"
        static let legacySession = "VantaPlayer.session.v1"
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    private let bookmarksStore: BookmarksStore
    private let maxArtworkBytes = 512 * 1024

    nonisolated init(defaults: UserDefaults = .standard, bookmarksStore: BookmarksStore) {
        self.defaults = defaults
        self.bookmarksStore = bookmarksStore
    }

    nonisolated func save(snapshot: Snapshot) {
        saveQueue(snapshot: QueueSnapshot(tracks: snapshot.tracks))
        savePlayback(
            snapshot: PlaybackSnapshot(
                selectedTrackID: snapshot.selectedTrackID,
                playingTrackID: snapshot.playingTrackID,
                playbackPositions: snapshot.playbackPositions,
                volume: snapshot.volume,
                wasPlaying: snapshot.wasPlaying
            )
        )
    }

    nonisolated func saveQueue(snapshot: QueueSnapshot) {
        let queue = snapshot.tracks.compactMap { persistedTrack(from: $0) }
        guard let encoded = encode(PersistedQueue(queue: queue)) else {
            return
        }

        defaults.set(encoded, forKey: Keys.queue)
    }

    nonisolated func savePlayback(snapshot: PlaybackSnapshot) {
        let state = PersistedPlayback(
            selectedTrackID: snapshot.selectedTrackID,
            playingTrackID: snapshot.playingTrackID,
            playbackPositions: snapshot.playbackPositions,
            volume: max(0, min(snapshot.volume, 1)),
            wasPlaying: snapshot.wasPlaying
        )

        guard let encoded = encode(state) else {
            return
        }

        defaults.set(encoded, forKey: Keys.playback)
    }

    nonisolated func restore() -> RestoredSession? {
        if let restored = restoreFromSplitKeys() {
            return restored
        }

        guard let legacyRestored = restoreFromLegacyKey() else {
            return nil
        }

        // One-time migration from legacy combined payload.
        saveQueue(snapshot: QueueSnapshot(tracks: legacyRestored.tracks))
        savePlayback(
            snapshot: PlaybackSnapshot(
                selectedTrackID: legacyRestored.selectedTrackID,
                playingTrackID: legacyRestored.playingTrackID,
                playbackPositions: legacyRestored.playbackPositions,
                volume: legacyRestored.volume,
                wasPlaying: legacyRestored.wasPlaying
            )
        )
        defaults.removeObject(forKey: Keys.legacySession)

        return legacyRestored
    }

    private nonisolated func restoreFromSplitKeys() -> RestoredSession? {
        guard let queueData = defaults.data(forKey: Keys.queue),
              let queueState = decode(PersistedQueue.self, from: queueData) else {
            return nil
        }

        let restoredTracks = queueState.queue.compactMap { restoredTrack(from: $0) }
        let playbackState: PersistedPlayback?
        if let playbackData = defaults.data(forKey: Keys.playback) {
            playbackState = decode(PersistedPlayback.self, from: playbackData)
        } else {
            playbackState = nil
        }

        return makeRestoredSession(restoredTracks: restoredTracks, playbackState: playbackState)
    }

    private nonisolated func restoreFromLegacyKey() -> RestoredSession? {
        guard let encoded = defaults.data(forKey: Keys.legacySession),
              let legacyState = decode(PersistedSession.self, from: encoded) else {
            return nil
        }

        let restoredTracks = legacyState.queue.compactMap { restoredTrack(from: $0) }
        let playbackState = PersistedPlayback(
            selectedTrackID: legacyState.selectedTrackID,
            playingTrackID: legacyState.playingTrackID,
            playbackPositions: legacyState.playbackPositions,
            volume: legacyState.volume,
            wasPlaying: legacyState.wasPlaying
        )

        return makeRestoredSession(restoredTracks: restoredTracks, playbackState: playbackState)
    }

    private nonisolated func makeRestoredSession(
        restoredTracks: [Track],
        playbackState: PersistedPlayback?
    ) -> RestoredSession {
        let validIDs = Set(restoredTracks.map(\.id))

        let selectedTrackID = playbackState?.selectedTrackID.flatMap {
            validIDs.contains($0) ? $0 : nil
        }
        let playingTrackID = playbackState?.playingTrackID.flatMap {
            validIDs.contains($0) ? $0 : nil
        }
        let playbackPositions = (playbackState?.playbackPositions ?? [:]).filter {
            validIDs.contains($0.key)
        }

        return RestoredSession(
            tracks: restoredTracks,
            selectedTrackID: selectedTrackID,
            playingTrackID: playingTrackID,
            playbackPositions: playbackPositions,
            volume: max(0, min(playbackState?.volume ?? 0.8, 1)),
            wasPlaying: playbackState?.wasPlaying ?? false
        )
    }

    private nonisolated func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(value)
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: data)
    }

    private nonisolated func persistedTrack(from track: Track) -> PersistedTrack? {
        let bookmarkData = track.bookmarkData ?? (try? bookmarksStore.makeBookmark(for: track.url))
        let trimmedArtwork = track.artworkData.flatMap { data -> Data? in
            data.count <= maxArtworkBytes ? data : nil
        }

        return PersistedTrack(
            id: track.id,
            path: track.url.path,
            bookmarkData: bookmarkData,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkData: trimmedArtwork,
            isPlayable: track.isPlayable
        )
    }

    private nonisolated func restoredTrack(from track: PersistedTrack) -> Track? {
        let resolvedURL: URL
        var resolvedBookmarkData = track.bookmarkData

        if let bookmarkData = track.bookmarkData,
           let resolvedBookmark = bookmarksStore.resolveBookmark(bookmarkData) {
            resolvedURL = resolvedBookmark.url
            resolvedBookmarkData = resolvedBookmark.bookmarkData
        } else {
            resolvedURL = URL(fileURLWithPath: track.path)
        }

        let normalizedURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            return nil
        }

        return Track(
            id: track.id,
            url: normalizedURL,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkData: track.artworkData,
            bookmarkData: resolvedBookmarkData,
            isPlayable: track.isPlayable,
            unplayableReason: nil
        )
    }
}
