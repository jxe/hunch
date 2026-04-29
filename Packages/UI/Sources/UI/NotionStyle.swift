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
    public static let headingWeight: Font.Weight = .semibold

    // MARK: Heading sizes (em-relative to 16px base)
    public static let h1Size: CGFloat = 30
    public static let h2Size: CGFloat = 24
    public static let h3Size: CGFloat = 20

    // MARK: Page layout
    public static let maxContentWidth: CGFloat = 708
    public static let pageHorizontalPadding: CGFloat = 16

    // MARK: Inline code
    public static let inlineCodeSize: CGFloat = 13.6
    public static let inlineCodeRadius: CGFloat = 3
    public static let inlineCodeHorizontalPadding: CGFloat = 4

    // MARK: List indentation
    public static let indentStep: CGFloat = 24

    // MARK: Toggle / subpage
    public static let chevronSize: CGFloat = 12
    public static let pageIconSize: CGFloat = 14
}
