import Foundation

struct Track: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    var duration: TimeInterval?
    var isPlayable: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        duration: TimeInterval? = nil,
        isPlayable: Bool = true
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.isPlayable = isPlayable
    }
}
