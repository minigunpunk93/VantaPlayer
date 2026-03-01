import Foundation

final class BookmarksStore: @unchecked Sendable {
    struct ResolvedBookmark: Sendable {
        let url: URL
        let bookmarkData: Data?
    }

    private struct ActiveAccess {
        let accessURL: URL
        var count: Int
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var activeAccesses: [URL: ActiveAccess] = [:]

    nonisolated func makeBookmark(for url: URL) throws -> Data {
        let bookmarkURL = bookmarkURL(for: url)
        return try bookmarkURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    nonisolated func resolveBookmark(_ bookmarkData: Data) -> ResolvedBookmark? {
        var isStale = false

        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return nil
        }

        let refreshedBookmarkData: Data?

        if isStale {
            refreshedBookmarkData = try? makeBookmark(for: resolvedURL)
        } else {
            refreshedBookmarkData = bookmarkData
        }

        return ResolvedBookmark(url: resolvedURL, bookmarkData: refreshedBookmarkData)
    }

    @discardableResult
    nonisolated func beginAccess(to url: URL) -> Bool {
        let accessURL = bookmarkURL(for: url)
        let key = accessKey(for: accessURL)
        let started = accessURL.startAccessingSecurityScopedResource()
        guard started else { return false }

        lock.lock()
        if var existing = activeAccesses[key] {
            existing.count += 1
            activeAccesses[key] = existing
        } else {
            activeAccesses[key] = ActiveAccess(accessURL: accessURL, count: 1)
        }
        lock.unlock()

        return true
    }

    nonisolated func endAccess(to url: URL) {
        let key = accessKey(for: url)
        var urlToStop: URL?

        lock.lock()
        if var activeAccess = activeAccesses[key] {
            if activeAccess.count <= 1 {
                activeAccesses.removeValue(forKey: key)
                urlToStop = activeAccess.accessURL
            } else {
                activeAccess.count -= 1
                activeAccesses[key] = activeAccess
            }
        }
        lock.unlock()

        if let urlToStop {
            urlToStop.stopAccessingSecurityScopedResource()
        }
    }

    private nonisolated func accessKey(for url: URL) -> URL {
        url.standardizedFileURL
    }

    private nonisolated func bookmarkURL(for url: URL) -> URL {
        url.isFileURL ? url : url.standardizedFileURL
    }
}
