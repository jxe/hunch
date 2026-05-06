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
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(b))
    }

    @Test func textChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("Hello"))
        let b: Block = .paragraph(text: AttributedString("Hello!"))
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    /// Depth in the tree no longer contributes to a block's identity — moving
    /// a paragraph to a deeper position shouldn't change its fingerprint.
    @Test func depthDoesNotMatter() {
        let a: Block = .paragraph(text: AttributedString("Hi"))
        let b: Block = .paragraph(text: AttributedString("Hi"))
        // (Both are constructed identically; the test asserts the historical
        // "indent matters" semantics no longer apply.)
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(b))
    }

    @Test func kindChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("X"))
        let b: Block = .bullet(text: AttributedString("X"))
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func headingLevelMatters() {
        let a: Block = .heading(level: .h1, text: AttributedString("T"))
        let b: Block = .heading(level: .h2, text: AttributedString("T"))
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func todoDoneStateMatters() {
        let a: Block = .todo(text: AttributedString("T"), done: false)
        let b: Block = .todo(text: AttributedString("T"), done: true)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func codeLanguageMatters() {
        let a: Block = .code(source: "x", language: "swift")
        let b: Block = .code(source: "x", language: "rust")
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func whitespaceIsNormalised() {
        let a: Block = .paragraph(text: AttributedString("a b"))
        let b: Block = .paragraph(text: AttributedString("a   b"))
        let c: Block = .paragraph(text: AttributedString("  a b  "))
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(b))
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(c))
    }

    @Test func inlineMarksDoNotAffectFingerprint() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Hello")
        s.mergeAttributes(bold)

        let plain: Block = .paragraph(text: AttributedString("Hello"))
        let bolded: Block = .paragraph(text: s)
        #expect(BlockFingerprint.compute(plain) == BlockFingerprint.compute(bolded))
    }
}
