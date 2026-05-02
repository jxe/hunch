import SwiftUI

// MARK: - Voice recording / speech-to-text
//
// Toolbar mic button + the host-driven start hook
// (`EditorState.requestStartVoiceRecording()` bumps `voiceRecordingStartTicket`
// — the editor watches that and runs the same path as the mic button).
// Transcripts are inserted either into the active editor's text via
// `insertText:` (for live typing experience while still in edit mode) or
// as a new paragraph at end-of-doc.

extension EditorView {
    func handleVoiceRecordingStart() async {
        await handleSpeechRecordButton()
    }

    var speechErrorBinding: Binding<Bool> {
        Binding(
            get: { speechError != nil },
            set: { newValue in if !newValue { speechError = nil } }
        )
    }

    var speechToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    var speechRecordButton: some View {
        Button {
            Task { await handleSpeechRecordButton() }
        } label: {
            switch speechRecorder.state {
            case .idle:
                Image(systemName: "mic")
            case .recording:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(speechRecorder.state == .transcribing)
        .help(speechRecordButtonHelp)
        .accessibilityLabel(speechRecordButtonHelp)
    }

    fileprivate var speechRecordButtonHelp: String {
        switch speechRecorder.state {
        case .idle:
            return "Record Audio"
        case .recording:
            return "Stop Recording"
        case .transcribing:
            return "Transcribing"
        }
    }

    fileprivate func handleSpeechRecordButton() async {
        do {
            switch speechRecorder.state {
            case .idle:
                try await speechRecorder.start()
            case .recording:
                let transcript = try await speechRecorder.stopAndTranscribe()
                insertTranscript(transcript)
            case .transcribing:
                break
            }
        } catch {
            speechRecorder.cancel()
            speechError = error.localizedDescription
        }
    }

    fileprivate func insertTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if state.editingBlock != nil,
           sendInsertActionToFirstResponder(trimmed) {
            exitEditMode()
            return
        }

        let newBlock = Block.paragraph(text: AttributedString(trimmed))
        mutate("Insert Transcript") {
            document.blocks.append(newBlock)
        }
        focusPageNavigation(on: newBlock.id)
    }

    fileprivate func sendInsertActionToFirstResponder(_ text: String) -> Bool {
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
