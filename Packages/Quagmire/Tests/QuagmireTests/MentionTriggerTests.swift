import Testing
import Foundation
@testable import Quagmire

@Suite("Mention trigger detection")
struct MentionTriggerTests {
    private func detect(_ s: String, cursor: Int? = nil) -> MentionTrigger? {
        let nsCursor = cursor ?? (s as NSString).length
        return detectMentionTrigger(plain: s, cursor: nsCursor)
    }

    @Test func bareAtFiresWithEmptyQuery() {
        let r = detect("@")
        #expect(r?.query == "")
        #expect(r?.nsRange == NSRange(location: 0, length: 1))
    }

    @Test func atWithQuery() {
        let r = detect("@foo")
        #expect(r?.query == "foo")
        #expect(r?.nsRange == NSRange(location: 0, length: 4))
    }

    @Test func midSentenceAfterSpace() {
        let r = detect("see @bar")
        #expect(r?.query == "bar")
        #expect(r?.nsRange == NSRange(location: 4, length: 4))
    }

    @Test func emailLikeDoesNotTrigger() {
        let r = detect("you@host")
        #expect(r == nil)
    }

    @Test func newlineBeforeAtIsBoundary() {
        let r = detect("first\n@second")
        #expect(r?.query == "second")
    }

    @Test func newlineAfterAtBlocks() {
        let r = detect("@foo\nbar")
        #expect(r == nil)
    }

    @Test func cursorBeforeAtReturnsNil() {
        let r = detect("hello @world", cursor: 4)
        #expect(r == nil)
    }

    @Test func cursorMidQuery() {
        let r = detect("@foobar", cursor: 4)
        #expect(r?.query == "foo")
        #expect(r?.nsRange == NSRange(location: 0, length: 4))
    }

    @Test func multiWordQuery() {
        let r = detect("@foo bar")
        #expect(r?.query == "foo bar")
        #expect(r?.nsRange == NSRange(location: 0, length: 8))
    }

    @Test func openParenIsBoundary() {
        let r = detect("(@foo")
        #expect(r?.query == "foo")
        #expect(r?.nsRange == NSRange(location: 1, length: 4))
    }

    @Test func lineLeadingMentionCreatesDocumentLinkBlock() {
        #expect(mentionStartsDocumentLinkBlock(plain: "@foo", triggerStart: 0))
        #expect(mentionStartsDocumentLinkBlock(plain: "  @foo", triggerStart: 2))
    }

    @Test func mentionAfterMarkdownMarkerCreatesDocumentLinkBlock() {
        #expect(mentionStartsDocumentLinkBlock(plain: "- @foo", triggerStart: 2))
        #expect(mentionStartsDocumentLinkBlock(plain: "1. @foo", triggerStart: 3))
        #expect(mentionStartsDocumentLinkBlock(plain: "[ ] @foo", triggerStart: 4))
        #expect(mentionStartsDocumentLinkBlock(plain: "## @foo", triggerStart: 3))
    }

    @Test func midSentenceMentionStaysInline() {
        #expect(!mentionStartsDocumentLinkBlock(plain: "see @foo", triggerStart: 4))
        #expect(!mentionStartsDocumentLinkBlock(plain: "(@foo", triggerStart: 1))
        #expect(!mentionStartsDocumentLinkBlock(plain: "see - @foo", triggerStart: 6))
    }

    // MARK: - Deep heading prefixes

    /// H4–H6 are representable, so a mention typed after one of their markers
    /// is line-leading like any other. Missing these meant `#### @page` created
    /// an inline link inside a heading instead of a reference row.
    @Test func mentionAfterADeepHeadingMarkerIsLineLeading() {
        #expect(mentionStartsDocumentLinkBlock(plain: "#### @", triggerStart: 5))
        #expect(mentionStartsDocumentLinkBlock(plain: "##### @", triggerStart: 6))
        #expect(mentionStartsDocumentLinkBlock(plain: "###### @", triggerStart: 7))
    }

    @Test func mentionAfterSevenHashesIsNotLineLeading() {
        // Not a heading marker in Markdown, so it is ordinary text.
        #expect(!mentionStartsDocumentLinkBlock(plain: "####### @", triggerStart: 8))
    }
}
