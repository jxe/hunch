import Foundation
import Quagmire
import QuagmireExtras

typealias HunchVoiceRecordingSession = VoiceRecordingSession<String>

@MainActor
enum HunchVoice {
    static func makeSession(window: WorkspaceWindow) -> HunchVoiceRecordingSession {
        HunchVoiceRecordingSession(
            recoveryStore: PendingVoiceRecordingStore(directoryURL: pendingRecordingsDirectory()),
            loggingSubsystem: Bundle.main.bundleIdentifier,
            recoveryDelivery: { [weak window] transcript, pageID in
                guard let window else { throw HunchVoiceDeliveryError.workspaceUnavailable }
                try await append(transcript, to: pageID, using: window)
            }
        )
    }

    static func startFromToolbar(
        session: HunchVoiceRecordingSession,
        editorState: EditorState,
        window: WorkspaceWindow
    ) async {
        guard let pageID = window.currentPageRelativePath else {
            session.reportError("The current page is not ready for recording.")
            return
        }
        await session.start(destination: pageID) { [weak window, weak editorState] transcript, pageID in
            guard let window else { throw HunchVoiceDeliveryError.workspaceUnavailable }
            if window.currentPageRelativePath == pageID, let editorState {
                if editorState.editingBlock != nil,
                   VoiceTranscriptInsertion.insertIntoFirstResponder(transcript) {
                    return
                }
                editorState.appendBlocks(
                    [.paragraph(text: AttributedString(transcript))],
                    actionName: "Insert Transcript"
                )
            } else {
                try await append(transcript, to: pageID, using: window)
            }
        }
    }

    static func toggleFromShortcut(
        session: HunchVoiceRecordingSession,
        homePageID: String,
        window: WorkspaceWindow
    ) async {
        switch session.state {
        case .idle:
            window.navigateFromSearch(relativePath: homePageID)
            await session.start(destination: homePageID)
        case .recording:
            await session.stopAndDeliver()
        case .transcribing:
            session.cancelTranscription()
        }
    }

    private static func append(
        _ transcript: String,
        to pageID: String,
        using window: WorkspaceWindow
    ) async throws {
        guard let clamshell = window.workspace.clamshell else {
            throw HunchVoiceDeliveryError.workspaceUnavailable
        }
        do {
            try await clamshell.page(atPath: pageID).append([
                .paragraph(text: AttributedString(transcript))
            ])
        } catch {
            throw HunchVoiceDeliveryError.couldNotAppendToPage(
                underlying: error.localizedDescription
            )
        }
    }

    private static func pendingRecordingsDirectory() -> URL {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("Pending Voice Recordings", isDirectory: true)
    }
}

private enum HunchVoiceDeliveryError: LocalizedError {
    case workspaceUnavailable
    case couldNotAppendToPage(underlying: String)

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace is not available for this recording."
        case .couldNotAppendToPage(let underlying):
            "The recording could not be added to its page: \(underlying)"
        }
    }
}
