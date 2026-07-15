import SwiftUI
import Editor
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One recording session shared by every page toolbar in a window. Keeping the
/// recorder above the navigation stack prevents mounted-but-hidden pages from
/// starting (and retaining) their own microphone sessions for one shortcut.
@MainActor
@Observable
final class VoiceRecordingSession {
    private enum Destination {
        case editor(EditorState, pageID: String)
        case home(pageID: String)
    }

    private let recorder = PageSpeechRecorder()
    private var destination: Destination?
    private(set) var isTransitioning = false
    var errorMessage: String?

    var state: PageSpeechRecorder.State { recorder.state }

    func toggleFromToolbar(editorState: EditorState, window: WorkspaceWindow) async {
        switch state {
        case .idle:
            guard let pageID = window.currentPageRelativePath else {
                errorMessage = "The current page is not ready for recording."
                return
            }
            await start(destination: .editor(editorState, pageID: pageID))
        case .recording:
            await stopAndDeliver(using: window)
        case .transcribing:
            break
        }
    }

    func toggleFromShortcut(homePageID: String, window: WorkspaceWindow) async {
        switch state {
        case .idle:
            window.navigateFromSearch(relativePath: homePageID)
            await start(destination: .home(pageID: homePageID))
        case .recording:
            await stopAndDeliver(using: window)
        case .transcribing:
            break
        }
    }

    func reportMissingHome() {
        errorMessage = "Set a Home page before starting a recording from a Shortcut or the Action Button."
    }

    func cancel() {
        recorder.cancel()
        destination = nil
        isTransitioning = false
    }

    private func start(destination: Destination) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            try await recorder.start()
            self.destination = destination
        } catch {
            recorder.cancel()
            self.destination = nil
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndDeliver(using window: WorkspaceWindow) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        let destination = destination
        self.destination = nil
        defer { isTransitioning = false }

        do {
            let transcript = try await recorder.stopAndTranscribe()
            try await deliver(transcript, to: destination, using: window)
        } catch {
            recorder.cancel()
            errorMessage = error.localizedDescription
        }
    }

    private func deliver(
        _ text: String,
        to destination: Destination?,
        using window: WorkspaceWindow
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let destination else { return }

        let block = Block.paragraph(text: AttributedString(trimmed))
        switch destination {
        case .home(let pageID):
            guard let clamshell = window.workspace.clamshell else {
                throw VoiceRecordingSessionError.workspaceUnavailable
            }
            do {
                try await clamshell.appendBlocks([block], toPage: pageID)
            } catch {
                throw VoiceRecordingSessionError.couldNotAppendToHome(underlying: error.localizedDescription)
            }

        case .editor(let editorState, let pageID):
            if window.currentPageRelativePath == pageID {
                if editorState.editingBlock != nil,
                   sendInsertActionToFirstResponder(trimmed) {
                    return
                }
                editorState.appendBlocks([block], actionName: "Insert Transcript")
            } else {
                guard let clamshell = window.workspace.clamshell else {
                    throw VoiceRecordingSessionError.workspaceUnavailable
                }
                try await clamshell.appendBlocks([block], toPage: pageID)
            }
        }
    }

    private func sendInsertActionToFirstResponder(_ text: String) -> Bool {
        #if os(macOS)
        return NSApp.sendAction(
            #selector(NSText.insertText(_:)),
            to: nil,
            from: text
        )
        #else
        return UIApplication.shared.sendAction(
            #selector(UIKeyInput.insertText(_:)),
            to: nil,
            from: text,
            for: nil
        )
        #endif
    }
}

private enum VoiceRecordingSessionError: LocalizedError {
    case workspaceUnavailable
    case couldNotAppendToHome(underlying: String)

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace is not available for this recording."
        case .couldNotAppendToHome(let underlying):
            "The recording could not be added to Home: \(underlying)"
        }
    }
}

/// Mic / stop / progress button shown in the page toolbar. Every mounted page
/// observes the same window-level session, so the visible toolbar can stop a
/// recording that was started by a Shortcut or the Action Button.
struct RecordingButton: View {
    let editorState: EditorState
    let recordingSession: VoiceRecordingSession
    let window: WorkspaceWindow

    var body: some View {
        Button {
            Task { await recordingSession.toggleFromToolbar(editorState: editorState, window: window) }
        } label: {
            switch recordingSession.state {
            case .idle:
                if recordingSession.isTransitioning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "mic")
                }
            case .recording:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(recordingSession.isTransitioning || recordingSession.state == .transcribing)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch recordingSession.state {
        case .idle:         return recordingSession.isTransitioning ? "Starting Recording" : "Record Audio"
        case .recording:    return "Stop Recording"
        case .transcribing: return "Transcribing"
        }
    }
}
