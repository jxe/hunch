import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum NotionStyle {
    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> RGBA {
        rgba(red, green, blue, 1)
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> RGBA {
        RGBA(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    #if os(macOS)
    private static func adaptivePlatformColor(light: RGBA, dark: RGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return platformColor(match == .darkAqua ? dark : light)
        } ?? platformColor(light)
    }

    private static func adaptiveColor(light: RGBA, dark: RGBA) -> Color {
        Color(nsColor: adaptivePlatformColor(light: light, dark: dark))
    }

    private static func platformColor(_ rgba: RGBA) -> NSColor {
        NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
    #elseif os(iOS)
    private static func adaptivePlatformColor(light: RGBA, dark: RGBA) -> UIColor {
        UIColor { traits in
            platformColor(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    private static func adaptiveColor(light: RGBA, dark: RGBA) -> Color {
        Color(uiColor: adaptivePlatformColor(light: light, dark: dark))
    }

    private static func platformColor(_ rgba: RGBA) -> UIColor {
        UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
    #else
    private static func adaptiveColor(light: RGBA, dark: RGBA) -> Color {
        Color(red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
    }
    #endif

    // MARK: Colors
    public static let foreground = adaptiveColor(light: rgb(55, 53, 47), dark: rgb(218, 216, 211))        // #37352F / #DAD8D3
    public static let mutedForeground = adaptiveColor(light: rgba(55, 53, 47, 0.5), dark: rgba(255, 255, 255, 0.46))
    public static let background = adaptiveColor(light: rgb(255, 255, 255), dark: rgb(25, 25, 25))
    public static let codeForeground = adaptiveColor(light: rgb(235, 87, 87), dark: rgb(255, 115, 105))    // #EB5757 / #FF7369
    public static let codeBackground = adaptiveColor(light: rgba(135, 131, 120, 0.15), dark: rgba(255, 255, 255, 0.08))
    public static let dividerColor = adaptiveColor(light: rgb(233, 233, 231), dark: rgba(255, 255, 255, 0.13))
    public static let linkForeground = adaptiveColor(light: rgb(35, 131, 226), dark: rgb(82, 156, 255))
    public static let selectionBackground = adaptiveColor(light: rgba(35, 131, 226, 0.12), dark: rgba(82, 156, 255, 0.22))

    #if os(macOS)
    public static let platformForeground = adaptivePlatformColor(light: rgb(55, 53, 47), dark: rgb(218, 216, 211))
    public static let platformCodeForeground = adaptivePlatformColor(light: rgb(235, 87, 87), dark: rgb(255, 115, 105))
    public static let platformCodeBackground = adaptivePlatformColor(light: rgba(135, 131, 120, 0.15), dark: rgba(255, 255, 255, 0.08))
    public static let platformLinkForeground = adaptivePlatformColor(light: rgb(35, 131, 226), dark: rgb(82, 156, 255))
    #elseif os(iOS)
    public static let platformForeground = adaptivePlatformColor(light: rgb(55, 53, 47), dark: rgb(218, 216, 211))
    public static let platformCodeForeground = adaptivePlatformColor(light: rgb(235, 87, 87), dark: rgb(255, 115, 105))
    public static let platformCodeBackground = adaptivePlatformColor(light: rgba(135, 131, 120, 0.15), dark: rgba(255, 255, 255, 0.08))
    public static let platformLinkForeground = adaptivePlatformColor(light: rgb(35, 131, 226), dark: rgb(82, 156, 255))
    #endif

    // MARK: Fonts
    /// Inter at the requested size and weight, built via a platform font descriptor
    /// so SwiftUI never has to call `.weight()` on a `Font.custom(...)` — that path
    /// emits "Unable to update Font Descriptor's weight" warnings on iOS for every
    /// non-system font (Inter is registered as a single variable face). Same family
    /// + weight resolution as `InlineMarksBridge.interFont`, just bridged into a
    /// SwiftUI `Font`.
    public static func body(size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        let platformWeight = platformFontWeight(for: weight)
        let attributes: [PlatformFontDescriptor.AttributeName: Any] = [
            .family: "Inter",
            .traits: [PlatformFontDescriptor.TraitKey.weight: platformWeight.rawValue]
        ]
        let descriptor = PlatformFontDescriptor(fontAttributes: attributes)
        #if os(macOS)
        let font = NSFont(descriptor: descriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: platformWeight)
        return Font(font)
        #else
        let font = UIFont(descriptor: descriptor, size: size)
        return Font(font)
        #endif
    }

    public static func mono(size: CGFloat = 14) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced)
    }

    private static func platformFontWeight(for weight: Font.Weight) -> PlatformFontWeight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }

    // MARK: Spacing
    public static let lineHeightMultiple: CGFloat = 1.5
    public static let blockVerticalPadding: CGFloat = 3
    public static let headingTopPadding: CGFloat = 22
    /// Notion uses 700 across page title, H1, H2, H3 — confirmed against pre-2026 reference shots.
    public static let headingWeight: Font.Weight = .semibold

    /// SwiftUI's `.lineSpacing` is *additional* spacing between baselines, not a multiplier.
    /// Inter's natural 16pt leading already reads a touch airier than Notion's body copy,
    /// so we stay slightly under the theoretical 1.5em target to keep wrapped paragraphs dense enough.
    public static let bodyLineSpacing: CGFloat = 3.5
    /// Headings use a tighter line-height (~1.2em) than body so multi-line headings don't sprawl.
    public static let headingLineSpacing: CGFloat = 1

    // MARK: Heading sizes
    /// Notion's `.notion-page-title-text { font-size: 40px }`. Used only for the *first* H1 in a
    /// document when it sits at the top — that's how Notion treats the document title.
    public static let pageTitleSize: CGFloat = 40
    /// `.notion-h1 { font-size: 1.875em }` → 30pt. Inline H1 (rare; not the page title).
    public static let h1Size: CGFloat = 30
    /// `.notion-h2 { font-size: 1.5em }` → 24pt.
    public static let h2Size: CGFloat = 24
    /// `.notion-h3 { font-size: 1.25em }` → 20pt.
    public static let h3Size: CGFloat = 20

    // MARK: Page layout
    public static let maxContentWidth: CGFloat = 708
    /// Minimum side breathing room before the centered page column takes over on wider windows.
    public static func pageHorizontalPadding(for availableWidth: CGFloat) -> CGFloat {
        min(48, max(20, availableWidth * 0.055))
    }

    // MARK: Inline code
    public static let inlineCodeSize: CGFloat = 13.6
    public static let inlineCodeRadius: CGFloat = 3
    public static let inlineCodeHorizontalPadding: CGFloat = 4

    // MARK: List indentation
    public static let indentStep: CGFloat = 24
    public static let listMarkerGap: CGFloat = 10
    /// Width of the marker column for every list-style row (bullet/numbered/
    /// todo/toggle/templateButton/subpage). Unified across kinds so list-text
    /// columns line up regardless of marker shape, and so an indented paragraph
    /// at depth N+1 aligns exactly with list text at depth N. Marker glyphs are
    /// right-aligned within the column.
    public static let listMarkerColumnWidth: CGFloat = 24

    /// Leading inset for marker-less rows (paragraph, heading, quote, code, divider).
    /// At depth N>0, aligns with where a list item at depth N-1 puts its TEXT — so
    /// depth reads consistently across block kinds.
    public static func nonListLeading(depth: Int) -> CGFloat {
        depth <= 0 ? 0 : CGFloat(depth - 1) * indentStep + listMarkerColumnWidth + listMarkerGap
    }
    public static let listMarkerFrameHeight: CGFloat = 16
    public static let bulletMarkerDiameter: CGFloat = 6
    public static let bulletMarkerColumnWidth: CGFloat = listMarkerColumnWidth
    public static let bulletMarkerBaselineOffset: CGFloat = 5
    public static let numberedMarkerColumnWidth: CGFloat = listMarkerColumnWidth
    public static let todoMarkerColumnWidth: CGFloat = listMarkerColumnWidth
    public static let todoCheckboxSize: CGFloat = 16

    // MARK: Toggle / subpage
    public static let chevronSize: CGFloat = 12
    public static let pageIconSize: CGFloat = 14
}

/// Sibling-aware spacing modelled on Notion's pre-March-2026 CSS as preserved in
/// `react-notion-x/packages/react-notion-x/src/styles.css` (16px base font).
///
/// Notion uses CSS padding (inside the block's box) plus margin (outside) plus a global
/// `.notion > * { padding: 3px 0 }` rule. Between two stacked blocks the visible gap is
/// `max(prev.bottomMargin, curr.topMargin)` (CSS margin-collapse). SwiftUI doesn't collapse
/// margins, so we compute the gap explicitly and apply it via `.padding(.top, gap)` on the
/// second block.
public enum BlockSpacing {
    /// Inter-block gap to insert *above* `current`, given the immediately preceding sibling
    /// in document order (visible-flat order, may be a sibling at a different tree depth).
    public static func gap(before current: Block, depth: Int, after prev: Block?, prevDepth: Int) -> CGFloat {
        guard let prev else {
            // First child of a container — no gap above.
            return 0
        }
        let prevBottom = bottomMargin(prev)
        var currTop = topMargin(current)

        // Nested-child relationship: current sits one or more depth levels deeper than prev.
        // Treat as a child stacked under its parent — no boundary bump, no extra top margin —
        // so the spacing matches sibling-to-sibling list spacing.
        let isNestedChild = depth > prevDepth
        if isNestedChild {
            currTop = 0
        } else if isListItem(prev) != isListItem(current) {
            // The implicit `<ul>` / `<ol>` container in Notion has 0.6em (~9.6pt) top/bottom margin.
            // We render a flat list (no container), so simulate that by adding the container's margin
            // whenever we cross the list↔non-list boundary.
            currTop = max(currTop, 9.6)
        }

        return max(prevBottom, currTop)
    }

    /// Intrinsic vertical padding INSIDE a block (between content and the block's frame edges).
    /// This corresponds to CSS `padding-top` + `padding-bottom`; SwiftUI applies it via
    /// `.padding(.vertical, …)`.
    public static func intrinsicVerticalPadding(_ block: Block) -> CGFloat {
        switch block.kind {
        // List items: ~5pt above/below per item — measured against notion_prompt_example.png,
        // gives an item-to-item gap that's ~1.5× the within-paragraph line height. Toggles
        // are list-item shaped (chevron + title, body as siblings), so they share this rule.
        case .bullet, .numbered, .todo, .subpage, .toggle, .templateButton: return 5
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
        switch block.kind {
        case .heading(.h1, _): return 32  // page-title H1: ~2em above when there is something
        case .heading(.h2, _): return 28  // H2 above body or after another heading
        case .heading(.h3, _): return 22
        case .paragraph: return 5
        case .quote: return 6
        case .code: return 8
        case .divider: return 12
        case .image: return 8
        case .subpage, .bullet, .numbered, .todo, .toggle, .templateButton: return 0
        }
    }

    private static func bottomMargin(_ block: Block) -> CGFloat {
        switch block.kind {
        case .heading(.h1, _): return 6
        case .heading: return 5
        case .paragraph: return 5
        case .quote: return 6
        case .code: return 8
        case .divider: return 12
        case .image: return 8
        case .subpage, .bullet, .numbered, .todo, .toggle, .templateButton: return 0
        }
    }

    private static func isListItem(_ block: Block) -> Bool {
        switch block.kind {
        case .bullet, .numbered, .todo, .subpage, .toggle, .templateButton: return true
        default: return false
        }
    }
}
