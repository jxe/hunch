import Foundation
import Testing
@testable import Editor

@MainActor
@Suite("BlockRowModel equality")
struct BlockRowModelTests {
    private func model(
        block: Block = .paragraph(text: AttributedString("body")),
        isSelected: Bool = false,
        pageLookups: [String: PageLookup] = [:],
        linkPreviews: [URL: LinkPreview] = [:]
    ) -> BlockRowModel {
        BlockRowModel(
            block: block,
            depth: 0,
            isPageTitle: false,
            numberingIndex: nil,
            isSelected: isSelected,
            isEditing: false,
            isActiveEditor: false,
            completionActive: false,
            isIconPickerPresented: false,
            isExpanded: false,
            isDropTarget: false,
            isActionMenuTarget: false,
            isActionMenuPresented: false,
            isPinching: false,
            reorderSourceOpacity: 1,
            isReorderingThisBlock: false,
            isSelectionHandleRow: false,
            accessibilityID: "block-row-body",
            accessibilityLabelText: "Paragraph: body",
            pageLookups: pageLookups,
            linkPreviews: linkPreviews
        )
    }

    @Test func renderStateChangesAffectEquality() {
        let base = model()
        #expect(base != model(isSelected: true))

        let pageBlock = Block.subpage(title: "Old", pageID: "child.md")
        #expect(model(block: pageBlock, pageLookups: ["child.md": .present(title: "Child")])
            != model(block: pageBlock, pageLookups: ["child.md": .missing]))

        let url = URL(string: "https://example.com")!
        #expect(model(linkPreviews: [url: LinkPreview(url: url, title: "A", iconPNG: nil)])
            != model(linkPreviews: [url: LinkPreview(url: url, title: "B", iconPNG: nil)]))
    }
}
