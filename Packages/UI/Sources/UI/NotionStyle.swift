import SwiftUI

public enum NotionStyle {
    // MARK: Colors
    public static let foreground = Color(red: 55/255, green: 53/255, blue: 47/255)        // #37352F
    public static let mutedForeground = Color(red: 55/255, green: 53/255, blue: 47/255).opacity(0.5)
    public static let background = Color.white
    public static let codeForeground = Color(red: 235/255, green: 87/255, blue: 87/255)    // #EB5757
    public static let codeBackground = Color(red: 135/255, green: 131/255, blue: 120/255).opacity(0.15)
    public static let dividerColor = Color(red: 233/255, green: 233/255, blue: 231/255)

    // MARK: Fonts
    public static func body(size: CGFloat = 16) -> Font {
        Font.custom("Inter", size: size, relativeTo: .body)
    }

    public static func mono(size: CGFloat = 14) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced)
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
    public static let listMarkerFrameHeight: CGFloat = 16
    public static let bulletMarkerDiameter: CGFloat = 6
    public static let bulletMarkerColumnWidth: CGFloat = 18
    public static let bulletMarkerBaselineOffset: CGFloat = 5
    public static let numberedMarkerColumnWidth: CGFloat = 24
    public static let todoMarkerColumnWidth: CGFloat = 20
    public static let todoCheckboxSize: CGFloat = 16

    // MARK: Toggle / subpage
    public static let chevronSize: CGFloat = 12
    public static let pageIconSize: CGFloat = 14
}
