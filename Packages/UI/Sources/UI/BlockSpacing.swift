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
        // List items: ~5pt above/below per item — measured against notion_prompt_example.png,
        // gives an item-to-item gap that's ~1.5× the within-paragraph line height.
        case .bullet, .numbered, .todo: return 5
        // .notion-code { padding: 1em }
        case .code: return 16
        // Default block padding — matches Notion's `.notion > * { padding: 3px 2px }`.
        default: return 3
        }
    }

    /// Top-margins reverse-engineered from real Notion screenshots (not from react-notion-x's CSS,
    /// which doesn't match). Headings carry generous breathing room above; paragraphs sit on a
    /// 6-7pt margin so two stacked paragraphs show a clear blank-line-style gap.
    private static func topMargin(_ block: Block) -> CGFloat {
        switch block {
        case .heading(_, 1, _): return 32     // page-title H1: ~2em above when there is something
        case .heading(_, 2, _): return 28     // H2 above body or after another heading
        case .heading(_, 3, _): return 22
        case .heading: return 18
        case .paragraph: return 5
        case .quote: return 6
        case .code: return 8
        case .divider: return 12
        case .toggle: return 2
        case .subpage: return 2
        case .bullet, .numbered, .todo: return 0
        }
    }

    private static func bottomMargin(_ block: Block) -> CGFloat {
        switch block {
        case .heading(_, 1, _): return 6
        case .heading: return 5
        case .paragraph: return 5
        case .quote: return 6
        case .code: return 8
        case .divider: return 12
        case .toggle: return 2
        case .subpage: return 2
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
