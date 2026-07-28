import XCTest
@testable import Romeo

final class ElevenLabsTTSClientTests: XCTestCase {
    func testBuildsFlashWebSocketURLFromContract() throws {
        let client = ElevenLabsTTSClient()

        let url = try client.websocketURL(voiceID: "voice_123")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(components.path, "/v1/text-to-speech/voice_123/stream-input")

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(queryItems["model_id"], "eleven_flash_v2_5")
        XCTAssertEqual(queryItems["output_format"], "mp3_44100_128")
        XCTAssertEqual(queryItems["auto_mode"], "true")
    }

    func testRejectsMissingVoiceID() {
        let client = ElevenLabsTTSClient()

        XCTAssertThrowsError(try client.websocketURL(voiceID: "   ")) { error in
            XCTAssertEqual(error as? ElevenLabsTTSError, .missingVoiceID)
        }
    }

    func testPlaybackQueueFlushHonorsCancellation() async {
        let queue = SpeechPlaybackQueue(speaker: SlowSpeaker())
        await queue.configure(apiKey: "test", voiceID: "voice")
        await queue.enqueue("Hello")

        let flushTask = Task {
            try await queue.flush()
        }
        flushTask.cancel()

        do {
            try await flushTask.value
            XCTFail("Expected flush to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await queue.stop()
    }
}

private struct SlowSpeaker: TextToSpeechSpeaking {
    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data {
        try await Task.sleep(for: .seconds(5))
        return Data(text.utf8)
    }

    func play(_ audio: Data) async throws {}
    func stop() async {}
}
