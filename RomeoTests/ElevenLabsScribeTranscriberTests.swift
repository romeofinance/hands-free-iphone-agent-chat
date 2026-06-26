import XCTest
@testable import Romeo

final class ElevenLabsScribeTranscriberTests: XCTestCase {
    func testConfigurationBuildsRealtimeScribeRequest() throws {
        let configuration = ElevenLabsScribeConfiguration(
            apiKey: "  test-key  ",
            keyterms: ["Sam", "OpenClaw", "this keyterm is much too long for docs", "Sam"]
        )

        let request = try configuration.request()
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(value("model_id", in: queryItems), "scribe_v2_realtime")
        XCTAssertEqual(value("audio_format", in: queryItems), "pcm_16000")
        XCTAssertEqual(value("commit_strategy", in: queryItems), "vad")
        XCTAssertEqual(value("language_code", in: queryItems), "en")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        XCTAssertEqual(queryItems.filter { $0.name == "keyterms" }.map(\.value), ["Sam", "OpenClaw"])
    }

    func testDecodesPartialTranscriptAsVolatile() throws {
        let update = try ElevenLabsScribeTranscriber.transcriptionUpdate(
            from: Data(#"{"message_type":"partial_transcript","text":"what's my"}"#.utf8)
        )

        XCTAssertEqual(update, TranscriptionUpdate(text: "what's my", isFinal: false))
    }

    func testDecodesCommittedTranscriptAsFinal() throws {
        let update = try ElevenLabsScribeTranscriber.transcriptionUpdate(
            from: Data(#"{"message_type":"committed_transcript","text":"what's my name"}"#.utf8)
        )

        XCTAssertEqual(update, TranscriptionUpdate(text: "what's my name", isFinal: true))
    }

    func testIgnoresSessionStarted() throws {
        let update = try ElevenLabsScribeTranscriber.transcriptionUpdate(
            from: Data(#"{"message_type":"session_started","session_id":"abc"}"#.utf8)
        )

        XCTAssertNil(update)
    }

    func testThrowsProviderErrors() {
        XCTAssertThrowsError(
            try ElevenLabsScribeTranscriber.transcriptionUpdate(
                from: Data(#"{"message_type":"scribe_auth_error","message":"bad key"}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? ElevenLabsScribeError, .providerError("bad key"))
        }
    }

    private func value(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}
