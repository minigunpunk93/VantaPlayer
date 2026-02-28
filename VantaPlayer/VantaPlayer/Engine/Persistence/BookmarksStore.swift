import Foundation

final class BookmarksStore: @unchecked Sendable {
    struct ResolvedBookmark: Sendable {
        let url: URL
        let bookmarkData: Data?
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var activeAccessCounts: [String: Int] = [:]
    private nonisolated(unsafe) var activeScopedURLs: [String: URL] = [:]

    nonisolated func makeBookmark(for url: URL) throws -> Data {
        try scopedURL(for: url).bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    nonisolated func resolveBookmark(_ bookmarkData: Data) -> ResolvedBookmark? {
        var isStale = false

        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        let resolved = scopedURL(for: resolvedURL)
        let refreshedBookmarkData: Data?

        if isStale {
            refreshedBookmarkData = try? makeBookmark(for: resolved)
        } else {
            refreshedBookmarkData = bookmarkData
        }

        return ResolvedBookmark(url: resolved, bookmarkData: refreshedBookmarkData)
    }

    @discardableResult
    nonisolated func beginAccess(to url: URL) -> Bool {
        let scoped = scopedURL(for: url)
        let key = accessKey(for: scoped)
        let started = scoped.startAccessingSecurityScopedResource()
        guard started else { return false }

        lock.lock()
        activeAccessCounts[key, default: 0] += 1
        activeScopedURLs[key] = scoped
        lock.unlock()

        return true
    }

    nonisolated func endAccess(to url: URL) {
        let key = accessKey(for: url)
        var shouldStop = false
        var scopedURLToStop: URL?

        lock.lock()
        if let count = activeAccessCounts[key] {
            if count <= 1 {
                activeAccessCounts.removeValue(forKey: key)
                scopedURLToStop = activeScopedURLs.removeValue(forKey: key)
                shouldStop = true
            } else {
                activeAccessCounts[key] = count - 1
            }
        }
        lock.unlock()

        if shouldStop {
            (scopedURLToStop ?? scopedURL(for: url)).stopAccessingSecurityScopedResource()
        }
    }

    private nonisolated func scopedURL(for url: URL) -> URL {
        url
    }

    private nonisolated func accessKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
