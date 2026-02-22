import Foundation

final class BookmarksStore: @unchecked Sendable {
    struct ResolvedBookmark: Sendable {
        let url: URL
        let bookmarkData: Data?
    }

    private let lock = NSLock()
    private var activeAccessCounts: [URL: Int] = [:]

    func makeBookmark(for url: URL) throws -> Data {
        try normalizedURL(for: url).bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ bookmarkData: Data) -> ResolvedBookmark? {
        var isStale = false

        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        let normalized = normalizedURL(for: resolvedURL)
        let refreshedBookmarkData: Data?

        if isStale {
            refreshedBookmarkData = try? makeBookmark(for: normalized)
        } else {
            refreshedBookmarkData = bookmarkData
        }

        return ResolvedBookmark(url: normalized, bookmarkData: refreshedBookmarkData)
    }

    @discardableResult
    func beginAccess(to url: URL) -> Bool {
        let normalized = normalizedURL(for: url)
        let started = normalized.startAccessingSecurityScopedResource()
        guard started else { return false }

        lock.lock()
        activeAccessCounts[normalized, default: 0] += 1
        lock.unlock()

        return true
    }

    func endAccess(to url: URL) {
        let normalized = normalizedURL(for: url)
        var shouldStop = false

        lock.lock()
        if let count = activeAccessCounts[normalized] {
            if count <= 1 {
                activeAccessCounts.removeValue(forKey: normalized)
                shouldStop = true
            } else {
                activeAccessCounts[normalized] = count - 1
            }
        }
        lock.unlock()

        if shouldStop {
            normalized.stopAccessingSecurityScopedResource()
        }
    }

    private func normalizedURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
