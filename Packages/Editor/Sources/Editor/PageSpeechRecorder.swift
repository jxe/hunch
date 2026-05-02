import AVFoundation
import Foundation
import Speech

@MainActor
@Observable
public final class PageSpeechRecorder {
    public enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    public internal(set) var state: State = .idle

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    public init() {}

    public var isBusy: Bool {
        state != .idle
    }

    func start() async throws {
        guard state == .idle else { return }
        try await requestPermissions()

        // iOS requires explicit audio session setup; without this `record()` returns
        // false intermittently when another process holds the session.
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            NSLog("[PageSpeechRecorder] audio session activation failed: %@", String(describing: error))
            throw PageSpeechRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunch-dictation-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            NSLog("[PageSpeechRecorder] AVAudioRecorder init failed: %@", String(describing: error))
            throw PageSpeechRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        guard recorder.prepareToRecord() else {
            NSLog("[PageSpeechRecorder] prepareToRecord returned false for %@", url.path)
            throw PageSpeechRecorderError.recordingFailed(underlying: "prepareToRecord failed")
        }
        guard recorder.record() else {
            NSLog("[PageSpeechRecorder] record() returned false; session category=%@", currentSessionCategoryDescription())
            throw PageSpeechRecorderError.recordingFailed(underlying: "record() returned false")
        }

        self.recorder = recorder
        recordingURL = url
        state = .recording
    }

    func stopAndTranscribe() async throws -> String {
        guard state == .recording, let url = recordingURL else { return "" }
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        state = .transcribing
        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            state = .idle
        }

        return try await transcribeAudio(at: url)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        state = .idle
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[PageSpeechRecorder] audio session deactivation failed: %@", String(describing: error))
        }
        #endif
    }

    private func currentSessionCategoryDescription() -> String {
        #if os(iOS)
        return AVAudioSession.sharedInstance().category.rawValue
        #else
        return "n/a"
        #endif
    }

    private func requestPermissions() async throws {
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else {
            throw PageSpeechRecorderError.microphonePermissionDenied
        }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw PageSpeechRecorderError.speechPermissionDenied
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func transcribeAudio(at url: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw PageSpeechRecorderError.transcriptionUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .autoupdatingCurrent) else {
            throw PageSpeechRecorderError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)

        let audioFile = try AVAudioFile(forReading: url)
        let resultTask = Task {
            var chunks: [String] = []
            for try await result in transcriber.results {
                if result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        chunks.append(text)
                    }
                }
            }
            return chunks.joined(separator: " ")
        }

        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            try await request.downloadAndInstall()
        case .unsupported:
            throw PageSpeechRecorderError.transcriptionUnavailable
        @unknown default:
            throw PageSpeechRecorderError.transcriptionUnavailable
        }
    }
}

enum PageSpeechRecorderError: LocalizedError {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recordingFailed(underlying: String?)
    case transcriptionUnavailable
    case unsupportedLocale

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required to record audio."
        case .speechPermissionDenied:
            "Speech recognition permission is required to transcribe audio."
        case .recordingFailed(let underlying):
            if let underlying, !underlying.isEmpty {
                "Recording could not be started: \(underlying)"
            } else {
                "Recording could not be started."
            }
        case .transcriptionUnavailable:
            "Speech transcription is not available on this device."
        case .unsupportedLocale:
            "Speech transcription is not available for your current language."
        }
    }
}
