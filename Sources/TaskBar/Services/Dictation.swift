@preconcurrency import AVFoundation
import Foundation
import Speech

/// What the recogniser has heard so far.
struct DictationTranscript: Equatable, Sendable {
    /// Text the recogniser will no longer change.
    var finalized: String
    /// The tail still being refined as more audio arrives.
    var volatile: String

    var text: String { finalized + volatile }
}

enum DictationError: LocalizedError, Equatable {
    case needsBundledApp
    case microphoneDenied
    case speechRecognitionDenied
    case unsupportedLanguage(String)
    case noMicrophone
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .needsBundledApp:
            "Voice input needs the bundled TaskBar.app (build it with `make app`)."
        case .microphoneDenied:
            "Microphone access is off. Allow TaskBar in System Settings > Privacy & Security > Microphone."
        case .speechRecognitionDenied:
            "Speech recognition is off. Allow TaskBar in System Settings > Privacy & Security > Speech Recognition."
        case .unsupportedLanguage(let language):
            "On-device dictation does not support \(language) yet. Pick another language with the language button next to the microphone."
        case .noMicrophone:
            "No microphone was found."
        case .engineFailure(let reason):
            reason
        }
    }
}

/// A speech-to-text backend. Both implementations run entirely on-device.
@MainActor
protocol DictationEngine: AnyObject {
    /// Starts listening. `onUpdate` receives the growing transcript and `onFinish` is called
    /// once, with an error description when recognition ended abnormally.
    func start(
        locale: Locale,
        onStatus: @escaping @MainActor (String) -> Void,
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onFinish: @escaping @MainActor (String?) -> Void
    ) async throws

    /// Stops listening and waits for the last words to be transcribed.
    func stop() async
}

@MainActor
enum Dictation {
    /// The best engine for this system: the macOS 26 analyzer, or the classic recogniser.
    static func makeEngine() -> any DictationEngine {
        if #available(macOS 26.0, *) {
            return AnalyzerDictationEngine()
        }
        return LegacyDictationEngine()
    }

    /// Languages offered in Settings, as BCP 47 identifiers.
    static let commonLocaleIdentifiers = [
        "en-US", "en-GB", "pt-BR", "pt-PT", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "ja-JP", "ko-KR", "zh-CN"
    ]

    /// A language's name in the current locale, such as "Portuguese (Brazil)".
    static func label(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Languages the on-device recogniser accepts, as BCP 47 identifiers.
    /// Read once: the list does not change while the app runs, and views read it while drawing.
    static let supportedLocaleIdentifiers: [String] = SFSpeechRecognizer.supportedLocales()
        .map { $0.identifier(.bcp47) }
        .sorted()
}

/// Privacy prompts. Kept off the main actor because the system calls back on arbitrary threads.
enum DictationPermissions {
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}

// MARK: - Audio capture

/// Taps the default microphone. Not actor-isolated: the tap block runs on a real-time audio
/// thread and must never be tied to the main actor.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    /// Starts capturing. `onBuffer` is called on the audio thread.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noMicrophone }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.engineFailure("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}

/// Converts captured audio to the format a recogniser expects.
final class AudioBufferConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        // The converter pulls input through a callback; hand it this one buffer exactly once.
        let source = SingleBufferSource(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = source.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private final class SingleBufferSource: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

// MARK: - macOS 26 engine

/// Dictation built on `SpeechAnalyzer`, the on-device model introduced in macOS 26. It handles
/// long-form speech and downloads its language model through the system on first use.
@available(macOS 26.0, *)
@MainActor
final class AnalyzerDictationEngine: DictationEngine {
    private let capture = MicrophoneCapture()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    func start(
        locale: Locale,
        onStatus: @escaping @MainActor (String) -> Void,
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onFinish: @escaping @MainActor (String?) -> Void
    ) async throws {
        let pipeline = try await AnalyzerPipeline.prepare(locale: locale, onStatus: onStatus)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let converter = AudioBufferConverter(outputFormat: pipeline.format)

        try capture.start { buffer in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        do {
            try await pipeline.analyzer.start(inputSequence: stream)
        } catch {
            capture.stop()
            continuation.finish()
            throw DictationError.engineFailure(error.localizedDescription)
        }

        analyzer = pipeline.analyzer
        input = continuation
        resultsTask = Task {
            let failure = await AnalyzerPipeline.collect(from: pipeline.transcriber, onUpdate: onUpdate)
            onFinish(failure)
        }
    }

    func stop() async {
        capture.stop()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        // The results sequence ends once the analyzer has flushed its last words.
        await resultsTask?.value
        resultsTask = nil
    }
}

/// The parts of the analyzer flow that do not depend on where the audio comes from, shared by
/// live dictation and the file-based self-test.
@available(macOS 26.0, *)
enum AnalyzerPipeline {
    struct Prepared {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }

    /// Builds a transcriber for `locale`, installing its language model when missing.
    static func prepare(
        locale: Locale,
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> Prepared {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.unsupportedLanguage(locale.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                await onStatus("Downloading the speech model…")
                try await request.downloadAndInstall()
            }
        } catch {
            throw DictationError.engineFailure("Could not prepare the speech model: \(error.localizedDescription)")
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.engineFailure("The speech model is not ready yet. Try again in a moment.")
        }
        return Prepared(transcriber: transcriber, analyzer: SpeechAnalyzer(modules: [transcriber]), format: format)
    }

    /// Streams results until the analyzer finishes. Returns an error description on failure.
    static func collect(
        from transcriber: SpeechTranscriber,
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void
    ) async -> String? {
        var finalized = ""
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    await onUpdate(DictationTranscript(finalized: finalized, volatile: ""))
                } else {
                    await onUpdate(DictationTranscript(finalized: finalized, volatile: text))
                }
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Transcribes an audio file with the same pipeline used for live dictation.
    static func transcribe(fileAt url: URL, locale: Locale) async throws -> String {
        let pipeline = try await prepare(locale: locale) { _ in }
        let file = try AVAudioFile(forReading: url)
        let converter = AudioBufferConverter(outputFormat: pipeline.format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task { @MainActor in
            let box = TranscriptBox()
            let failure = await collect(from: pipeline.transcriber) { box.transcript = $0 }
            return (box.transcript.text, failure)
        }

        try await pipeline.analyzer.start(inputSequence: stream)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        continuation.finish()
        try await pipeline.analyzer.finalizeAndFinishThroughEndOfInput()

        let (text, failure) = await collector.value
        if let failure { throw DictationError.engineFailure(failure) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private final class TranscriptBox {
        var transcript = DictationTranscript(finalized: "", volatile: "")
    }
}

// MARK: - Classic engine (macOS 14 and 15)

/// Dictation built on `SFSpeechRecognizer`, for systems older than macOS 26.
@MainActor
final class LegacyDictationEngine: DictationEngine {
    private let capture = MicrophoneCapture()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var hasFinished = false

    func start(
        locale: Locale,
        onStatus: @escaping @MainActor (String) -> Void,
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onFinish: @escaping @MainActor (String?) -> Void
    ) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationError.unsupportedLanguage(locale.identifier(.bcp47))
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Keep audio on the Mac whenever the language has a local model.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        hasFinished = false

        let sink = RequestSink(request)
        try capture.start { buffer in
            sink.append(buffer)
        }

        let handler = Self.makeResultHandler(onUpdate: onUpdate) { [weak self] failure in
            guard let self, !self.hasFinished else { return }
            self.hasFinished = true
            self.finishContinuation?.resume()
            self.finishContinuation = nil
            onFinish(failure)
        }
        task = recognizer.recognitionTask(with: request, resultHandler: handler)
    }

    func stop() async {
        capture.stop()
        request?.endAudio()
        if !hasFinished {
            // Give the recogniser a moment to deliver its final result.
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let pending = self.finishContinuation else { return }
                    self.finishContinuation = nil
                    self.hasFinished = true
                    pending.resume()
                }
            }
        }
        task?.cancel()
        task = nil
        request = nil
    }

    /// Built outside the main actor: Speech invokes the handler on a background queue.
    private nonisolated static func makeResultHandler(
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onFinish: @escaping @MainActor (String?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let text {
                    onUpdate(DictationTranscript(finalized: isFinal ? text : "", volatile: isFinal ? "" : text))
                }
                if isFinal {
                    onFinish(nil)
                } else if let failure {
                    // Ending the audio surfaces as an error on some systems; the text is kept.
                    onFinish(text == nil ? failure : nil)
                }
            }
        }
    }

    private final class RequestSink: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            request.append(buffer)
        }
    }
}
