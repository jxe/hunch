import CoreGraphics

struct ReorderDropFrame: Equatable {
    var frame: CGRect
}

enum ReorderDropResolver {
    static func insertionIndex(
        forY y: CGFloat,
        rowFrames: [ReorderDropFrame],
        previousIndex: Int? = nil,
        hysteresis: CGFloat = 10
    ) -> Int {
        guard !rowFrames.isEmpty else { return 0 }

        let sortedFrames = rowFrames.sorted {
            if $0.frame.midY == $1.frame.midY {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.midY < $1.frame.midY
        }
        let rawIndex = sortedFrames.reduce(0) { count, row in
            y > row.frame.midY ? count + 1 : count
        }

        guard let previousIndex else { return rawIndex }
        let clampedPrevious = max(0, min(previousIndex, sortedFrames.count))
        guard rawIndex != clampedPrevious else { return rawIndex }
        guard abs(rawIndex - clampedPrevious) == 1 else { return rawIndex }

        if rawIndex > clampedPrevious {
            let boundary = sortedFrames[clampedPrevious].frame.midY
            return y > boundary + hysteresis ? rawIndex : clampedPrevious
        } else {
            let boundary = sortedFrames[rawIndex].frame.midY
            return y < boundary - hysteresis ? rawIndex : clampedPrevious
        }
    }
}

