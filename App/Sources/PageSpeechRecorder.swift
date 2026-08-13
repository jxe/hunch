import AVFoundation
import Foundation
import Speech

struct PendingVoiceRecording: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let pageID: String
    let createdAt: Date
}

struct PendingVoiceRecordingStore: Sendable {
    let directoryURL: URL

    static var live: Self {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return Self(directoryURL: root.appendingPathComponent("Pending Voice Recordings", isDirectory: true))
    }

    func begin(pageID: String, now: Date = Date()) throws -> PendingVoiceRecording {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let recording = PendingVoiceRecording(id: UUID(), pageID: pageID, createdAt: now)
        let data = try JSONEncoder().encode(recording)
        try data.write(to: metadataURL(for: recording), options: .atomic)
        return recording
    }

    func audioURL(for recording: PendingVoiceRecording) -> URL {
        directoryURL.appendingPathComponent(recording.id.uuidString).appendingPathExtension("caf")
    }

    func pendingRecordings() throws -> [PendingVoiceRecording] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let recording = try? JSONDecoder().decode(PendingVoiceRecording.self, from: data),
                  FileManager.default.fileExists(atPath: audioURL(for: recording).path) else {
                return nil
            }
            return recording
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ recording: PendingVoiceRecording) throws {
        let fileManager = FileManager.default
        let urls = [audioURL(for: recording), metadataURL(for: recording)]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func metadataURL(for recording: PendingVoiceRecording) -> URL {
        directoryURL.appendingPathComponent(recording.id.uuidString).appendingPathExtension("json")
    }
}

@MainActor
@Observable
final class PageSpeechRecorder {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var healthMonitor: Task<Void, Never>?
    private var activeAnalyzer: SpeechAnalyzer?
    private var activeResultTask: Task<String, Error>?
    private var transcriptionWasCancelled = false
    var unexpectedStopHandler: ((String) -> Void)?

    init() {}

    func start(recordingAt url: URL) async throws {
        guard state == .idle else { return }
        try await requestPermissions()

        // iOS requires explicit audio session setup; without this `record()` returns
        // false intermittently when another process holds the session.
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            Diag.speech.error("audio session activation failed: \(String(describing: error), privacy: .public)")
            throw PageSpeechRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        #endif

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
            Diag.speech.error("AVAudioRecorder init failed: \(String(describing: error), privacy: .public)")
            throw PageSpeechRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        guard recorder.prepareToRecord() else {
            Diag.speech.error("prepareToRecord returned false for \(url.path, privacy: .public)")
            throw PageSpeechRecorderError.recordingFailed(underlying: "prepareToRecord failed")
        }
        guard recorder.record() else {
            Diag.speech.error("record() returned false; session category=\(self.currentSessionCategoryDescription(), privacy: .public)")
            throw PageSpeechRecorderError.recordingFailed(underlying: "record() returned false")
        }

        self.recorder = recorder
        recordingURL = url
        state = .recording
        startHealthMonitor(for: recorder)
        Diag.speech.log("recording started file=\(url.lastPathComponent, privacy: .public)")
    }

    func stopAndTranscribe() async throws -> String {
        guard state == .recording, let url = recordingURL else { return "" }
        healthMonitor?.cancel()
        healthMonitor = nil
        state = .transcribing
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        transcriptionWasCancelled = false
        defer {
            recordingURL = nil
            state = .idle
        }

        return try await transcribeAudio(at: url)
    }

    func transcribeSavedRecording(at url: URL) async throws -> String {
        guard state == .idle else { return "" }
        state = .transcribing
        transcriptionWasCancelled = false
        defer { state = .idle }
        return try await transcribeAudio(at: url)
    }

    func cancel(discardingAudio: Bool = true) {
        healthMonitor?.cancel()
        healthMonitor = nil
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        if discardingAudio, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        cancelTranscription()
        recordingURL = nil
        state = .idle
    }

    func cancelTranscription() {
        guard state == .transcribing else { return }
        transcriptionWasCancelled = true
        activeResultTask?.cancel()
        if let activeAnalyzer {
            Task { await activeAnalyzer.cancelAndFinishNow() }
        }
        state = .idle
    }

    private func startHealthMonitor(for recorder: AVAudioRecorder) {
        healthMonitor?.cancel()
        healthMonitor = Task { @MainActor [weak self, weak recorder] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.state == .recording else { return }
                guard recorder?.isRecording == true else {
                    self.handleUnexpectedStop()
                    return
                }
            }
        }
    }

    private func handleUnexpectedStop() {
        healthMonitor?.cancel()
        healthMonitor = nil
        recorder = nil
        deactivateAudioSession()
        recordingURL = nil
        state = .idle
        Diag.speech.error("AVAudioRecorder stopped unexpectedly")
        unexpectedStopHandler?(
            "Recording stopped unexpectedly. Any audio captured before it stopped was preserved."
        )
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Diag.speech.error("audio session deactivation failed: \(String(describing: error), privacy: .public)")
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
        try checkForTranscriptionCancellation()
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            Diag.speech.error("refusing to transcribe empty audio file=\(url.lastPathComponent, privacy: .public)")
            throw PageSpeechRecorderError.noAudioCaptured
        }
        guard SpeechTranscriber.isAvailable else {
            throw PageSpeechRecorderError.transcriptionUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .autoupdatingCurrent) else {
            throw PageSpeechRecorderError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)
        try checkForTranscriptionCancellation()

        Diag.speech.log("transcription analysis started file=\(url.lastPathComponent, privacy: .public) frames=\(audioFile.length, privacy: .public)")
        let resultTask = Task<String, Error> {
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

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        activeAnalyzer = analyzer
        activeResultTask = resultTask
        defer {
            activeAnalyzer = nil
            activeResultTask = nil
        }

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                await analyzer.cancelAndFinishNow()
                throw PageSpeechRecorderError.noAudioCaptured
            }
            try checkForTranscriptionCancellation()
            try await analyzer.finalizeAndFinish(through: lastSample)
            let transcript = try await resultTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw PageSpeechRecorderError.noTranscribableSpeech
            }
            Diag.speech.log("transcription analysis finished file=\(url.lastPathComponent, privacy: .public) characters=\(transcript.count, privacy: .public)")
            return transcript
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func checkForTranscriptionCancellation() throws {
        if transcriptionWasCancelled {
            throw CancellationError()
        }
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
    case noAudioCaptured
    case noTranscribableSpeech
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
        case .noAudioCaptured:
            "No audio was captured. The recording stopped before Hunch received any microphone samples."
        case .noTranscribableSpeech:
            "No speech could be transcribed from the recording."
        case .transcriptionUnavailable:
            "Speech transcription is not available on this device."
        case .unsupportedLocale:
            "Speech transcription is not available for your current language."
        }
    }
}
