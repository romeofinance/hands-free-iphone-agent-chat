import XCTest
@testable import Romeo

final class LiveTranscriptClientTests: XCTestCase {
    func testBuildsLiveTranscriptRequestFromContract() throws {
        let client = LiveTranscriptClient()

        let request = try client.makeLiveTranscriptRequest(
            baseURL: "https://agent-host.your-tailnet.ts.net",
            transcript: "User: Hello\nRomeo: Hi"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://agent-host.your-tailnet.ts.net/voice/live-transcript")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertNil(object?["request_id"])
        XCTAssertNil(object?["session_id"])
        XCTAssertEqual(object?["transcript"] as? String, "User: Hello\nRomeo: Hi")
    }

    func testBuildsLiveTranscriptRequestUnderBasePath() throws {
        let client = LiveTranscriptClient()

        let request = try client.makeLiveTranscriptRequest(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443/romeo",
            transcript: "User: Hello"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://agent-host.your-tailnet.ts.net:8443/romeo/voice/live-transcript")
    }

    func testLiveTranscriptResponseDecodesContractShape() throws {
        let data = #"{"status":"ok"}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(LiveTranscriptResponse.self, from: data)

        XCTAssertEqual(response, LiveTranscriptResponse(status: "ok"))
    }
}
