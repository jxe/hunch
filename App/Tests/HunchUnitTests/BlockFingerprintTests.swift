import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("BlockFingerprint")
struct BlockFingerprintTests {
    @Test func sameContentSameFingerprintAcrossFreshIDs() {
        let a: Block = .paragraph(text: AttributedString("Hello"), indent: 0)
        let b: Block = .paragraph(text: AttributedString("Hello"), indent: 0)
        #expect(a.id != b.id, "fresh BlockIDs differ")
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(b))
    }

    @Test func textChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("Hello"), indent: 0)
        let b: Block = .paragraph(text: AttributedString("Hello!"), indent: 0)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func indentChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("Hi"), indent: 0)
        let b: Block = .paragraph(text: AttributedString("Hi"), indent: 1)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func kindChangeChangesFingerprint() {
        let a: Block = .paragraph(text: AttributedString("X"), indent: 0)
        let b: Block = .bullet(text: AttributedString("X"), indent: 0)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func headingLevelMatters() {
        let a: Block = .heading(level: 1, text: AttributedString("T"), indent: 0)
        let b: Block = .heading(level: 2, text: AttributedString("T"), indent: 0)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func todoDoneStateMatters() {
        let a: Block = .todo(text: AttributedString("T"), done: false, indent: 0)
        let b: Block = .todo(text: AttributedString("T"), done: true, indent: 0)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func codeLanguageMatters() {
        let a: Block = .code(source: "x", language: "swift", indent: 0)
        let b: Block = .code(source: "x", language: "rust", indent: 0)
        #expect(BlockFingerprint.compute(a) != BlockFingerprint.compute(b))
    }

    @Test func whitespaceIsNormalised() {
        let a: Block = .paragraph(text: AttributedString("a b"), indent: 0)
        let b: Block = .paragraph(text: AttributedString("a   b"), indent: 0)
        let c: Block = .paragraph(text: AttributedString("  a b  "), indent: 0)
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(b))
        #expect(BlockFingerprint.compute(a) == BlockFingerprint.compute(c))
    }

    @Test func inlineMarksDoNotAffectFingerprint() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Hello")
        s.mergeAttributes(bold)

        let plain: Block = .paragraph(text: AttributedString("Hello"), indent: 0)
        let bolded: Block = .paragraph(text: s, indent: 0)
        #expect(BlockFingerprint.compute(plain) == BlockFingerprint.compute(bolded))
    }
}
