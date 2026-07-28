import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC

@MainActor
protocol LiveRealtimeSessioning: AnyObject, Sendable {
    func start(apiKey: String, duckingLevel: RomeoDuckingLevel) -> AsyncStream<LiveRealtimeEvent>
    func stop() async
}

@MainActor
final class LiveRealtimeOpenAISession: LiveRealtimeSessioning {
    private var connector: OpenAIRealtimeWebRTCConnector?
    private var sessionTask: Task<Void, Never>?
    private var continuation: AsyncStream<LiveRealtimeEvent>.Continuation?

    func start(apiKey: String, duckingLevel: RomeoDuckingLevel = .max) -> AsyncStream<LiveRealtimeEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            sessionTask = Task {
                await run(apiKey: apiKey, duckingLevel: duckingLevel)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    await self?.stop()
                }
            }
        }
    }

    func stop() async {
        sessionTask?.cancel()
        sessionTask = nil
        connector?.disconnect()
        connector = nil
        continuation?.yield(.ended)
        continuation?.finish()
        continuation = nil
    }

    private func run(apiKey: String, duckingLevel: RomeoDuckingLevel) async {
        do {
            try await RomeoAudioSession.ensureRecordPermission()
            try RomeoAudioSession.configureForListening()

            let connector = try await withTimeout(seconds: 20) {
                let connector = try OpenAIRealtimeWebRTCConnector.make(duckingLevel: duckingLevel)
                try await connector.connect(apiKey: apiKey)
                return connector
            }
            self.connector = connector

            for try await event in connector.events {
                guard !Task.isCancelled else {
                    return
                }

                handle(event)
            }
        } catch is CancellationError {
            continuation?.finish()
        } catch {
            continuation?.yield(.error(Self.diagnosticMessage(for: error)))
            continuation?.finish()
        }
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .connected:
            continuation?.yield(.connected)
        case .userTranscript(let transcript):
            continuation?.yield(.userTranscript(transcript))
        case .assistantTranscript(let transcript):
            continuation?.yield(.assistantTranscript(transcript))
        case .error(let message):
            continuation?.yield(.error(message))
        }
    }

    nonisolated static func makeRealtimeCallsRequest(apiKey: String, localSDP: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "romeo-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(boundary: boundary, localSDP: localSDP)
        return request
    }

    nonisolated static func sessionConfigData() throws -> Data {
        try JSONEncoder().encode(RealtimeSessionConfig())
    }

    nonisolated private static func multipartBody(boundary: String, localSDP: String) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"sdp\"\r\n")
        append("Content-Type: application/sdp\r\n\r\n")
        append(localSDP)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"session\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(try sessionConfigData())
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LiveRealtimeError.connectionTimedOut
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private static func diagnosticMessage(for error: Error) -> String {
        if let liveError = error as? LiveRealtimeError {
            return liveError.localizedDescription
        }

        if let webRTCError = error as? OpenAIRealtimeWebRTCConnector.WebRTCError {
            return webRTCError.localizedDescription
        }

        return error.localizedDescription
    }
}

private enum RealtimeServerEvent: Equatable {
    case connected
    case userTranscript(String)
    case assistantTranscript(String)
    case error(String)
}

private enum RealtimeServerEventDecoder {
    private struct EventEnvelope: Decodable {
        let type: String
        let transcript: String?
        let error: ErrorPayload?
    }

    private struct ErrorPayload: Decodable {
        let message: String?
    }

    static func decode(_ data: Data) throws -> RealtimeServerEvent? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)

        switch envelope.type {
        case "session.created", "session.updated":
            return .connected
        case "conversation.item.input_audio_transcription.completed":
            return envelope.transcript.map(RealtimeServerEvent.userTranscript)
        case "conversation.item.input_audio_transcription.failed", "error":
            return .error(envelope.error?.message ?? "OpenAI realtime returned an error.")
        case "response.output_audio_transcript.done":
            return envelope.transcript.map(RealtimeServerEvent.assistantTranscript)
        default:
            return nil
        }
    }
}

private extension RomeoDuckingLevel {
    var rtcAudioDuckingLevel: LKRTCAudioDuckingLevel {
        switch self {
        case .systemDefault:
            .default
        case .min:
            .min
        case .mid:
            .mid
        case .max:
            .max
        }
    }
}

private struct RealtimeSessionConfig: Encodable {
    struct Audio: Encodable {
        struct Input: Encodable {
            struct Transcription: Encodable {
                let model = "gpt-4o-mini-transcribe"
                let language = "en"
                let prompt = "Expect the closing phrase Romeo over, sometimes spoken as Romeo, over."
            }

            struct TurnDetection: Encodable {
                let type = "server_vad"
                let createResponse = true
                let interruptResponse = true

                enum CodingKeys: String, CodingKey {
                    case type
                    case createResponse = "create_response"
                    case interruptResponse = "interrupt_response"
                }
            }

            let transcription = Transcription()
            let turnDetection = TurnDetection()

            enum CodingKeys: String, CodingKey {
                case transcription
                case turnDetection = "turn_detection"
            }
        }

        struct Output: Encodable {
            let voice = "ash"
        }

        let input = Input()
        let output = Output()
    }

    struct Reasoning: Encodable {
        let effort = "low"
    }

    let type = "realtime"
    let model = "gpt-realtime-2.1"
    // Live Romeo's spoken persona. Edit to match your own agent's name and tone.
    // (The Full Romeo persona lives on your agent / Agent One, not in the app.)
    let instructions = "You are Romeo, a concise spoken assistant for its owner. Keep responses useful, natural, and brief unless the owner asks for detail. Speak in a calm, warm, medium-deep register. Sound conversational, never booming or theatrical."
    let outputModalities = ["audio"]
    let audio = Audio()
    let reasoning = Reasoning()

    enum CodingKeys: String, CodingKey {
        case type
        case model
        case instructions
        case outputModalities = "output_modalities"
        case audio
        case reasoning
    }
}

private final class OpenAIRealtimeWebRTCConnector: NSObject, Sendable {
    enum WebRTCError: LocalizedError {
        case missingAudioPermission
        case failedToCreatePeerConnection
        case failedToCreateDataChannel
        case failedToCreateSDPOffer(Error)
        case failedToSetLocalDescription(Error)
        case failedToSetRemoteDescription(Error)
        case connectionLost
        case badServerResponse(Int, String)
        case unexpectedServerResponse

        var errorDescription: String? {
            switch self {
            case .missingAudioPermission:
                "Romeo does not have microphone permission."
            case .failedToCreatePeerConnection:
                "Could not create the WebRTC peer connection."
            case .failedToCreateDataChannel:
                "Could not create the WebRTC data channel."
            case .failedToCreateSDPOffer(let error):
                "Could not create the WebRTC offer: \(error.localizedDescription)"
            case .failedToSetLocalDescription(let error):
                "Could not set the local WebRTC description: \(error.localizedDescription)"
            case .failedToSetRemoteDescription(let error):
                "Could not set the OpenAI WebRTC answer: \(error.localizedDescription)"
            case .connectionLost:
                "The OpenAI realtime connection ended unexpectedly."
            case .badServerResponse(let status, let body):
                body.isEmpty ? "OpenAI realtime returned HTTP \(status)." : "OpenAI realtime returned HTTP \(status): \(body)"
            case .unexpectedServerResponse:
                "OpenAI realtime returned an unexpected response."
            }
        }
    }

    let events: AsyncThrowingStream<RealtimeServerEvent, Error>

    private let connection: LKRTCPeerConnection
    private let dataChannel: LKRTCDataChannel
    private let stream: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory()
    }()

    static func make(duckingLevel: RomeoDuckingLevel = .max) throws -> OpenAIRealtimeWebRTCConnector {
        Self.factory.audioDeviceModule.isAdvancedDuckingEnabled = false
        Self.factory.audioDeviceModule.duckingLevel = duckingLevel.rtcAudioDuckingLevel

        guard let connection = Self.factory.peerConnection(
            with: LKRTCConfiguration(),
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        ) else {
            throw WebRTCError.failedToCreatePeerConnection
        }

        let audioSource = Self.factory.audioSource(with: LKRTCMediaConstraints(
            mandatoryConstraints: [
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true",
                "googEchoCancellation": "true",
                "googAutoGainControl": "true"
            ],
            optionalConstraints: nil
        ))
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "local_audio")
        connection.add(audioTrack, streamIds: ["local_stream"])

        guard let dataChannel = connection.dataChannel(
            forLabel: "oai-events",
            configuration: LKRTCDataChannelConfiguration()
        ) else {
            throw WebRTCError.failedToCreateDataChannel
        }

        return OpenAIRealtimeWebRTCConnector(connection: connection, dataChannel: dataChannel)
    }

    private init(connection: LKRTCPeerConnection, dataChannel: LKRTCDataChannel) {
        self.connection = connection
        self.dataChannel = dataChannel
        (events, stream) = AsyncThrowingStream.makeStream(of: RealtimeServerEvent.self)

        super.init()

        connection.delegate = self
        dataChannel.delegate = self
    }

    deinit {
        disconnect()
    }

    func connect(apiKey: String) async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw WebRTCError.missingAudioPermission
        }

        let offer = try await createOffer()
        try await setLocalDescription(offer)
        let localSDP = connection.localDescription?.sdp ?? offer.sdp

        let request = try LiveRealtimeOpenAISession.makeRealtimeCallsRequest(
            apiKey: apiKey,
            localSDP: localSDP
        )
        let remoteSDP = try await fetchRemoteSDP(request)
        try await setRemoteDescription(remoteSDP)
    }

    func disconnect() {
        stream.finish()
        connection.close()
    }

    private func createOffer() async throws -> LKRTCSessionDescription {
        do {
            return try await connection.offer(
                for: LKRTCMediaConstraints(
                    mandatoryConstraints: ["levelControl": "true"],
                    optionalConstraints: nil
                )
            )
        } catch {
            throw WebRTCError.failedToCreateSDPOffer(error)
        }
    }

    private func setLocalDescription(_ description: LKRTCSessionDescription) async throws {
        do {
            try await connection.setLocalDescription(description)
        } catch {
            throw WebRTCError.failedToSetLocalDescription(error)
        }
    }

    private func setRemoteDescription(_ remoteSDP: String) async throws {
        do {
            try await connection.setRemoteDescription(
                LKRTCSessionDescription(type: .answer, sdp: remoteSDP)
            )
        } catch {
            throw WebRTCError.failedToSetRemoteDescription(error)
        }
    }

    private func fetchRemoteSDP(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebRTCError.unexpectedServerResponse
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebRTCError.badServerResponse(httpResponse.statusCode, body)
        }

        guard !body.isEmpty else {
            throw WebRTCError.unexpectedServerResponse
        }

        return body
    }
}

extension OpenAIRealtimeWebRTCConnector: LKRTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
    func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}
    func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        AppTimingLogger.liveRomeo.info(
            "ice_state_changed state=\(newState.rawValue, privacy: .public)"
        )

        if newState == .failed || newState == .closed {
            stream.finish(throwing: WebRTCError.connectionLost)
        }
    }
}

extension OpenAIRealtimeWebRTCConnector: LKRTCDataChannelDelegate {
    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        do {
            if let event = try RealtimeServerEventDecoder.decode(buffer.data) {
                stream.yield(event)
            }
        } catch {
            AppTimingLogger.liveRomeo.error(
                "server_event_decode_failed bytes=\(buffer.data.count, privacy: .public)"
            )
            stream.finish(throwing: error)
        }
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        AppTimingLogger.liveRomeo.info(
            "data_channel_state_changed state=\(dataChannel.readyState.rawValue, privacy: .public)"
        )

        if dataChannel.readyState == .closed {
            stream.finish(throwing: WebRTCError.connectionLost)
        }
    }
}
