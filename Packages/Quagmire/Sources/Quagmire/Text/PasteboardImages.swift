import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// File extensions the editor accepts when a pasteboard item is a file URL.
/// Anything outside this list falls through to text/string paste handling.
private let supportedImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"
]

#if os(macOS)
/// Pull image bytes (or image file URLs) off an NSPasteboard. PNG / TIFF
/// representations come through as raw bytes; file copies show up as
/// `.fileURL` items. Order: PNG first (preferred), then TIFF re-encoded
/// to PNG, then file URLs we recognise as images. Empty array means
/// "no image — caller should fall through to text paste".
func readPasteboardImages(_ pasteboard: NSPasteboard) -> [PastedImage] {
    var out: [PastedImage] = []

    if let png = pasteboard.data(forType: .png) {
        out.append(PastedImage(data: png, ext: "png"))
        return out
    }
    if let tiff = pasteboard.data(forType: .tiff),
       let png = tiff.tiffToPNG() {
        out.append(PastedImage(data: png, ext: "png"))
        return out
    }

    // File URLs — Finder copies show up here. Each item is an NSURL on the
    // pasteboard; only accept file:// URLs whose extension is in the
    // supported list. Web URLs fall through to text paste.
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
        for url in urls {
            guard url.isFileURL else { continue }
            let ext = url.pathExtension.lowercased()
            guard supportedImageExtensions.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            out.append(PastedImage(data: data, ext: ext))
        }
    }

    return out
}

private extension Data {
    /// Re-encode TIFF bytes as PNG via NSBitmapImageRep. Notion-style
    /// pasteboards from screenshots come through as TIFF; we'd rather
    /// store PNG on disk for size and tooling.
    func tiffToPNG() -> Data? {
        guard let rep = NSBitmapImageRep(data: self) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Read the richest text representation off `pasteboard`. Order: RTFD
/// (carries inline images, but we don't extract them here — only the
/// text + marks), then RTF, then HTML. Returns nil when only plain
/// text is on the board so callers can fall through to the platform's
/// native plain-text paste.
func readPasteboardRichText(_ pasteboard: NSPasteboard) -> NSAttributedString? {
    if let data = pasteboard.data(forType: .rtfd),
       let attr = NSAttributedString(rtfd: data, documentAttributes: nil) {
        return attr
    }
    if let data = pasteboard.data(forType: .rtf),
       let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
        return attr
    }
    if let data = pasteboard.data(forType: .html),
       let attr = try? NSAttributedString(
           data: data,
           options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue
           ],
           documentAttributes: nil) {
        return attr
    }
    return nil
}
#else
/// Pull image bytes (or image file URLs) off a UIPasteboard. UIPasteboard's
/// `images` covers the common case (Photos, browser image-copy). For file
/// URLs we fall back to type-identifier lookup.
func readPasteboardImages(_ pasteboard: UIPasteboard) -> [PastedImage] {
    var out: [PastedImage] = []

    if pasteboard.hasImages, let images = pasteboard.images {
        for image in images {
            if let data = image.pngData() {
                out.append(PastedImage(data: data, ext: "png"))
            }
        }
        if !out.isEmpty { return out }
    }

    // Fallback: a file-URL item on the pasteboard. UIPasteboard.urls includes
    // both http(s) and file URLs; filter to file URLs with image extensions.
    if let urls = pasteboard.urls {
        for url in urls where url.isFileURL {
            let ext = url.pathExtension.lowercased()
            guard supportedImageExtensions.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            out.append(PastedImage(data: data, ext: ext))
        }
    }

    return out
}

/// iOS twin of the macOS reader. UTI strings rather than `UIPasteboard.PasteboardType`
/// because UTType constants for RTFD/RTF/HTML aren't surfaced as enum cases.
func readPasteboardRichText(_ pasteboard: UIPasteboard) -> NSAttributedString? {
    if let data = pasteboard.data(forPasteboardType: "com.apple.flat-rtfd"),
       let attr = try? NSAttributedString(
           data: data,
           options: [.documentType: NSAttributedString.DocumentType.rtfd],
           documentAttributes: nil) {
        return attr
    }
    if let data = pasteboard.data(forPasteboardType: "public.rtf"),
       let attr = try? NSAttributedString(
           data: data,
           options: [.documentType: NSAttributedString.DocumentType.rtf],
           documentAttributes: nil) {
        return attr
    }
    if let data = pasteboard.data(forPasteboardType: "public.html"),
       let attr = try? NSAttributedString(
           data: data,
           options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue
           ],
           documentAttributes: nil) {
        return attr
    }
    return nil
}
#endif
