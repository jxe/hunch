import Foundation
import LinkPresentation
import Editor
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pulls page metadata + favicon for a single URL using Apple's
/// `LinkPresentation` framework. Handles the platform-specific image plumbing
/// (UIImage vs NSImage) and resizes the favicon down to a small PNG suitable
/// for inline `Text` rendering.
///
/// `LPMetadataProvider` is documented as main-thread-only, so the whole
/// fetcher runs on `@MainActor`. The actor that drives it (`LinkPreviewService`)
/// hops over here and back via `await`.
@MainActor
enum LinkPreviewFetcher {
    /// Native pixel size of the favicon we persist. Decoded back at 2x scale
    /// so it renders inside `Text` at `NotionStyle.pageIconSize` (14pt) logical,
    /// matching the small `doc.text` icon used in subpage rows. Stored as
    /// `Data` so the actor cache stays `Sendable`.
    private static let iconPixelSize: CGFloat = 28

    static func fetch(url: URL) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            return nil
        }
        let title = metadata.title
        let iconPNG = await loadIconPNG(from: metadata.iconProvider)
        // Treat a fetch with neither title nor icon as a failure — there's
        // nothing to decorate with.
        if title == nil && iconPNG == nil { return nil }
        return LinkPreview(url: url, title: title, iconPNG: iconPNG)
    }

    private static func loadIconPNG(from itemProvider: NSItemProvider?) async -> Data? {
        guard let itemProvider else { return nil }
        #if os(macOS)
        guard itemProvider.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { cont in
            itemProvider.loadObject(ofClass: NSImage.self) { object, _ in
                cont.resume(returning: object as? NSImage)
            }
        }
        guard let image else { return nil }
        return resizeToPNG(image)
        #else
        guard itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
        let image: UIImage? = await withCheckedContinuation { cont in
            itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: object as? UIImage)
            }
        }
        guard let image else { return nil }
        return resizeToPNG(image)
        #endif
    }

    #if os(macOS)
    private static func resizeToPNG(_ image: NSImage) -> Data? {
        let target = NSSize(width: iconPixelSize, height: iconPixelSize)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #else
    private static func resizeToPNG(_ image: UIImage) -> Data? {
        let target = CGSize(width: iconPixelSize, height: iconPixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.pngData()
    }
    #endif
}
