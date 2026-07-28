@preconcurrency import AVFoundation
import Foundation

final class ElevenLabsScribeTranscriber: Transcriber, @unchecked Sendable {
    private let configuration: ElevenLabsScribeConfiguration
    private let duckingLevel: RomeoDuckingLevel
    private let session: URLSession
    private let engine = AVAudioEngine()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lifecycleLock = NSLock()

    private var didStop = false
    private var tapInstalled = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<Data>.Continuation?

    init(
        apiKey: String,
        keyterms: [String] = ElevenLabsScribeConfiguration.defaultKeyterms,
        duckingLevel: RomeoDuckingLevel = .max,
        session: URLSession = .shared
    ) {
        configuration = ElevenLabsScribeConfiguration(apiKey: apiKey, keyterms: keyterms)
        self.duckingLevel = duckingLevel
        self.session = session
    }

    func start() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let startTask = Task {
                do {
                    try await startStreaming(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                    await stop()
                }
            }

            continuation.onTermination = { _ in
                startTask.cancel()
                Task {
                    await self.stop()
                }
            }
        }
    }

    func stop() async {
        let shouldFinishCleanup = lifecycleLock.withLock {
            guard !didStop else {
                return false
            }

            didStop = true
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            return true
        }
        guard shouldFinishCleanup else {
            return
        }

        receiveTask?.cancel()
        receiveTask = nil

        audioContinuation?.finish()
        audioContinuation = nil
        sendTask?.cancel()
        sendTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func startStreaming(
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        guard !configuration.trimmedAPIKey.isEmpty else {
            throw ElevenLabsTTSError.missingAPIKey
        }

        try await RomeoAudioSession.ensureRecordPermission()
        try RomeoAudioSession.configureForListening()

        var request = try configuration.request()
        request.timeoutInterval = 15

        let inputNode = engine.inputNode
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: duckingLevel.avAudioLevel
            )
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw ElevenLabsScribeError.audioFormatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ElevenLabsScribeError.audioFormatUnavailable
        }

        try lifecycleLock.withLock {
            guard !didStop else {
                throw CancellationError()
            }

            let task = session.webSocketTask(with: request)
            webSocketTask = task
            task.resume()

            receiveTask = Task {
                await receiveMessages(from: task, continuation: continuation)
            }

            let audioStream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(12)) { [weak self] streamContinuation in
                self?.audioContinuation = streamContinuation
            }
            sendTask = Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    for await audioData in audioStream {
                        try Task.checkCancellation()
                        try await self.sendAudioChunk(audioData)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, _ in
                guard let self,
                      let audioData = Self.pcm16MonoData(
                        from: buffer,
                        inputFormat: inputFormat,
                        outputFormat: outputFormat,
                        converter: converter
                      ),
                      !audioData.isEmpty
                else {
                    return
                }

                self.audioContinuation?.yield(audioData)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
        }
        continuation.yield(.started)
    }

    private func sendAudioChunk(_ audioData: Data) async throws {
        guard let webSocketTask else {
            throw ElevenLabsScribeError.notConnected
        }

        let message = ElevenLabsScribeInputAudioChunk(
            audioBase64: audioData.base64EncodedString(),
            sampleRate: 16_000
        )
        let data = try encoder.encode(message)
        try await webSocketTask.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveMessages(
        from task: URLSessionWebSocketTask,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let receivedData):
                    data = receivedData
                case .string(let string):
                    data = Data(string.utf8)
                @unknown default:
                    continue
                }

                if let update = try Self.transcriptionUpdate(from: data, decoder: decoder) {
                    continuation.yield(update)
                }
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    static func transcriptionUpdate(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> TranscriptionUpdate? {
        let event = try decoder.decode(ElevenLabsScribeEvent.self, from: data)
        switch event.messageType {
        case "session_started":
            return nil
        case "partial_transcript":
            return TranscriptionUpdate(text: event.text ?? "", isFinal: false)
        case "committed_transcript", "committed_transcript_with_timestamps":
            return TranscriptionUpdate(text: event.text ?? "", isFinal: true)
        case "error",
             "scribe_error",
             "scribe_auth_error",
             "scribe_quota_exceeded_error",
             "scribe_throttled_error",
             "scribe_unaccepted_terms_error",
             "scribe_rate_limited_error",
             "scribe_queue_overflow_error",
             "scribe_resource_exhausted_error",
             "scribe_session_time_limit_exceeded_error",
             "scribe_input_error",
             "scribe_chunk_size_exceeded_error",
             "scribe_insufficient_audio_activity_error",
             "scribe_transcriber_error",
             "auth_error",
             "quota_exceeded",
             "throttled",
             "unaccepted_terms",
             "rate_limited":
            throw ElevenLabsScribeError.providerError(event.errorMessage)
        default:
            return nil
        }
    }

    private static func pcm16MonoData(
        from inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Data? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = max(
            AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 512,
            1024
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else {
            return nil
        }

        let inputProvider = AudioConverterInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            inputProvider.nextBuffer(status: status)
        }

        guard conversionError == nil else {
            return nil
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else {
            return nil
        }

        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }
}

struct ElevenLabsScribeConfiguration: Equatable {
    // Keyterms bias the on-device/cloud transcriber toward words it would
    // otherwise mis-hear. Seed this with YOUR own vocabulary: your agent's name,
    // collaborators' names, project codenames, and any jargon you use often.
    // The entries below are just generic examples for this template.
    static let defaultKeyterms = [
        "Romeo",
        "Tailscale",
        "Mac Mini",
        "Agent One",
        "Agent Two",
        "Full Romeo",
        "Live Romeo",
        "Scribe",
        "ElevenLabs",
        "OpenAI"
    ]

    let apiKey: String
    let keyterms: [String]
    let modelID = "scribe_v2_realtime"
    let audioFormat = "pcm_16000"
    let commitStrategy = "vad"
    let languageCode = "en"

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/speech-to-text/realtime"
        components.queryItems = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: audioFormat),
            URLQueryItem(name: "commit_strategy", value: commitStrategy),
            URLQueryItem(name: "language_code", value: languageCode),
            URLQueryItem(name: "include_timestamps", value: "false"),
            URLQueryItem(name: "include_language_detection", value: "false"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.0"),
            URLQueryItem(name: "vad_threshold", value: "0.4"),
            URLQueryItem(name: "min_speech_duration_ms", value: "100"),
            URLQueryItem(name: "min_silence_duration_ms", value: "100")
        ] + sanitizedKeyterms.map {
            URLQueryItem(name: "keyterms", value: $0)
        }

        guard let url = components.url else {
            throw ElevenLabsTTSError.invalidURL
        }

        return url
    }

    func request() throws -> URLRequest {
        var request = URLRequest(url: try url())
        request.setValue(trimmedAPIKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private var sanitizedKeyterms: [String] {
        var seen = Set<String>()
        return keyterms.compactMap { keyterm in
            let trimmed = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 20 else {
                return nil
            }

            let normalized = trimmed.lowercased()
            guard !seen.contains(normalized) else {
                return nil
            }

            seen.insert(normalized)
            return trimmed
        }
        .prefix(50)
        .map { $0 }
    }
}

struct ElevenLabsScribeKeyValidator: Sendable {
    var session: URLSession = .shared

    func validate(apiKey: String) async throws {
        let configuration = ElevenLabsScribeConfiguration(apiKey: apiKey, keyterms: [])
        guard !configuration.trimmedAPIKey.isEmpty else {
            throw ElevenLabsTTSError.missingAPIKey
        }

        var request = try configuration.request()
        request.timeoutInterval = 10

        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let receivedData):
                    data = receivedData
                case .string(let string):
                    data = Data(string.utf8)
                @unknown default:
                    throw ElevenLabsScribeError.invalidProviderMessage
                }

                let event = try JSONDecoder().decode(ElevenLabsScribeEvent.self, from: data)
                if event.messageType != "session_started" {
                    throw ElevenLabsScribeError.providerError(event.errorMessage)
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw ElevenLabsScribeError.validationTimedOut
            }

            try await group.next()
            group.cancelAll()
        }
    }
}

enum ElevenLabsScribeError: LocalizedError, Equatable {
    case audioFormatUnavailable
    case invalidProviderMessage
    case notConnected
    case providerError(String)
    case validationTimedOut

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            "The iPhone could not prepare microphone audio for ElevenLabs Scribe."
        case .invalidProviderMessage:
            "ElevenLabs Scribe returned a message Romeo could not read."
        case .notConnected:
            "Romeo is not connected to ElevenLabs Scribe."
        case .providerError(let message):
            "ElevenLabs Scribe failed: \(message)"
        case .validationTimedOut:
            "ElevenLabs Scribe did not confirm the key in time."
        }
    }
}

private struct ElevenLabsScribeInputAudioChunk: Encodable {
    let messageType = "input_audio_chunk"
    let audioBase64: String
    let sampleRate: Int

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case audioBase64 = "audio_base_64"
        case sampleRate = "sample_rate"
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            status.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}

private struct ElevenLabsScribeEvent: Decodable {
    let messageType: String
    let text: String?
    let message: String?
    let error: String?
    let detail: String?

    var errorMessage: String {
        error ?? message ?? detail ?? "Unknown provider error"
    }

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
        case message
        case error
        case detail
    }
}
