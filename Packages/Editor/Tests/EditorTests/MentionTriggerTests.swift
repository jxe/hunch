import Testing
import Foundation
@testable import Editor

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
}
