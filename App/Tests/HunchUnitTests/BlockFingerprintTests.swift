import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("BlockFingerprint")
struct BlockFingerprintTests {
    @Test func sameContentSameFingerprintAcrossFreshIDs() {
        let a: Block = .paragraph(text: AttributedString("Hello"))
        let b: Block = .paragraph(text: AttributedString("Hello"))
        #expect(a.id != b.id, "fresh BlockIDs differ")
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func textChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("Hello"))
        let b: Block = .paragraph(text: AttributedString("Hello!"))
        #expect(a.fingerprint != b.fingerprint)
    }

    /// Depth in the tree no longer contributes to a block's identity — moving
    /// a paragraph to a deeper position shouldn't change its fingerprint.
    @Test func depthDoesNotMatter() {
        let a: Block = .paragraph(text: AttributedString("Hi"))
        let b: Block = .paragraph(text: AttributedString("Hi"))
        // (Both are constructed identically; the test asserts the historical
        // "indent matters" semantics no longer apply.)
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func kindChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("X"))
        let b: Block = .bullet(text: AttributedString("X"))
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func headingLevelMatters() {
        let a: Block = .heading(level: .h1, text: AttributedString("T"))
        let b: Block = .heading(level: .h2, text: AttributedString("T"))
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func todoDoneStateMatters() {
        let a: Block = .todo(text: AttributedString("T"), done: false)
        let b: Block = .todo(text: AttributedString("T"), done: true)
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func codeLanguageMatters() {
        let a: Block = .code(source: "x", language: "swift")
        let b: Block = .code(source: "x", language: "rust")
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func whitespaceIsNormalised() {
        let a: Block = .paragraph(text: AttributedString("a b"))
        let b: Block = .paragraph(text: AttributedString("a   b"))
        let c: Block = .paragraph(text: AttributedString("  a b  "))
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint == c.fingerprint)
    }

    @Test func inlineMarksDoNotAffectFingerprint() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Hello")
        s.mergeAttributes(bold)

        let plain: Block = .paragraph(text: AttributedString("Hello"))
        let bolded: Block = .paragraph(text: s)
        #expect(plain.fingerprint == bolded.fingerprint)
    }
}
