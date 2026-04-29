import Foundation

public struct BlockID: Hashable, Sendable, Codable {
    public let value: UUID

    public init(_ value: UUID = UUID()) {
        self.value = value
    }
}
