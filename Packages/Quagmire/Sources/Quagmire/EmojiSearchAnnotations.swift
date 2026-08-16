import Foundation

/// English short names and search keywords from Unicode CLDR 48. EmojiKit's
/// localized strings use formal Unicode names for some symbols, so CLDR adds
/// the familiar names and synonyms people expect from an emoji keyboard.
enum EmojiSearchAnnotations {
    struct Entry: Decodable, Equatable, Sendable {
        let keywords: [String]
        let name: String?
    }

    static func entry(for character: String) -> Entry? {
        annotations[annotationKey(for: character)]
    }

    static func searchTerms(for character: String) -> [String] {
        let entry = entry(for: character)
        return [entry?.name].compactMap { $0 }
            + (entry?.keywords ?? [])
            + (supplementalAliases[annotationKey(for: character)] ?? [])
    }

    private struct AnnotationFile: Decodable {
        let annotations: [String: Entry]
    }

    private static let annotations: [String: Entry] = {
        guard let url = Bundle.module.url(
            forResource: "emoji-annotations-en",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(AnnotationFile.self, from: data) else {
            return [:]
        }
        return file.annotations
    }()

    /// CLDR deliberately keeps keyword sets compact. These few conversational
    /// aliases cover terms people naturally type that are absent from the
    /// canonical English annotations.
    private static let supplementalAliases: [String: [String]] = [
        "🔁": ["loop"],
        "🔂": ["loop"],
        "🔄": ["loop", "sync"]
    ]

    private static func annotationKey(for character: String) -> String {
        character.replacingOccurrences(of: "\u{FE0F}", with: "")
    }
}
