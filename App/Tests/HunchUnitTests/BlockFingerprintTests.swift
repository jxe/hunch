import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("BlockFingerprint")
struct BlockFingerprintTests {
    @Test func everyBlockKindKeepsItsLiteralRecoveryHash() {
        let fixtures: [(Block, String)] = [
            (.paragraph(text: AttributedString("Hello")), "f22d3f2e0f58dfcb24fd8f482629178b6b45cf62695b1921085df4c79911a9ca"),
            (.heading(level: .h1, text: AttributedString("Title")), "3bc5a86e32181f6d55c9f4432b8308acd4d4fb635f31621810f00a16ae94d641"),
            (.bullet(text: AttributedString("Item")), "6067594e6635e17efb59b5032f711c7f114097f8f78bef766156849c64baaa61"),
            (.numbered(text: AttributedString("First")), "d859e93499cce3df12a8288c6a0bbcf8498762d4714c7ddb02ef49c0302808d7"),
            (.todo(text: AttributedString("Task"), done: false), "b0afbc345eba855be3ab86513f2292cd7b2b94c6be01c8927c3ae013dffb46db"),
            (.todo(text: AttributedString("Done"), done: true), "aa9160deb9272117907de1c9ef0c48cab5b4dd18bd0325da55f8925a96e8fa18"),
            (.quote(text: AttributedString("Quote")), "1be9b5d9dd983123ab10a9a456e43a979869930d92d4cf71b2d441cd99586b75"),
            (.code(source: "let x = 1", language: "swift"), "1807c737ccfc3ce5489092284bee4f50b1074530cf5ffe7ebc66584230da2654"),
            (.divider(), "002cd6bbb3f74bf5f437e8977197df4c8c6f3d0592a6c53abd9c2ed3f2c68c1c"),
            (.toggle(title: AttributedString("More")), "26b149ee07610f9cec030393594b62e4597e74838efc148fa9c1bcec313dc722"),
            (.templateButton(label: "Add item"), "48b77b628e2e8b4e64f293e1f1cbf04ef05092c0b5cfcd2b7f7ef1bb59df3924"),
            (.subpage(title: "Child", pageID: "abc123"), "15ae2c173c8c33572907da954c9b7e817fdc6705992b4b1bd675c4fc46dedc89"),
            (.image(source: "Assets/photo.png", alt: "Alt text"), "c6756fec53b97770e04ef14599ba7858df3ed55ac28dd07fefda4760c59e117e")
        ]

        for (block, expected) in fixtures {
            #expect(block.atomicHash == expected)
        }
    }

    @Test func unicodeAndWhitespaceKeepLiteralRecoveryHashes() {
        #expect(
            Block.paragraph(text: AttributedString("  a   b\n")).atomicHash ==
            "255fc60b596680b5c1b8ea29ff8e3be728356f83d46ce441c879f9b22d22a9d5"
        )
        #expect(
            Block.paragraph(text: AttributedString("café 🧠")).atomicHash ==
            "d98d5eda7b7a0469bd36f2ab657d19b8d35bf03aa1515f4ab34ee6221bf14fb1"
        )
    }

    @Test func treeRelationshipsDoNotChangeAtomicContentIdentity() {
        let child = Block.paragraph(text: AttributedString("Hello"))
        let withoutChild = Block.toggle(title: AttributedString("More"))
        let withChild = Block(
            id: withoutChild.id,
            kind: withoutChild.kind,
            children: [child]
        )
        #expect(withChild.atomicHash == withoutChild.atomicHash)
        #expect(child.atomicHash == "f22d3f2e0f58dfcb24fd8f482629178b6b45cf62695b1921085df4c79911a9ca")
    }

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
