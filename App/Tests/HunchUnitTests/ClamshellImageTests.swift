import Testing
import Foundation
@testable import Hunch
import Quagmire

@Suite("Clamshell image writes")
@MainActor
struct ClamshellImageTests {
    @Test func writeImageStoresPNGUnderAssetsAndResolves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clamshell = Clamshell(root: root)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG header
        let path = try clamshell.writeImage(PastedImage(data: bytes, ext: "png"))

        #expect(path.hasPrefix("Assets/pasted-"))
        #expect(path.hasSuffix(".png"))

        let onDisk = root.appendingPathComponent(path)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try Data(contentsOf: onDisk) == bytes)

        // Resolver returns the same URL when the file exists.
        let resolved = clamshell.resolveImage(source: path)
        #expect(resolved?.standardizedFileURL == onDisk.standardizedFileURL)

        // Missing reference → nil so the renderer shows a placeholder.
        #expect(clamshell.resolveImage(source: "Assets/does-not-exist.png") == nil)

        // Path-traversal attempt outside the workspace must be rejected.
        #expect(clamshell.resolveImage(source: "../escape.png") == nil)
    }

    @Test func writeImageSanitizesExtensionToAlphanumeric() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clamshell = Clamshell(root: root)
        // Hostile extension with a slash + traversal component is reduced to
        // alphanumerics so the filename can't escape Assets/.
        let path = try clamshell.writeImage(PastedImage(data: Data([0x00]), ext: "png/../sneaky"))
        #expect(!path.contains(".."))
        #expect(path.hasPrefix("Assets/"))
    }
}
