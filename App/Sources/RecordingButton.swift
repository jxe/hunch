import SwiftUI
import Quagmire
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
        case page(pageID: String)
    }

    private let recorder: PageSpeechRecorder
    private let recoveryStore: PendingVoiceRecordingStore
    private var destination: Destination?
    private var activeRecording: PendingVoiceRecording?
    private var deferredRecoveryIDs: Set<UUID> = []
    private(set) var isTransitioning = false
    private(set) var pendingRecovery: PendingVoiceRecording?
    var errorMessage: String?

    var state: PageSpeechRecorder.State { recorder.state }

    init(recoveryStore: PendingVoiceRecordingStore = .live) {
        self.recorder = PageSpeechRecorder()
        self.recoveryStore = recoveryStore
        refreshPendingRecovery()
        recorder.unexpectedStopHandler = { [weak self] message in
            self?.handleUnexpectedStop(message)
        }
    }

    func toggleFromToolbar(editorState: EditorState, window: WorkspaceWindow) async {
        switch state {
        case .idle:
            guard let pageID = window.currentPageRelativePath else {
                errorMessage = "The current page is not ready for recording."
                return
            }
            await start(destination: .editor(editorState, pageID: pageID), pageID: pageID)
        case .recording:
            await stopAndDeliver(using: window)
        case .transcribing:
            cancelTranscription()
        }
    }

    func toggleFromShortcut(homePageID: String, window: WorkspaceWindow) async {
        switch state {
        case .idle:
            window.navigateFromSearch(relativePath: homePageID)
            await start(destination: .page(pageID: homePageID), pageID: homePageID)
        case .recording:
            await stopAndDeliver(using: window)
        case .transcribing:
            cancelTranscription()
        }
    }

    func reportMissingHome() {
        errorMessage = "Set a Home page before starting a recording from a Shortcut or the Action Button."
    }

    func cancel() {
        recorder.cancel()
        if let activeRecording {
            try? recoveryStore.remove(activeRecording)
        }
        activeRecording = nil
        destination = nil
        isTransitioning = false
    }

    func recoverPendingRecording(using window: WorkspaceWindow) async {
        guard !isTransitioning, state == .idle, let recording = pendingRecovery else { return }
        pendingRecovery = nil
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            let transcript = try await recorder.transcribeSavedRecording(
                at: recoveryStore.audioURL(for: recording)
            )
            try await deliver(transcript, to: .page(pageID: recording.pageID), using: window)
            try recoveryStore.remove(recording)
        } catch {
            if PendingVoiceRecordingFailureDisposition(error: error) == .discard {
                try? recoveryStore.remove(recording)
            } else {
                deferredRecoveryIDs.insert(recording.id)
            }
            errorMessage = recoveryFailureMessage(for: error)
        }
        refreshPendingRecovery()
    }

    func deferPendingRecovery() {
        if let pendingRecovery {
            deferredRecoveryIDs.insert(pendingRecovery.id)
        }
        pendingRecovery = nil
    }

    private func start(destination: Destination, pageID: String) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            let recording = try recoveryStore.begin(pageID: pageID)
            activeRecording = recording
            try await recorder.start(recordingAt: recoveryStore.audioURL(for: recording))
            self.destination = destination
        } catch {
            recorder.cancel()
            if let activeRecording {
                try? recoveryStore.remove(activeRecording)
            }
            activeRecording = nil
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
            if let activeRecording {
                try recoveryStore.remove(activeRecording)
            }
            activeRecording = nil
        } catch {
            recorder.cancel(discardingAudio: false)
            if PendingVoiceRecordingFailureDisposition(error: error) == .discard,
               let activeRecording {
                try? recoveryStore.remove(activeRecording)
            }
            activeRecording = nil
            refreshPendingRecovery()
            errorMessage = recoveryFailureMessage(for: error)
        }
    }

    private func cancelTranscription() {
        recorder.cancelTranscription()
    }

    private func deliver(
        _ text: String,
        to destination: Destination?,
        using window: WorkspaceWindow
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceRecordingSessionError.emptyTranscript
        }
        guard let destination else { return }

        let block = Block.paragraph(text: AttributedString(trimmed))
        switch destination {
        case .page(let pageID):
            guard let clamshell = window.workspace.clamshell else {
                throw VoiceRecordingSessionError.workspaceUnavailable
            }
            do {
                try await clamshell.page(atPath: pageID).append([block])
            } catch {
                throw VoiceRecordingSessionError.couldNotAppendToPage(underlying: error.localizedDescription)
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
                try await clamshell.page(atPath: pageID).append([block])
            }
        }
    }

    private func handleUnexpectedStop(_ message: String) {
        destination = nil
        activeRecording = nil
        isTransitioning = false
        refreshPendingRecovery()
        errorMessage = message
    }

    private func refreshPendingRecovery() {
        pendingRecovery = (try? recoveryStore.pendingRecordings())?
            .first { !deferredRecoveryIDs.contains($0.id) }
    }

    private func recoveryFailureMessage(for error: Error) -> String {
        if PendingVoiceRecordingFailureDisposition(error: error) == .discard {
            return error.localizedDescription
        }
        if error is CancellationError {
            return "Transcription was canceled. The audio was preserved and can be recovered later."
        }
        return "\(error.localizedDescription) The audio was preserved and can be recovered later."
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

enum PendingVoiceRecordingFailureDisposition: Equatable {
    case discard
    case preserve

    init(error: Error) {
        if let recorderError = error as? PageSpeechRecorderError {
            switch recorderError {
            case .noAudioCaptured, .noTranscribableSpeech:
                self = .discard
            default:
                self = .preserve
            }
        } else if let sessionError = error as? VoiceRecordingSessionError,
                  case .emptyTranscript = sessionError {
            self = .discard
        } else {
            self = .preserve
        }
    }
}

enum VoiceRecordingSessionError: LocalizedError {
    case workspaceUnavailable
    case couldNotAppendToPage(underlying: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace is not available for this recording."
        case .couldNotAppendToPage(let underlying):
            "The recording could not be added to its page: \(underlying)"
        case .emptyTranscript:
            "No speech could be transcribed from the recording."
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
                    .overlay {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
            }
        }
        .disabled(recordingSession.isTransitioning && recordingSession.state != .transcribing)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch recordingSession.state {
        case .idle:         return recordingSession.isTransitioning ? "Starting Recording" : "Record Audio"
        case .recording:    return "Stop Recording"
        case .transcribing: return "Cancel Transcription"
        }
    }
}
