import Foundation
import Core
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Sibling-aware spacing modelled on Notion's pre-March-2026 CSS as preserved in
/// `react-notion-x/packages/react-notion-x/src/styles.css` (16px base font).
///
/// Notion uses CSS padding (inside the block's box) plus margin (outside) plus a global
/// `.notion > * { padding: 3px 0 }` rule. Between two stacked blocks the visible gap is
/// `max(prev.bottomMargin, curr.topMargin)` (CSS margin-collapse). SwiftUI doesn't collapse
/// margins, so we compute the gap explicitly and apply it via `.padding(.top, gap)` on the
/// second block.
public enum BlockSpacing {
    /// Inter-block gap to insert *above* `current`, given the immediately preceding sibling.
    public static func gap(before current: Block, after prev: Block?) -> CGFloat {
        guard let prev else {
            // First child of a container — no gap above.
            return 0
        }
        let prevBottom = bottomMargin(prev)
        var currTop = topMargin(current)

        // The implicit `<ul>` / `<ol>` container in Notion has 0.6em (~9.6pt) top/bottom margin.
        // We render a flat list (no container), so simulate that by adding the container's margin
        // whenever we cross the list↔non-list boundary.
        if isListItem(prev) != isListItem(current) {
            currTop = max(currTop, 9.6)
        }

        return max(prevBottom, currTop)
    }

    /// Intrinsic vertical padding INSIDE a block (between content and the block's frame edges).
    /// This corresponds to CSS `padding-top` + `padding-bottom`; SwiftUI applies it via
    /// `.padding(.vertical, …)`.
    public static func intrinsicVerticalPadding(_ block: Block) -> CGFloat {
        switch block {
        // .notion-list li { padding: 6px 0 }
        case .bullet, .numbered, .todo: return 6
        // .notion-code { padding: 1em }
        case .code: return 16
        // global .notion > * { padding: 3px 0 }
        default: return 3
        }
    }

    /// `margin-top` from `react-notion-x` styles.css. Values are in points (em × 16).
    private static func topMargin(_ block: Block) -> CGFloat {
        switch block {
        case .heading(_, 1, _): return 17     // .notion-h1 { margin-top: 1.08em } → 17.28
        case .heading(_, 2, _): return 18     // .notion-h2 { margin-top: 1.1em }  → 17.6
        case .heading(_, 3, _): return 16     // .notion-h3 { margin-top: 1em }    → 16
        case .heading: return 16
        case .paragraph: return 1             // .notion-text { margin: 1px 0 }
        case .quote: return 6                 // .notion-quote { margin: 6px 0 }
        case .code: return 4                  // .notion-code { margin: 4px 0 }
        case .divider: return 6               // .notion-hr { margin: 6px 0 }
        case .toggle: return 0                // .notion-toggle has no margin
        case .subpage: return 1               // .notion-page-link { margin: 1px 0 }
        case .bullet, .numbered, .todo: return 0  // list items have no margin
        }
    }

    /// `margin-bottom` (or the implicit "1px from `.notion-h`" for headings).
    private static func bottomMargin(_ block: Block) -> CGFloat {
        switch block {
        case .heading: return 1               // .notion-h { margin-bottom: 1px }
        case .paragraph: return 1             // .notion-text { margin: 1px 0 }
        case .quote: return 6
        case .code: return 4
        case .divider: return 6
        case .toggle: return 0
        case .subpage: return 1
        case .bullet, .numbered, .todo: return 0
        }
    }

    private static func isListItem(_ block: Block) -> Bool {
        switch block {
        case .bullet, .numbered, .todo: return true
        default: return false
        }
    }
}
