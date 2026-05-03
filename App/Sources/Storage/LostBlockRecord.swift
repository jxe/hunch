import Foundation

/// On-disk record of a block that disappeared from a document. One JSON object per
/// line in `<workspace>/.history/<relativePath>.jsonl`.
///
/// `cause: edited` is appended automatically when a save's content drops fingerprints
/// that were on disk before. `cause: deleted` is appended on explicit user delete in
/// nav mode.
public struct LostBlockRecord: Codable, Sendable, Hashable {
    public enum Cause: String, Codable, Sendable, Hashable {
        case edited
        case deleted
    }

    public let source: String
    public let recordedAt: Date
    public let cause: Cause
    public let originalIndex: Int?
    public let anchorFingerprint: String?
    public let fingerprint: String
    /// Markdown body for the lost block (or, for toggles/sections, the toggle plus
    /// its nested body). Restored verbatim through `BlockParser.parse`.
    public let markdown: String

    public init(
        source: String,
        recordedAt: Date,
        cause: Cause,
        originalIndex: Int?,
        anchorFingerprint: String?,
        fingerprint: String,
        markdown: String
    ) {
        self.source = source
        self.recordedAt = recordedAt
        self.cause = cause
        self.originalIndex = originalIndex
        self.anchorFingerprint = anchorFingerprint
        self.fingerprint = fingerprint
        self.markdown = markdown
    }
}

/// JSON-line codec. `JSONEncoder` produces compact single-line output suitable for
/// `.jsonl`; the decoder accepts the same shape and is forgiving of unknown keys
/// (Codable ignores them by default).
enum LostBlockRecordCodec {
    static func encode(_ record: LostBlockRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable key order so eyeballing the file is sane.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ line: String) -> LostBlockRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LostBlockRecord.self, from: Data(trimmed.utf8))
    }
}
