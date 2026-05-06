import SwiftUI

// MARK: - Voice recording / speech-to-text
//
// `EditorState` owns the `PageSpeechRecorder` instance and a
// `voiceRecordingToggleTicket`. The host renders `EditorRecordingButton` in
// its toolbar; tapping it bumps the ticket. The Siri/intent bridge bumps the
// same ticket. The editor watches the ticket and runs the actual flow:
// idle → start; recording → stop, transcribe, insert at the active focus.

extension EditorView {
    func handleVoiceRecordingToggle() async {
        do {
            switch state.speechRecorder.state {
            case .idle:
                try await state.speechRecorder.start()
            case .recording:
                let transcript = try await state.speechRecorder.stopAndTranscribe()
                insertTranscript(transcript)
            case .transcribing:
                break
            }
        } catch {
            state.speechRecorder.cancel()
            speechError = error.localizedDescription
        }
    }

    var speechErrorBinding: Binding<Bool> {
        Binding(
            get: { speechError != nil },
            set: { newValue in if !newValue { speechError = nil } }
        )
    }

    fileprivate func insertTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if state.editingBlock != nil,
           sendInsertActionToFirstResponder(trimmed) {
            transferFocus(to: .nav(cursor: state.editingBlock))
            return
        }

        let newBlock = Block.paragraph(text: AttributedString(trimmed))
        mutate("Insert Transcript") {
            document.children.append(newBlock)
        }
        transferFocus(to: .nav(cursor: newBlock.id))
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

// MARK: - Public toolbar button

/// The mic / stop / progress button the host places in its own toolbar. Reads
/// recording state from `EditorState.speechRecorder`; tapping bumps
/// `voiceRecordingToggleTicket`, which the editor observes to run the flow.
public struct EditorRecordingButton: View {
    @Bindable var state: EditorState

    public init(state: EditorState) {
        self.state = state
    }

    public var body: some View {
        Button {
            state.requestToggleVoiceRecording()
        } label: {
            switch state.speechRecorder.state {
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
        .disabled(state.speechRecorder.state == .transcribing)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state.speechRecorder.state {
        case .idle:         return "Record Audio"
        case .recording:    return "Stop Recording"
        case .transcribing: return "Transcribing"
        }
    }
}
