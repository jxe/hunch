import Foundation
import Testing
@testable import Quagmire

@Suite("Emoji completion")
struct EmojiCompletionTests {
    private func detect(_ string: String, cursor: Int? = nil) -> EmojiTrigger? {
        detectEmojiTrigger(plain: string, cursor: cursor ?? (string as NSString).length)
    }

    @Test func bareColonAndQueryProduceUTF16Range() {
        #expect(detect(":") == EmojiTrigger(nsRange: NSRange(location: 0, length: 1), query: ""))
        #expect(detect(":rocket") == EmojiTrigger(nsRange: NSRange(location: 0, length: 7), query: "rocket"))
    }

    @Test func worksAtTextBoundaries() {
        #expect(detect("pick :rocket")?.query == "rocket")
        #expect(detect("(:wave")?.query == "wave")
    }

    @Test func ignoresURLsTimesAndWordAttachedColons() {
        #expect(detect("https://example.com") == nil)
        #expect(detect("12:30") == nil)
        #expect(detect("label:value") == nil)
    }

    @Test func whitespaceEndsTheToken() {
        #expect(detect(":red heart") == nil)
        #expect(detect(":rocket\nnext") == nil)
    }

    @Test func unifiedDetectorPreservesMentions() {
        #expect(detectInlineCompletionTrigger(plain: "@page", cursor: 5) == .mention(
            MentionTrigger(nsRange: NSRange(location: 0, length: 5), query: "page")
        ))
    }

    @Test func replacementSplicesWholeTokenAndTracksMultiScalarCaret() {
        let trigger = EmojiTrigger(nsRange: NSRange(location: 4, length: 7), query: "family")
        let result = replacingEmojiTrigger(
            in: AttributedString("see :family today"),
            trigger: trigger,
            with: "👨‍👩‍👧"
        )
        #expect(result.map { String($0.text.characters) } == "see 👨‍👩‍👧 today")
        #expect(result?.cursor == 5)
    }

    @MainActor
    @Test func searchesLocalizedEmojiNames() {
        let results = emojiSuggestions(matching: "rocket", locale: Locale(identifier: "en"))
        #expect(results.contains { $0.character == "🚀" })
        #expect(results.count <= 50)
    }

    @MainActor
    @Test func ranksFamiliarHeartsAheadOfCompoundMatches() {
        let results = emojiSuggestions(matching: "heart", limit: .max, locale: Locale(identifier: "en"))
        #expect(results.first?.character == "❤️")

        let redHeart = results.firstIndex { $0.character == "❤️" }
        let couple = results.firstIndex { $0.character == "💑" }
        #expect(redHeart != nil)
        #expect(couple != nil)
        if let redHeart, let couple {
            #expect(redHeart < couple)
        }
    }

    @MainActor
    @Test func exactNameStillOutranksGeneralFrequency() {
        let results = emojiSuggestions(matching: "pink heart", locale: Locale(identifier: "en"))
        #expect(results.first?.character == "🩷")
    }

    @MainActor
    @Test func findsRepeatArrowsByCLDRNameAndKeyword() {
        let results = emojiSuggestions(matching: "repeat", locale: Locale(identifier: "en"))
        #expect(results.first?.character == "🔁")
        #expect(results.first?.name == "Repeat Button")
    }

    @MainActor
    @Test func findsRepeatArrowsByConversationalLoopAlias() {
        let results = emojiSuggestions(matching: "loop", locale: Locale(identifier: "en"))
        #expect(results.contains { $0.character == "🔁" })
        #expect(results.contains { $0.character == "🔂" })
    }

    @Test func bundledCLDRAnnotationsLoad() {
        let annotation = EmojiSearchAnnotations.entry(for: "🔁")
        #expect(annotation?.name == "repeat button")
        #expect(annotation?.keywords.contains("repeat") == true)
    }

    @Test func unicodeFrequencySnapshotKeepsRedHeartInTopTier() {
        #expect(EmojiGeneralFrequency.rank(of: "❤️")?.tier == 0)
        #expect(EmojiGeneralFrequency.rank(of: "💔")?.tier == 3)
        #expect(EmojiGeneralFrequency.rank(of: "💘")?.tier == 6)
    }

    @Test func pageTitlePrependsOrReplacesOneEmoji() {
        #expect(pageTitle("Project", settingEmoji: "🚀") == "🚀 Project")
        #expect(pageTitle("  👍   Project  ", settingEmoji: "🚀") == "🚀 Project")
        #expect(pageTitle("👨‍👩‍👧 Family", settingEmoji: "🏡") == "🏡 Family")
        #expect(pageTitle("👍", settingEmoji: "🎉") == "🎉")
        #expect(pageTitle("   ", settingEmoji: "🎉") == "🎉")
    }

    @Test func subpageIconHitTestUsesOnlyIndentedMarkerColumn() {
        let frame = CGRect(x: 100, y: 20, width: 500, height: 28)
        #expect(hitsSubpageIconColumn(point: CGPoint(x: 126, y: 30), rowFrame: frame, depth: 1))
        #expect(!hitsSubpageIconColumn(point: CGPoint(x: 150, y: 30), rowFrame: frame, depth: 1))
        #expect(!hitsSubpageIconColumn(point: CGPoint(x: 110, y: 30), rowFrame: frame, depth: 1))
    }
}
