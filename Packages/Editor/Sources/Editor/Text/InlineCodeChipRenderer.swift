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
            for rect in inlineCodeRects(in: line) {
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

    private func inlineCodeRects(in line: Text.Layout.Line) -> [CGRect] {
        let sourceRects = line.compactMap { run -> CGRect? in
            guard run[InlineCodeChipAttribute.self] != nil else { return nil }
            return run.typographicBounds.rect
        }
        guard !sourceRects.isEmpty else { return [] }

        let mergedRects = sourceRects
            .sorted { $0.minX < $1.minX }
            .reduce(into: [CGRect]()) { partial, rect in
                guard let last = partial.last else {
                    partial.append(rect)
                    return
                }

                if rect.minX <= last.maxX + 0.5 {
                    partial[partial.count - 1] = last.union(rect)
                } else {
                    partial.append(rect)
                }
            }

        return mergedRects.map {
            $0.insetBy(
                dx: 0,
                dy: -NotionStyle.inlineCodeVerticalPadding
            )
        }
    }
}
