import SwiftUI

struct InlineCodeChipAttribute: TextAttribute {}

struct InlineCodeChipRenderer: TextRenderer {
    var displayPadding: EdgeInsets {
        EdgeInsets(
            top: NotionStyle.inlineCodeVerticalPadding,
            leading: 0,
            bottom: NotionStyle.inlineCodeVerticalPadding,
            trailing: 0
        )
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InlineCodeChipAttribute.self] != nil {
                let rect = run.typographicBounds.rect.insetBy(
                    dx: 0,
                    dy: -NotionStyle.inlineCodeVerticalPadding
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: NotionStyle.inlineCodeRadius),
                    with: .color(NotionStyle.codeBackground)
                )
            }
        }

        for line in layout {
            context.draw(line)
        }
    }
}
