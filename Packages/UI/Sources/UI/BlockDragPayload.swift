import Foundation
import CoreTransferable
import Core

/// What we shuttle through pasteboard/`NSItemProvider` during a row drag. Carries the
/// `BlockID`s of the rows being dragged — multi-select drags include every selected ID,
/// single-row drags include just the one. The drop destination looks each ID up in
/// `document.blocks` to find the source indices and computes the move.
///
/// Forwards through `ProxyRepresentation` to `String` rather than declaring a custom
/// UTI conforming to `public.data`. CodableRepresentation over data-conforming UTIs
/// gets routed via the macOS file-promise pipeline (NSFileCoordinator + temp file
/// round-trip), which adds ~1.5 seconds of latency to in-app drops. String transfers
/// stay in memory and complete in milliseconds.
public struct BlockDragPayload: Codable, Transferable, Sendable {
    public let ids: [BlockID]

    public init(ids: [BlockID]) {
        self.ids = ids
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (payload: BlockDragPayload) -> String in
            let data = (try? JSONEncoder().encode(payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }, importing: { (string: String) -> BlockDragPayload in
            guard let data = string.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(BlockDragPayload.self, from: data) else {
                return BlockDragPayload(ids: [])
            }
            return payload
        })
    }
}
