import Foundation
import CryptoKit
import Editor

/// On-disk cache for fetched `LinkPreview` metadata.
///
/// Layout: `~/Library/Application Support/Hunch/LinkPreviews/<sha256>.json`
/// (+ a sibling `<sha256>.png` for the favicon, if any). Keys are SHA-256 of
/// the URL's `absoluteString`.
///
/// Each JSON record carries a `status` (`ok` / `failed`) plus a `fetchedAt`
/// epoch. After ~7 days the entry is considered stale and a refetch is allowed
/// — applies equally to successes and failures, so an offline-when-typed URL
/// gets a second chance once the user is back online.
struct LinkPreviewCache: Sendable {
    private static let ttl: TimeInterval = 7 * 24 * 60 * 60

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = LinkPreviewCache.defaultDirectory()
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Hunch", isDirectory: true)
            .appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    struct Entry {
        let preview: LinkPreview?
        let isStale: Bool
    }

    func read(for url: URL) -> Entry? {
        let key = Self.key(for: url)
        let jsonURL = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: jsonURL),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        let stale = Date().timeIntervalSince1970 - record.fetchedAt > Self.ttl
        switch record.status {
        case .ok:
            let iconURL = directory.appendingPathComponent("\(key).png")
            let iconData = try? Data(contentsOf: iconURL)
            let preview = LinkPreview(url: url, title: record.title, iconPNG: iconData)
            return Entry(preview: preview, isStale: stale)
        case .failed:
            return Entry(preview: nil, isStale: stale)
        }
    }

    func write(_ preview: LinkPreview?, for url: URL) {
        let key = Self.key(for: url)
        let jsonURL = directory.appendingPathComponent("\(key).json")
        let iconURL = directory.appendingPathComponent("\(key).png")
        let record: Record
        if let preview {
            record = Record(
                url: url.absoluteString,
                title: preview.title,
                fetchedAt: Date().timeIntervalSince1970,
                status: .ok
            )
            if let icon = preview.iconPNG {
                try? icon.write(to: iconURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: iconURL)
            }
        } else {
            record = Record(
                url: url.absoluteString,
                title: nil,
                fetchedAt: Date().timeIntervalSince1970,
                status: .failed
            )
            try? FileManager.default.removeItem(at: iconURL)
        }
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    private static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Codable {
        enum Status: String, Codable { case ok, failed }
        let url: String
        let title: String?
        let fetchedAt: TimeInterval
        let status: Status
    }
}
