import Foundation

extension BlockTransform {
    /// Returns the block(s) that replace the source row. Most transforms produce a single
    /// block. `divider` and `codeFence` produce two: the transform block plus a fresh empty
    /// paragraph for the cursor to land in.
    public func apply(to remainingText: AttributedString) -> [Block] {
        switch self {
        case .heading(let level):
            return [.heading(level: level, text: remainingText)]
        case .bullet:
            return [.bullet(text: remainingText)]
        case .numbered:
            return [.numbered(text: remainingText)]
        case .todo:
            return [.todo(text: remainingText, done: false)]
        case .quote:
            return [.quote(text: remainingText)]
        case .toggle:
            return [.toggle(title: remainingText)]
        case .divider:
            return [.divider(), .paragraph(text: AttributedString())]
        case .codeFence:
            return [.code(source: "", language: nil), .paragraph(text: AttributedString())]
        }
    }

    /// Index into the result of `apply(to:)` where the cursor should land after the
    /// transform fires. For divider/codeFence we want the fresh paragraph (index 1) so the
    /// user can continue typing; everything else focuses the transformed block (index 0).
    public var focusReplacementIndex: Int {
        switch self {
        case .divider, .codeFence: return 1
        default: return 0
        }
    }
}
