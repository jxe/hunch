import Foundation
import Editor

/// Coordinates fetching + caching of `LinkPreview` data for external URLs.
///
/// The Editor package calls `preview(for:)` once per external URL it finds in
/// a rendered row. The service:
///   - returns a cached entry from the disk cache when fresh,
///   - dedupes concurrent in-flight fetches for the same URL,
///   - kicks off a real fetch via `LinkPreviewFetcher` and persists the result,
///   - returns `nil` when the fetch fails (and remembers that for ~7 days so
///     the next render doesn't redownload).
actor LinkPreviewService {
    private let cache: LinkPreviewCache
    /// In-flight task per URL — second concurrent caller awaits the same task
    /// instead of starting a parallel fetch. Cleared on completion.
    private var inFlight: [URL: Task<LinkPreview?, Never>] = [:]

    init(cache: LinkPreviewCache = LinkPreviewCache()) {
        self.cache = cache
    }

    /// Public entry point. Safe to call from any task; the editor passes a
    /// `@Sendable` reference into the environment via `provider(for:)`.
    func preview(for url: URL) async -> LinkPreview? {
        // 1. Disk cache hit (and still within TTL) → return immediately.
        if let cached = cache.read(for: url), !cached.isStale {
            return cached.preview
        }

        // 2. Active fetch for this URL → await its result.
        if let existing = inFlight[url] {
            return await existing.value
        }

        // 3. Spin up a fresh fetch.
        let task = Task<LinkPreview?, Never> { [cache] in
            let result = await LinkPreviewFetcher.fetch(url: url)
            cache.write(result, for: url)
            return result
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    /// Adapter exposing the actor's method as a `@Sendable` async closure
    /// matching the editor's `LinkPreviewProvider` typealias.
    nonisolated func provider() -> LinkPreviewProvider {
        { [weak self] url in
            guard let self else { return nil }
            return await self.preview(for: url)
        }
    }
}
