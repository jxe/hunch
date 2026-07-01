import Foundation

enum SubpageTrashDecision {
    static func shouldPromptToTrash(
        targetPageID: String,
        sourcePageID: String,
        sourceOutboundAfterDelete: Set<String>,
        graph: LinkGraph
    ) -> Bool {
        var inbound = graph.inbound[targetPageID] ?? []
        if sourceOutboundAfterDelete.contains(targetPageID) {
            inbound.insert(sourcePageID)
        } else {
            inbound.remove(sourcePageID)
        }
        return inbound.isEmpty
    }
}
