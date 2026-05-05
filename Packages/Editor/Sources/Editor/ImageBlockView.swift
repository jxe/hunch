import SwiftUI

/// Renders a `Block.image` row. Resolves `source` (a markdown path like
/// `Assets/foo.png`) via the host-provided `imageURLResolver` Environment
/// value; renders a missing-image placeholder when resolution fails.
///
/// Sync `NSImage(contentsOf:)` / `UIImage(contentsOfFile:)` is fine for local
/// files of typical size. If page render cost becomes noticeable on
/// image-heavy pages, replace with a cached async load.
struct ImageBlockView: View {
    let source: String
    let alt: String
    @Environment(\.imageURLResolver) private var resolver: ImageURLResolver?

    var body: some View {
        let url = resolver?(source)
        Group {
            if let url, let image = loadImage(at: url) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
            } else {
                missingPlaceholder
            }
        }
    }

    private func loadImage(at url: URL) -> SwiftUI.Image? {
        #if os(macOS)
        guard let ns = NSImage(contentsOf: url) else { return nil }
        return SwiftUI.Image(nsImage: ns)
        #else
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return SwiftUI.Image(uiImage: ui)
        #endif
    }

    private var missingPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(NotionStyle.mutedForeground)
            Text("Missing image: \(source)")
                .font(NotionStyle.body())
                .foregroundStyle(NotionStyle.mutedForeground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotionStyle.codeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
