import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Visual values consumed by the editor. A host can supply a theme per
/// `EditorView`; the package default uses system fonts and requires no bundled
/// font registration.
public struct EditorTheme: Equatable, Sendable {
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
        }
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

    public struct Palette: Equatable, Sendable {
        public var foreground: Color
        public var mutedForeground: Color
        public var background: Color
        public var codeForeground: Color
        public var codeBackground: Color
        public var divider: Color
        public var link: Color
        public var selection: Color

        public init(
            foreground: Color,
            mutedForeground: Color,
            background: Color,
            codeForeground: Color,
            codeBackground: Color,
            divider: Color,
            link: Color,
            selection: Color
        ) {
            self.foreground = foreground
            self.mutedForeground = mutedForeground
            self.background = background
            self.codeForeground = codeForeground
            self.codeBackground = codeBackground
            self.divider = divider
            self.link = link
            self.selection = selection
        }

        public static let `default` = Palette(
            foreground: EditorTheme.adaptiveColor(light: EditorTheme.rgb(55, 53, 47), dark: EditorTheme.rgb(218, 216, 211)),
            mutedForeground: EditorTheme.adaptiveColor(light: EditorTheme.rgba(55, 53, 47, 0.5), dark: EditorTheme.rgba(255, 255, 255, 0.46)),
            background: EditorTheme.adaptiveColor(light: EditorTheme.rgb(255, 255, 255), dark: EditorTheme.rgb(25, 25, 25)),
            codeForeground: EditorTheme.adaptiveColor(light: EditorTheme.rgb(235, 87, 87), dark: EditorTheme.rgb(255, 115, 105)),
            codeBackground: EditorTheme.adaptiveColor(light: EditorTheme.rgba(135, 131, 120, 0.15), dark: EditorTheme.rgba(255, 255, 255, 0.08)),
            divider: EditorTheme.adaptiveColor(light: EditorTheme.rgb(233, 233, 231), dark: EditorTheme.rgba(255, 255, 255, 0.13)),
            link: EditorTheme.adaptiveColor(light: EditorTheme.rgb(35, 131, 226), dark: EditorTheme.rgb(82, 156, 255)),
            selection: EditorTheme.adaptiveColor(light: EditorTheme.rgba(35, 131, 226, 0.12), dark: EditorTheme.rgba(82, 156, 255, 0.22))
        )
    }

    public struct Typography: Equatable, Sendable {
        public var bodyFontFamily: String?
        public var bodySize: CGFloat
        public var bodyLineSpacing: CGFloat
        public var headingWeight: Font.Weight
        public var headingLineSpacing: CGFloat
        public var pageTitleSize: CGFloat
        public var h1Size: CGFloat
        public var h2Size: CGFloat
        public var h3Size: CGFloat
        public var h4Size: CGFloat
        public var h5Size: CGFloat
        public var h6Size: CGFloat
        public var inlineCodeSize: CGFloat

        public init(
            bodyFontFamily: String? = nil,
            bodySize: CGFloat = 16,
            bodyLineSpacing: CGFloat = 3.5,
            headingWeight: Font.Weight = .semibold,
            headingLineSpacing: CGFloat = 1,
            pageTitleSize: CGFloat = 40,
            h1Size: CGFloat = 30,
            h2Size: CGFloat = 24,
            h3Size: CGFloat = 20,
            h4Size: CGFloat = 18,
            h5Size: CGFloat = 17,
            h6Size: CGFloat = 16,
            inlineCodeSize: CGFloat = 13.6
        ) {
            self.bodyFontFamily = bodyFontFamily
            self.bodySize = bodySize
            self.bodyLineSpacing = bodyLineSpacing
            self.headingWeight = headingWeight
            self.headingLineSpacing = headingLineSpacing
            self.pageTitleSize = pageTitleSize
            self.h1Size = h1Size
            self.h2Size = h2Size
            self.h3Size = h3Size
            self.h4Size = h4Size
            self.h5Size = h5Size
            self.h6Size = h6Size
            self.inlineCodeSize = inlineCodeSize
        }
    }

    public struct Layout: Equatable, Sendable {
        public var maxContentWidth: CGFloat
        public var minimumHorizontalPadding: CGFloat
        public var maximumHorizontalPadding: CGFloat
        public var proportionalHorizontalPadding: CGFloat
        public var indentStep: CGFloat
        public var listMarkerGap: CGFloat
        public var listMarkerColumnWidth: CGFloat

        public init(
            maxContentWidth: CGFloat = 708,
            minimumHorizontalPadding: CGFloat = 20,
            maximumHorizontalPadding: CGFloat = 48,
            proportionalHorizontalPadding: CGFloat = 0.055,
            indentStep: CGFloat = 24,
            listMarkerGap: CGFloat = 10,
            listMarkerColumnWidth: CGFloat = 24
        ) {
            self.maxContentWidth = maxContentWidth
            self.minimumHorizontalPadding = minimumHorizontalPadding
            self.maximumHorizontalPadding = maximumHorizontalPadding
            self.proportionalHorizontalPadding = proportionalHorizontalPadding
            self.indentStep = indentStep
            self.listMarkerGap = listMarkerGap
            self.listMarkerColumnWidth = listMarkerColumnWidth
        }
    }

    public var palette: Palette
    public var typography: Typography
    public var layout: Layout

    public init(
        palette: Palette = .default,
        typography: Typography = Typography(),
        layout: Layout = Layout()
    ) {
        self.palette = palette
        self.typography = typography
        self.layout = layout
    }

    public static let `default` = EditorTheme()

    public var foreground: Color { palette.foreground }
    public var mutedForeground: Color { palette.mutedForeground }
    public var background: Color { palette.background }
    public var codeForeground: Color { palette.codeForeground }
    public var codeBackground: Color { palette.codeBackground }
    public var dividerColor: Color { palette.divider }
    public var linkForeground: Color { palette.link }
    public var selectionBackground: Color { palette.selection }
    public var bodyFontFamily: String? { typography.bodyFontFamily }

    var platformForeground: PlatformColor { PlatformColor(foreground) }
    var platformCodeForeground: PlatformColor { PlatformColor(codeForeground) }
    var platformCodeBackground: PlatformColor { PlatformColor(codeBackground) }

    public func body(weight: Font.Weight = .regular) -> Font {
        body(size: typography.bodySize, weight: weight)
    }

    public func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let platformWeight = platformFontWeight(for: weight)
        guard let bodyFontFamily else {
            return .system(size: size, weight: weight)
        }
        let attributes: [PlatformFontDescriptor.AttributeName: Any] = [
            .family: bodyFontFamily,
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

    public func mono(size: CGFloat = 14) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced)
    }

    private func platformFontWeight(for weight: Font.Weight) -> PlatformFontWeight {
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
    public var lineHeightMultiple: CGFloat { 1.5 }
    public var blockVerticalPadding: CGFloat { 3 }
    public var headingTopPadding: CGFloat { 22 }
    var headingWeight: Font.Weight { typography.headingWeight }

    /// SwiftUI's `.lineSpacing` is *additional* spacing between baselines, not a multiplier.
    /// Inter's natural 16pt leading already reads a touch airier than Notion's body copy,
    /// so we stay slightly under the theoretical 1.5em target to keep wrapped paragraphs dense enough.
    var bodyLineSpacing: CGFloat { typography.bodyLineSpacing }
    /// Headings use a tighter line-height (~1.2em) than body so multi-line headings don't sprawl.
    var headingLineSpacing: CGFloat { typography.headingLineSpacing }

    // MARK: Heading sizes
    /// Notion's `.notion-page-title-text { font-size: 40px }`. Used only for the *first* H1 in a
    /// document when it sits at the top — that's how Notion treats the document title.
    var pageTitleSize: CGFloat { typography.pageTitleSize }
    /// `.notion-h1 { font-size: 1.875em }` → 30pt. Inline H1 (rare; not the page title).
    var h1Size: CGFloat { typography.h1Size }
    /// `.notion-h2 { font-size: 1.5em }` → 24pt.
    var h2Size: CGFloat { typography.h2Size }
    /// `.notion-h3 { font-size: 1.25em }` → 20pt.
    var h3Size: CGFloat { typography.h3Size }
    // Notion has no H4–H6, so there is no reference screenshot to match. These
    // continue the ramp down toward body size (16pt) rather than inventing a
    // new scale; H6 lands at body size and is distinguished only by weight.
    // They exist to render imported documents faithfully, not to be authored.
    var h4Size: CGFloat { typography.h4Size }
    var h5Size: CGFloat { typography.h5Size }
    var h6Size: CGFloat { typography.h6Size }

    /// Point size for a heading at `level`, before the page-title override.
    func headingSize(_ level: HeadingLevel) -> CGFloat {
        switch level {
        case .h1: return h1Size
        case .h2: return h2Size
        case .h3: return h3Size
        case .h4: return h4Size
        case .h5: return h5Size
        case .h6: return h6Size
        }
    }

    // MARK: Page layout
    var maxContentWidth: CGFloat { layout.maxContentWidth }
    /// Minimum side breathing room before the centered page column takes over on wider windows.
    func pageHorizontalPadding(for availableWidth: CGFloat) -> CGFloat {
        min(layout.maximumHorizontalPadding, max(layout.minimumHorizontalPadding, availableWidth * layout.proportionalHorizontalPadding))
    }

    // MARK: Inline code
    var inlineCodeSize: CGFloat { typography.inlineCodeSize }
    public var inlineCodeRadius: CGFloat { 3 }
    public var inlineCodeHorizontalPadding: CGFloat { 4 }
    public var inlineCodeVerticalPadding: CGFloat { 1.5 }

    // MARK: List indentation
    var indentStep: CGFloat { layout.indentStep }
    var listMarkerGap: CGFloat { layout.listMarkerGap }
    /// Width of the marker column for every list-style row (bullet/numbered/
    /// todo/toggle/templateButton/documentLink). Unified across kinds so list-text
    /// columns line up regardless of marker shape, and so an indented paragraph
    /// at depth N+1 aligns exactly with list text at depth N. Marker glyphs are
    /// right-aligned within the column.
    var listMarkerColumnWidth: CGFloat { layout.listMarkerColumnWidth }

    /// Leading inset for marker-less rows (paragraph, heading, quote, code, divider).
    /// At depth N>0, aligns with where a list item at depth N-1 puts its TEXT — so
    /// depth reads consistently across block kinds.
    func nonListLeading(depth: Int) -> CGFloat {
        depth <= 0 ? 0 : CGFloat(depth - 1) * indentStep + listMarkerColumnWidth + listMarkerGap
    }
    var listMarkerFrameHeight: CGFloat { 16 }
    var bulletMarkerDiameter: CGFloat { 6 }
    var bulletMarkerColumnWidth: CGFloat { listMarkerColumnWidth }
    var bulletMarkerBaselineOffset: CGFloat { 5 }
    var numberedMarkerColumnWidth: CGFloat { listMarkerColumnWidth }
    var todoMarkerColumnWidth: CGFloat { listMarkerColumnWidth }
    var todoCheckboxSize: CGFloat { 16 }

    // MARK: Toggle / documentLink
    var chevronSize: CGFloat { 12 }
    var pageIconSize: CGFloat { 14 }
    /// A title emoji standing in for the page icon reads small next to the
    /// SF Symbol at the same point size; render it a touch larger. It sits
    /// in the same fixed-height marker frame, so the row height is unchanged.
    var documentLinkEmojiIconSize: CGFloat { 17 }
    /// Emoji glyphs render ~1.2× their point size wide. `markerCenteringOffset`
    /// centers a right-aligned marker by its *visual width*, so feed it the
    /// emoji's advance (not its point size) or the glyph lands a couple px
    /// too far left.
    var documentLinkEmojiIconAdvance: CGFloat { documentLinkEmojiIconSize * 1.2 }

    /// Visual shift (in pt) to apply to a right-aligned marker so its horizontal center
    /// matches the bullet marker's center. Bullet is `bulletMarkerDiameter` wide and sits
    /// at the right edge of `bulletMarkerColumnWidth`; a wider marker right-aligned in the
    /// same column has its center further left by `(width - bulletMarkerDiameter) / 2`.
    /// Apply via `.offset(x:)` *after* the marker's `.frame(...)` so layout (and therefore
    /// the text column) is unaffected.
    func markerCenteringOffset(markerWidth: CGFloat) -> CGFloat {
        (markerWidth - bulletMarkerDiameter) / 2
    }
}

/// Sibling-aware spacing modelled on Notion's pre-March-2026 CSS as preserved in
/// `react-notion-x/packages/react-notion-x/src/styles.css` (16px base font).
///
/// Notion uses CSS padding (inside the block's box) plus margin (outside) plus a global
/// `.notion > * { padding: 3px 0 }` rule. Between two stacked blocks the visible gap is
/// `max(prev.bottomMargin, curr.topMargin)` (CSS margin-collapse). SwiftUI doesn't collapse
/// margins, so we compute the gap explicitly and apply it via `.padding(.top, gap)` on the
/// second block.
enum BlockSpacing {
    /// Inter-block gap to insert *above* `current`, given the immediately preceding sibling
    /// in document order (visible-flat order, may be a sibling at a different tree depth).
    static func gap(before current: Block, depth: Int, after prev: Block?, prevDepth: Int) -> CGFloat {
        gap(
            before: VisibleRowKind(current.kind),
            depth: depth,
            after: prev.map { VisibleRowKind($0.kind) },
            prevDepth: prevDepth
        )
    }

    static func gap(before current: VisibleRowKind, depth: Int, after prev: VisibleRowKind?, prevDepth: Int) -> CGFloat {
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
            // Cross-boundary bump simulates Notion's implicit `<ul>` / `<ol>` container margin.
            // SwiftUI's line-leading already contributes ~11pt at a body-text boundary, so the
            // bump only needs to be small there. Headings carry less visual mass below their
            // descender (no body text underneath the baseline), so heading → list needs more
            // explicit gap to read with the same breathing room.
            currTop = max(currTop, isHeading(prev) ? 7 : 3)
        }

        return max(prevBottom, currTop)
    }

    /// Intrinsic padding INSIDE a block's row (between text content and the row's frame edges).
    /// Split top/bottom so headings can clip their oversized font line-leading on whichever side
    /// is adjacent to body text — a symmetric `.padding(.vertical, X)` couldn't do that.
    /// Negative values are allowed: SwiftUI honors negative padding, and it's the only way to
    /// pull the row frame *inside* the font's built-in leading (cap-top buffer / descender
    /// buffer). See `intrinsicTopPadding` / `intrinsicBottomPadding`.
    static func intrinsicTopPadding(_ block: Block) -> CGFloat {
        switch block.kind {
        case .bullet, .numbered, .todo, .documentLink, .toggle, .templateButton: return 5
        case .code: return 16
        case .heading: return 0
        default: return 3
        }
    }

    static func intrinsicBottomPadding(_ block: Block) -> CGFloat {
        switch block.kind {
        case .bullet, .numbered, .todo, .documentLink, .toggle, .templateButton: return 5
        case .code: return 16
        case .heading: return 0
        default: return 3
        }
    }

    /// Y offset applied to the drag handle so its grip-dots-center lands on the
    /// first line's visual center. The handle's frame is 28pt tall with the
    /// grip glyph centered, so the dots-center sits 14pt below the frame top —
    /// we shift the frame up/down to put that 14pt mark at the right place per
    /// block kind. Body-font blocks (paragraph/quote/list items) only differ
    /// in `intrinsicTopPadding`; headings start at the row top but have larger
    /// fonts; code lives deep inside its row.
    static func dragHandleYOffset(_ block: Block) -> CGFloat {
        switch block.kind {
        case .heading: return 2
        case .bullet, .numbered, .todo, .documentLink, .toggle, .templateButton: return 2
        case .code: return 8
        case .paragraph, .quote, .divider, .image: return 0
        // Unsupported blocks render as a fenced preview, same shape as code.
        case .unsupported: return 8
        }
    }

    /// Top-margins reverse-engineered from real Notion screenshots (not from react-notion-x's CSS,
    /// which doesn't match). Headings carry generous breathing room above; paragraphs sit on a
    /// margin that gives the ~24pt visual ink-to-ink gap Notion shows between stacked paragraphs
    /// and after an H2; list items get a non-zero top margin so item-to-item gaps match
    /// `notion_prompt_example.png` (the nested-child branch in `gap(...)` forces currTop = 0,
    /// so nested items still pack tight).
    private static func topMargin(_ kind: VisibleRowKind) -> CGFloat {
        switch kind {
        case .heading(.h1): return 40
        case .heading(.h2): return 40
        case .heading(.h3): return 30
        // H4–H6 are preserve-only and read as sub-sub-sections; they get the
        // smallest heading margin rather than a new step per level.
        case .heading(.h4), .heading(.h5), .heading(.h6): return 24
        case .paragraph: return 4
        case .quote: return 4
        case .code: return 8
        case .divider: return 12
        case .image: return 8
        case .unsupported: return 8
        case .documentLink, .bullet, .numbered, .todo, .toggle, .templateButton: return 1
        }
    }

    private static func topMargin(_ block: Block) -> CGFloat {
        topMargin(VisibleRowKind(block.kind))
    }

    private static func bottomMargin(_ kind: VisibleRowKind) -> CGFloat {
        switch kind {
        case .heading(.h1): return 0
        case .heading: return 0
        case .paragraph: return 3
        case .quote: return 4
        case .code: return 8
        case .divider: return 12
        case .image: return 8
        case .unsupported: return 8
        case .documentLink, .bullet, .numbered, .todo, .toggle, .templateButton: return 0
        }
    }

    private static func bottomMargin(_ block: Block) -> CGFloat {
        bottomMargin(VisibleRowKind(block.kind))
    }

    private static func isHeading(_ kind: VisibleRowKind) -> Bool {
        kind.isHeading
    }

    private static func isHeading(_ block: Block) -> Bool {
        isHeading(VisibleRowKind(block.kind))
    }

    private static func isListItem(_ kind: VisibleRowKind) -> Bool {
        switch kind {
        case .bullet, .numbered, .todo, .documentLink, .toggle, .templateButton:
            return true
        default:
            return false
        }
    }

    private static func isListItem(_ block: Block) -> Bool {
        isListItem(VisibleRowKind(block.kind))
    }
}
