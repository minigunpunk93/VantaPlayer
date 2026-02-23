import Foundation

final class SessionStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let tracks: [Track]
        let selectedTrackID: Track.ID?
        let playingTrackID: Track.ID?
        let playbackPositions: [Track.ID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    struct RestoredSession: Sendable {
        let tracks: [Track]
        let selectedTrackID: Track.ID?
        let playingTrackID: Track.ID?
        let playbackPositions: [Track.ID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    private struct PersistedTrack: Codable {
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

    private struct PersistedSession: Codable {
        let queue: [PersistedTrack]
        let selectedTrackID: UUID?
        let playingTrackID: UUID?
        let playbackPositions: [UUID: TimeInterval]
        let volume: Float
        let wasPlaying: Bool
    }

    private enum Keys {
        static let session = "VantaPlayer.session.v1"
    }

    private let defaults: UserDefaults
    private let bookmarksStore: BookmarksStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxArtworkBytes = 512 * 1024

    nonisolated init(defaults: UserDefaults = .standard, bookmarksStore: BookmarksStore) {
        self.defaults = defaults
        self.bookmarksStore = bookmarksStore
    }

    nonisolated func save(snapshot: Snapshot) {
        let queue = snapshot.tracks.compactMap { persistedTrack(from: $0) }
        let state = PersistedSession(
            queue: queue,
            selectedTrackID: snapshot.selectedTrackID,
            playingTrackID: snapshot.playingTrackID,
            playbackPositions: snapshot.playbackPositions,
            volume: snapshot.volume,
            wasPlaying: snapshot.wasPlaying
        )

        guard let encoded = try? encoder.encode(state) else {
            return
        }

        defaults.set(encoded, forKey: Keys.session)
    }

    nonisolated func restore() -> RestoredSession? {
        guard let encoded = defaults.data(forKey: Keys.session),
              let state = try? decoder.decode(PersistedSession.self, from: encoded) else {
            return nil
        }

        let restoredTracks = state.queue.compactMap { restoredTrack(from: $0) }
        let validIDs = Set(restoredTracks.map(\.id))

        let selectedTrackID = state.selectedTrackID.flatMap { validIDs.contains($0) ? $0 : nil }
        let playingTrackID = state.playingTrackID.flatMap { validIDs.contains($0) ? $0 : nil }
        let playbackPositions = state.playbackPositions.filter { validIDs.contains($0.key) }

        return RestoredSession(
            tracks: restoredTracks,
            selectedTrackID: selectedTrackID,
            playingTrackID: playingTrackID,
            playbackPositions: playbackPositions,
            volume: state.volume,
            wasPlaying: state.wasPlaying
        )
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
