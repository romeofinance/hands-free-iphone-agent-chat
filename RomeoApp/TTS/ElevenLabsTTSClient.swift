import AVFoundation
import Foundation

protocol TextToSpeechSpeaking: Sendable {
    /// Fetch the spoken audio for `text` (network/synthesis only — no playback),
    /// so a caller can synthesize upcoming clauses while earlier ones still play.
    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data
    /// Play already-synthesized audio. The caller owns the audio-session lifecycle.
    func play(_ audio: Data) async throws
    func stop() async
}

extension TextToSpeechSpeaking {
    /// Convenience: synthesize then play in one call (used by the in-app voice test).
    func speak(text: String, apiKey: String, voiceID: String) async throws {
        let audio = try await synthesize(text: text, apiKey: apiKey, voiceID: voiceID)
        try await play(audio)
    }
}

struct ElevenLabsTTSClient: TextToSpeechSpeaking, @unchecked Sendable {
    var session: URLSession = .shared
    var decoder = JSONDecoder()
    var encoder = JSONEncoder()

    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return Data()
        }

        return try await audioData(text: trimmedText, apiKey: apiKey, voiceID: voiceID)
    }

    func play(_ audio: Data) async throws {
        guard !audio.isEmpty else {
            return
        }

        try await MainActor.run {
            try RomeoAudioSession.configureForPlayback()
        }

        try await AudioPlayer.shared.play(data: audio)
    }

    func stop() async {
        await AudioPlayer.shared.stop()
    }

    func websocketURL(voiceID: String) throws -> URL {
        guard !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsTTSError.missingVoiceID
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)/stream-input"
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "eleven_flash_v2_5"),
            URLQueryItem(name: "output_format", value: "mp3_44100_128")
        ]

        guard let url = components.url else {
            throw ElevenLabsTTSError.invalidURL
        }

        return url
    }

    private func audioData(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let task = session.webSocketTask(with: try websocketURL(voiceID: voiceID))
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        try await task.send(.string(jsonString(
            ElevenLabsTTSMessage(
                text: " ",
                xiAPIKey: apiKey,
                voiceSettings: .init(stability: 0.5, similarityBoost: 0.8, useSpeakerBoost: false),
                generationConfig: .init(chunkLengthSchedule: [50, 120, 160, 290]),
                flush: nil
            )
        )))

        try await task.send(.string(jsonString(
            ElevenLabsTTSMessage(
                text: text,
                xiAPIKey: nil,
                voiceSettings: nil,
                generationConfig: nil,
                flush: true
            )
        )))

        try await task.send(.string(jsonString(
            ElevenLabsTTSMessage(
                text: "",
                xiAPIKey: nil,
                voiceSettings: nil,
                generationConfig: nil,
                flush: nil
            )
        )))

        var audioData = Data()
        while true {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                audioData.append(data)
            case .string(let string):
                let response = try decoder.decode(ElevenLabsTTSResponse.self, from: Data(string.utf8))
                if let error = response.error ?? response.message {
                    throw ElevenLabsTTSError.providerError(error)
                }

                if let audio = response.audio, let chunk = Data(base64Encoded: audio) {
                    audioData.append(chunk)
                }

                if response.isFinal == true {
                    return audioData
                }
            @unknown default:
                break
            }
        }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

enum ElevenLabsTTSError: LocalizedError, Equatable {
    case missingAPIKey
    case missingVoiceID
    case invalidURL
    case emptyAudio
    case playbackStartFailed
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Enter an ElevenLabs API key before testing voice mode."
        case .missingVoiceID:
            "Enter an ElevenLabs voice ID before testing voice mode."
        case .invalidURL:
            "Could not build the ElevenLabs WebSocket URL."
        case .emptyAudio:
            "ElevenLabs returned no audio."
        case .playbackStartFailed:
            "The iPhone could not start audio playback."
        case .providerError(let message):
            "ElevenLabs TTS failed: \(message)"
        }
    }
}

private struct ElevenLabsTTSMessage: Encodable {
    struct VoiceSettings: Encodable {
        let stability: Double
        let similarityBoost: Double
        let useSpeakerBoost: Bool

        enum CodingKeys: String, CodingKey {
            case stability
            case similarityBoost = "similarity_boost"
            case useSpeakerBoost = "use_speaker_boost"
        }
    }

    struct GenerationConfig: Encodable {
        let chunkLengthSchedule: [Int]

        enum CodingKeys: String, CodingKey {
            case chunkLengthSchedule = "chunk_length_schedule"
        }
    }

    let text: String
    let xiAPIKey: String?
    let voiceSettings: VoiceSettings?
    let generationConfig: GenerationConfig?
    let flush: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case xiAPIKey = "xi_api_key"
        case voiceSettings = "voice_settings"
        case generationConfig = "generation_config"
        case flush
    }
}

private struct ElevenLabsTTSResponse: Decodable {
    let audio: String?
    let isFinal: Bool?
    let error: String?
    let message: String?
}

@MainActor
private final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    // Playback never deactivates the audio session itself. The caller owns the
    // session lifecycle (the voice view model deactivates once at turn end), so
    // the duck stays engaged across consecutive clauses instead of fluttering
    // background music back to full and re-ducking between every clause.
    func play(data: Data) async throws {
        guard !data.isEmpty else {
            throw ElevenLabsTTSError.emptyAudio
        }

        try await withCheckedThrowingContinuation { continuation in
            do {
                self.continuation = continuation
                let player = try AVAudioPlayer(data: data)
                self.player = player
                player.delegate = self
                player.prepareToPlay()
                guard player.play() else {
                    self.player = nil
                    continuation.resume(throwing: ElevenLabsTTSError.playbackStartFailed)
                    self.continuation = nil
                    return
                }
            } catch {
                continuation.resume(throwing: error)
                self.continuation = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        continuation?.resume()
        continuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.player = nil
            if let error {
                self.continuation?.resume(throwing: error)
            } else {
                self.continuation?.resume()
            }
            self.continuation = nil
        }
    }
}
