import AVFoundation
import Foundation
import Speech

struct TranscriptResult {
    let fullText: String
    let partials: [String]
    let confidence: Double
}

protocol SpeechToTextService {
    func setPartialHandler(_ handler: (@Sendable (String) -> Void)?)
    func start()
    func stop() async throws -> TranscriptResult
    func cancel()
}

enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case noInputNode
    case emptyTranscript
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is not authorized."
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable."
        case .noInputNode:
            return "No input audio node available."
        case .emptyTranscript:
            return "No speech was detected."
        case let .startFailed(message):
            return "Failed to start speech recognition: \(message)"
        }
    }
}

final class AppleSpeechRecognizer: NSObject, SpeechToTextService {
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var partialHandler: (@Sendable (String) -> Void)?
    private var latestConfidence = 0.0

    private var latestTranscript = ""
    private var partials: [String] = []
    private var startedAt: Date?
    private var startError: Error?

    func setPartialHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock {
            partialHandler = handler
        }
    }

    func start() {
        startedAt = Date()
        resetStateForStart()
        requestSpeechAuthorizationAndStart()
    }

    func stop() async throws -> TranscriptResult {
        if let startError {
            throw startError
        }

        shutdownRecognition()

        // Allow the recognition task to flush final tokens.
        try? await Task.sleep(nanoseconds: 250_000_000)
        recognitionTask?.cancel()

        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        Logger.info("STT stopped after \(elapsed)s")

        let snapshot = lock.withLock { (latestTranscript, partials, latestConfidence) }
        let text = snapshot.0.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw SpeechRecognitionError.emptyTranscript
        }
        return TranscriptResult(
            fullText: text,
            partials: snapshot.1,
            confidence: snapshot.2
        )
    }

    func cancel() {
        shutdownRecognition()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func requestSpeechAuthorizationAndStart() {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            startRecognition()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] auth in
                guard let self else { return }
                if auth == .authorized {
                    self.startRecognition()
                } else {
                    self.startError = SpeechRecognitionError.notAuthorized
                }
            }
        case .denied, .restricted:
            startError = SpeechRecognitionError.notAuthorized
        @unknown default:
            startError = SpeechRecognitionError.notAuthorized
        }
    }

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            startError = SpeechRecognitionError.recognizerUnavailable
            return
        }
        guard audioEngine.inputNode.numberOfInputs > 0 else {
            startError = SpeechRecognitionError.noInputNode
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            startError = SpeechRecognitionError.startFailed(error.localizedDescription)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.withLock {
                    self.latestConfidence = Self.transcriptionConfidence(from: result)
                    self.latestTranscript = text
                    if self.partials.last != text {
                        self.partials.append(text)
                    }
                    self.partialHandler?(text)
                }
            }

            if error != nil {
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        }
    }

    private func resetStateForStart() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        lock.withLock {
            latestTranscript = ""
            partials = []
            startError = nil
            latestConfidence = 0.0
        }
    }

    private func shutdownRecognition() {
        audioEngine.stop()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
    }

    private static func transcriptionConfidence(from result: SFSpeechRecognitionResult) -> Double {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else {
            return 0.0
        }
        let total = segments.reduce(0.0) { accumulator, segment in
            accumulator + Double(segment.confidence)
        }
        return min(1.0, max(0.0, total / Double(segments.count)))
    }
}

final class WhisperAPIClient {
    func transcribe(audioData: Data) async throws -> String {
        _ = audioData
        return ""
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
