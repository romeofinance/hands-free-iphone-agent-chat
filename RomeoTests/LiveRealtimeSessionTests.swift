import XCTest
@testable import Romeo

final class LiveRealtimeSessionTests: XCTestCase {
    @MainActor
    func testRealtimeCallsRequestUsesPersistentKeyAndUnifiedCallsForm() throws {
        let request = try LiveRealtimeOpenAISession.makeRealtimeCallsRequest(
            apiKey: "sk-test",
            localSDP: "v=0\r\no=- test"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/realtime/calls")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=romeo-"))

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("name=\"sdp\""))
        XCTAssertTrue(body.contains("Content-Type: application/sdp"))
        XCTAssertTrue(body.contains("v=0\r\no=- test"))
        XCTAssertTrue(body.contains("name=\"session\""))
        XCTAssertTrue(body.contains("\"type\":\"realtime\""))
        XCTAssertTrue(body.contains("\"model\":\"gpt-realtime-2\""))
        XCTAssertTrue(body.contains("\"output_modalities\":[\"audio\"]"))
        XCTAssertTrue(body.contains("\"voice\":\"marin\""))
        XCTAssertTrue(body.contains("\"type\":\"server_vad\""))
        XCTAssertTrue(body.contains("\"effort\":\"low\""))
        XCTAssertFalse(body.contains("\"modalities\""))
    }

    func testConnectionTimeoutGivesActionableMessage() {
        XCTAssertEqual(
            LiveRealtimeError.connectionTimedOut.localizedDescription,
            "OpenAI realtime did not connect within 20 seconds."
        )
    }
}
