import SwiftUI

/// Renders a `Block.image` row. Resolves `source` (a markdown path like
/// `Assets/foo.png`) via the host (`EditorHost.imageURL(for:)`); renders a
/// missing-image placeholder when resolution fails.
///
/// Sync `NSImage(contentsOf:)` / `UIImage(contentsOfFile:)` is fine for local
/// files of typical size. If page render cost becomes noticeable on
/// image-heavy pages, replace with a cached async load.
struct ImageBlockView: View {
    let source: String
    let alt: String
    @Environment(\.editorHost) private var host: EditorHost?
    #if !os(macOS)
    @State private var presentingFullSize = false
    #endif

    var body: some View {
        let url = host?.imageURL(for: source)
        Group {
            if let url, let image = loadImage(at: url) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 400, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                    .onTapGesture { openFullSize(url: url) }
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    #else
                    .sheet(isPresented: $presentingFullSize) {
                        FullSizeImageView(url: url, alt: alt) { presentingFullSize = false }
                    }
                    #endif
            } else {
                missingPlaceholder
            }
        }
    }

    private func openFullSize(url: URL) {
        #if os(macOS)
        presentImageViewerWindow(url: url, alt: alt)
        #else
        presentingFullSize = true
        #endif
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

/// Modal viewer for a single image. Two discrete zoom modes — Preview-style:
/// fit-to-window (default; image scales to fit the viewer) or actual size
/// (1:1 native pixels; ScrollView pans when image overflows). Click the
/// image to toggle. Esc / close button dismiss.
private struct FullSizeImageView: View {
    let url: URL
    let alt: String
    let onClose: () -> Void

    private enum Zoom { case fit, actual }
    @State private var zoom: Zoom = .fit

    var body: some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            #else
            Color(UIColor.systemBackground).ignoresSafeArea()
            #endif

            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image = loadImage(at: url) {
            switch zoom {
            case .fit:
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
                    .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                    .contentShape(Rectangle())
                    .onTapGesture { zoom = .actual }
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering { NSCursor.zoomIn.push() } else { NSCursor.pop() }
                    }
                    #endif
            case .actual:
                ScrollView([.horizontal, .vertical]) {
                    image
                        .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(alt))
                        .onTapGesture { zoom = .fit }
                        #if os(macOS)
                        .onHover { hovering in
                            if hovering { NSCursor.zoomOut.push() } else { NSCursor.pop() }
                        }
                        #endif
                }
            }
        } else {
            Text("Could not load image")
                .foregroundStyle(.secondary)
                .padding()
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
}

#if os(macOS)
import AppKit

/// Holds one persistent image-viewer NSWindow across opens. The window has
/// `isReleasedWhenClosed = false` and is hidden (not deallocated) on close —
/// next open swaps in new content and re-shows it. Letting AppKit deallocate
/// the window on close races with `_NSWindowTransformAnimation`'s deferred
/// cleanup and crashes during the next runloop's autorelease pool drain
/// (use-after-free in the animation's block dispose helpers).
@MainActor
private final class ImageViewerWindowHolder {
    static let shared = ImageViewerWindowHolder()
    private var window: NSWindow?

    func present(url: URL, alt: String) {
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
            let windowFrame = screenFrame.insetBy(dx: screenFrame.width * 0.05, dy: screenFrame.height * 0.05)
            w = NSWindow(
                contentRect: windowFrame,
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        }

        w.title = alt.isEmpty ? "Image" : alt
        w.contentView = NSHostingView(
            rootView: FullSizeImageView(url: url, alt: alt) { [weak w] in
                w?.orderOut(nil)
            }
        )
        if !w.isVisible {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private func presentImageViewerWindow(url: URL, alt: String) {
    ImageViewerWindowHolder.shared.present(url: url, alt: alt)
}
#endif
