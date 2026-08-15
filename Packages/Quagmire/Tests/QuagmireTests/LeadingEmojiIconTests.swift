import Foundation
import Testing
@testable import Quagmire

@Suite("Subpage leading-emoji icon")
struct LeadingEmojiIconTests {
    @Test func extractsLeadingEmojiAndRest() {
        let result = leadingEmojiIcon(in: "👍 Emoji Page")
        #expect(result?.emoji == "👍")
        #expect(result?.rest == "Emoji Page")
    }

    @Test func handlesMultiScalarEmoji() {
        #expect(leadingEmojiIcon(in: "👨‍👩‍👧 Family")?.emoji == "👨‍👩‍👧")
        #expect(leadingEmojiIcon(in: "👍🏽 Approved")?.rest == "Approved")
    }

    @Test func noLeadingEmojiReturnsNil() {
        #expect(leadingEmojiIcon(in: "Plain Title") == nil)
        #expect(leadingEmojiIcon(in: "café notes") == nil)
        #expect(leadingEmojiIcon(in: "1 thing") == nil, "ASCII digit is not an emoji")
        #expect(leadingEmojiIcon(in: "") == nil)
    }

    @Test func emojiOnlyTitleRendersNormally() {
        // Stripping the emoji would leave an empty label — keep the whole
        // title as text (and the generic icon) instead of a blank row.
        #expect(leadingEmojiIcon(in: "👍") == nil)
        #expect(leadingEmojiIcon(in: "  🎉  ") == nil)
    }

    @Test func midTitleEmojiIsNotAnIcon() {
        #expect(leadingEmojiIcon(in: "Party 🎉 tonight") == nil)
    }
}
