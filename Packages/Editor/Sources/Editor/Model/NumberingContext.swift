/// Per-block 1-indexed position among consecutive sibling `.numbered` blocks at the same indent.
public enum NumberingContext {
    public static func compute(_ blocks: [Block]) -> [BlockID: Int] {
        var result: [BlockID: Int] = [:]
        var counters: [Int: Int] = [:]
        for block in blocks {
            switch block {
            case .numbered(_, _, let indent):
                let next = (counters[indent] ?? 0) + 1
                counters[indent] = next
                result[block.id] = next
                for key in counters.keys where key > indent {
                    counters[key] = 0
                }
            default:
                counters.removeAll()
            }
        }
        return result
    }
}
