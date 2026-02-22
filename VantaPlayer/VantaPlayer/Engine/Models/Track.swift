import Foundation

struct Track: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var artworkData: Data?
    var bookmarkData: Data?
    var isPlayable: Bool
    var unplayableReason: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        artworkData: Data? = nil,
        bookmarkData: Data? = nil,
        isPlayable: Bool = true,
        unplayableReason: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
        self.bookmarkData = bookmarkData
        self.isPlayable = isPlayable
        self.unplayableReason = unplayableReason
    }

    var subtitle: String? {
        if let artist, !artist.isEmpty {
            return artist
        }

        if let album, !album.isEmpty {
            return album
        }

        return nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}
