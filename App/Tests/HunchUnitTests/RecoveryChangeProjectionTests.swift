import Foundation
import Testing
@testable import Hunch
import Editor

@Suite("Clamshell recovery change projection")
struct RecoveryChangeProjectionTests {
    @Test func formattingOnlySnapshotsDoNotChurnRecoveryRecords() {
        let parentID = BlockID()
        let child = Block.paragraph(text: AttributedString("body"))
        let before = Block(
            id: parentID,
            kind: .toggle(title: AttributedString("Parent")),
            children: [child]
        )

        var bold = AttributeContainer()
        bold.inlineBold = true
        var boldTitle = AttributedString("Parent")
        boldTitle.mergeAttributes(bold)
        let after = Block(
            id: parentID,
            kind: .toggle(title: boldTitle),
            children: [child]
        )

        let changes: [DocumentChange] = [
            .removed(block: before),
            .inserted(block: after, parent: nil),
            .placementUpdated(block: child, previousParent: before, parent: after)
        ]
        #expect(RecoveryChangeProjection.entries(for: changes).isEmpty)
    }

    @Test func changedParentIdentityRefreshesStableChildParentReference() {
        let parentID = BlockID()
        let child = Block.paragraph(text: AttributedString("body"))
        let before = Block(
            id: parentID,
            kind: .heading(level: .h3, text: AttributedString("Section")),
            children: [child]
        )
        let after = Block(
            id: parentID,
            kind: .heading(level: .h2, text: AttributedString("Section")),
            children: [child]
        )

        let entries = RecoveryChangeProjection.entries(for: [
            .removed(block: before),
            .inserted(block: after, parent: nil),
            .placementUpdated(block: child, previousParent: before, parent: after)
        ])

        #expect(entries.count == 3)
        #expect(entries[0].op == .purge)
        #expect(entries[0].hash == before.atomicHash)
        #expect(entries[1].op == .add)
        #expect(entries[1].hash == after.atomicHash)
        #expect(entries[2].op == .add)
        #expect(entries[2].hash == child.atomicHash)
        #expect(entries[2].parent == after.atomicHash)
    }
}
