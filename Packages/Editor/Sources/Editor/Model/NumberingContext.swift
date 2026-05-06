/// Per-block 1-indexed position among consecutive sibling `.numbered` blocks at the
/// same tree level. Resets when a non-`.numbered` sibling intervenes. Recurses into
/// every container's children so nested lists number independently.
public enum NumberingContext {
    public static func compute(_ blocks: [Block]) -> [BlockID: Int] {
        var result: [BlockID: Int] = [:]
        compute(blocks, into: &result)
        return result
    }

    private static func compute(_ blocks: [Block], into result: inout [BlockID: Int]) {
        var counter = 0
        for block in blocks {
            switch block.kind {
            case .numbered:
                counter += 1
                result[block.id] = counter
            default:
                counter = 0
            }
            // Children get their own numbering scope, regardless of the
            // outer counter (a non-`.numbered` parent does not contribute).
            if !block.children.isEmpty {
                compute(block.children, into: &result)
            }
        }
    }
}
