import SwiftUI
import Editor
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Mic / stop / progress button shown in the page toolbar. Owns the recorder
/// state machine; on stop, transcribes and either inserts the text at the
/// focused text view (responder chain) or appends a paragraph via
/// `EditorState.appendBlocks`. Also bridges Siri intents — the
/// `VoiceRecordingLaunchRequest` notification fires the same toggle path.
struct RecordingButton: View {
    let editorState: EditorState
    @State private var recorder = PageSpeechRecorder()
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            switch recorder.state {
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
        .disabled(recorder.state == .transcribing)
        .help(label)
        .accessibilityLabel(label)
        .alert("Recording", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { forwardPending() }
        .onChange(of: scenePhase) { _, new in
            if new == .active { forwardPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceRecordingLaunchRequest.notificationName)) { _ in
            // The intent fires from another process and writes the pending-start
            // flag before posting the notification — consume the flag too so a
            // later `.active` transition doesn't fire a second time.
            _ = VoiceRecordingLaunchRequest.consumePendingStart()
            // Defer off the publisher's synchronous delivery — if it posts during
            // a SwiftUI render pass an inline state mutation trips
            // "Modifying state during view update".
            Task { @MainActor in await toggle() }
        }
    }

    @MainActor private func toggle() async {
        do {
            switch recorder.state {
            case .idle:
                try await recorder.start()
            case .recording:
                let transcript = try await recorder.stopAndTranscribe()
                insertTranscript(transcript)
            case .transcribing:
                break
            }
        } catch {
            recorder.cancel()
            errorMessage = error.localizedDescription
        }
    }

    private func insertTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if editorState.editingBlock != nil,
           sendInsertActionToFirstResponder(trimmed) {
            return
        }

        editorState.appendBlocks(
            [Block.paragraph(text: AttributedString(trimmed))],
            actionName: "Insert Transcript"
        )
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

    private func forwardPending() {
        guard VoiceRecordingLaunchRequest.consumePendingStart() else { return }
        Task { @MainActor in await toggle() }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in if !newValue { errorMessage = nil } }
        )
    }

    private var label: String {
        switch recorder.state {
        case .idle:         return "Record Audio"
        case .recording:    return "Stop Recording"
        case .transcribing: return "Transcribing"
        }
    }
}
