import Testing
import Foundation
@testable import Hunch
import Quagmire

@Suite("FileStore")
struct FileStoreTests {
    @Test @MainActor func loadDocumentTitleUsesFirstH1WithFilenameFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let titled = dir.appendingPathComponent("alpha.md")
        try "Intro\n\n# Project Alpha\n".write(to: titled, atomically: true, encoding: .utf8)
        #expect(try FileStore().loadDocumentTitle(at: titled) == "Project Alpha")

        let untitled = dir.appendingPathComponent("beta.md")
        try "Just text\n".write(to: untitled, atomically: true, encoding: .utf8)
        #expect(try FileStore().loadDocumentTitle(at: untitled) == "beta")
    }

    @Test func scanFindsMarkdownFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# A".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# B".write(to: nested.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.count == 2)
        #expect(entries.contains { $0.relativePath == "a.md" })
        #expect(entries.contains { $0.relativePath == "nested/b.md" })
    }

    @Test func scanSkipsAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-assets-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# Page".write(to: dir.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        let assets = dir.appendingPathComponent(FileStore.assetsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("foo.png"))
        // A stray .md file accidentally placed inside Assets/ should also be skipped —
        // the folder is reserved for image bytes, not pages.
        try "# Stray".write(to: assets.appendingPathComponent("stray.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.map(\.relativePath) == ["page.md"])
    }

    @Test func scanSkipsWorkspaceTrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-trash-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# Keep".write(to: dir.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        let trash = dir.appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try "# Gone".write(to: trash.appendingPathComponent("gone.md"), atomically: true, encoding: .utf8)

        let entries = try FileStore().scan(workspaceRoot: dir)
        #expect(entries.map(\.relativePath) == ["keep.md"])
    }

    @Test func localWritableAvailabilityAcceptsLocalWritableFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-local-writable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let page = dir.appendingPathComponent("page.md")
        try "# Page".write(to: page, atomically: true, encoding: .utf8)

        let store = FileStore()
        #expect(store.isLocallyWritable(page))
        try store.requireLocallyWritable(page)
    }

    @Test func localWritableAvailabilityRejectsMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-missing-writable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let page = dir.appendingPathComponent("missing.md")
        let store = FileStore()

        #expect(!store.isLocallyWritable(page))
        #expect(throws: FileStoreError.self) {
            try store.requireLocallyWritable(page)
        }
    }

    @Test func moveToTrashPreservesRelativePathAndUniquesCollisions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-trash-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# One".write(to: nested.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
        let existingTrash = dir
            .appendingPathComponent(FileStore.trashDirectoryName, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: existingTrash, withIntermediateDirectories: true)
        try "# Old".write(to: existingTrash.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)

        let trashedPath = try FileStore().moveToTrash(relativePath: "nested/page.md", workspaceRoot: dir)

        #expect(trashedPath == "\(FileStore.trashDirectoryName)/nested/page-2.md")
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("page.md").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(trashedPath).path))
    }
}

@Suite("Pending voice recordings")
struct PendingVoiceRecordingStoreTests {
    @Test func keepsRecordingUntilExplicitRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-pending-recordings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PendingVoiceRecordingStore(directoryURL: directory)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = try store.begin(pageID: "notes/meeting.md", now: createdAt)

        #expect(try store.pendingRecordings().isEmpty)

        try Data([0x01, 0x02, 0x03]).write(to: store.audioURL(for: recording))
        #expect(try store.pendingRecordings() == [recording])
        #expect(recording.pageID == "notes/meeting.md")
        #expect(recording.createdAt == createdAt)

        try store.remove(recording)
        #expect(try store.pendingRecordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))
    }

    @Test func returnsRecoveriesOldestFirst() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-pending-recordings-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PendingVoiceRecordingStore(directoryURL: directory)
        let later = try store.begin(pageID: "later.md", now: Date(timeIntervalSince1970: 20))
        let earlier = try store.begin(pageID: "earlier.md", now: Date(timeIntervalSince1970: 10))
        try Data([0x01]).write(to: store.audioURL(for: later))
        try Data([0x01]).write(to: store.audioURL(for: earlier))

        #expect(try store.pendingRecordings().map(\.pageID) == ["earlier.md", "later.md"])
    }

    @Test func discardsRecordingsThatCannotProduceATranscript() {
        #expect(
            PendingVoiceRecordingFailureDisposition(
                error: PageSpeechRecorderError.noAudioCaptured
            ) == .discard
        )
        #expect(
            PendingVoiceRecordingFailureDisposition(
                error: PageSpeechRecorderError.noTranscribableSpeech
            ) == .discard
        )
        #expect(
            PendingVoiceRecordingFailureDisposition(
                error: VoiceRecordingSessionError.emptyTranscript
            ) == .discard
        )
    }

    @Test func preservesRecordingsAfterRetryableFailures() {
        #expect(
            PendingVoiceRecordingFailureDisposition(
                error: PageSpeechRecorderError.transcriptionUnavailable
            ) == .preserve
        )
        #expect(
            PendingVoiceRecordingFailureDisposition(error: CancellationError()) == .preserve
        )
    }
}
