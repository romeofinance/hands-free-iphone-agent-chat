import XCTest
@testable import Romeo

final class FullRomeoClientTests: XCTestCase {
    func testBuildsFullRomeoRequestFromContract() throws {
        let client = FullRomeoClient()

        let request = try client.makeFullRomeoRequest(
            baseURL: "https://mini.tailnet.ts.net:8443",
            text: "Hello Romeo"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://mini.tailnet.ts.net:8443/voice/full-romeo")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertNil(object?["request_id"])
        XCTAssertEqual(object?["text"] as? String, "Hello Romeo")

        let metadata = object?["mode_metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["source"] as? String, "tap")
    }

    func testBuildsFullRomeoRequestUnderBasePath() throws {
        let client = FullRomeoClient()

        let request = try client.makeFullRomeoRequest(
            baseURL: "https://mini.tailnet.ts.net:8443/romeo",
            text: "Hello"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://mini.tailnet.ts.net:8443/romeo/voice/full-romeo")
    }

    func testBuildsFullRomeoRequestWithSiriSource() throws {
        let client = FullRomeoClient()

        let request = try client.makeFullRomeoRequest(
            baseURL: "https://mini.tailnet.ts.net:8443",
            text: "Hello from Siri",
            source: "siri"
        )

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let metadata = object?["mode_metadata"] as? [String: Any]

        XCTAssertEqual(metadata?["source"] as? String, "siri")
    }

    func testInvalidStreamEventErrorIsDiagnostic() {
        let error = MiniClientError.invalidStreamEvent(event: "text", data: #"{"unexpected":true}"#)

        XCTAssertEqual(
            error.localizedDescription,
            #"Could not read text stream event: {"unexpected":true}"#
        )
    }

    func testDecodesStrictContractStreamEvents() throws {
        let client = FullRomeoClient()

        XCTAssertEqual(
            try client.streamEvent(from: SSEMessage(event: "status", data: #"{"value":"thinking"}"#)),
            .status("thinking")
        )
        XCTAssertEqual(
            try client.streamEvent(from: SSEMessage(event: "status", data: #"{"value":"using_cli_fallback"}"#)),
            .status("using_cli_fallback")
        )
        XCTAssertEqual(
            try client.streamEvent(from: SSEMessage(event: "status", data: #"{"value":"future_status"}"#)),
            .status("future_status")
        )
        XCTAssertEqual(
            try client.streamEvent(from: SSEMessage(event: "text", data: #"{"delta":"four"}"#)),
            .text("four")
        )
        XCTAssertEqual(
            try client.streamEvent(from: SSEMessage(event: "error", data: #"{"message":"bad"}"#)),
            .error("bad")
        )
    }

    func testRejectsNonContractStreamEventVariants() throws {
        let client = FullRomeoClient()

        XCTAssertThrowsError(try client.streamEvent(from: SSEMessage(event: "status", data: #"{"status":"thinking"}"#)))
        XCTAssertThrowsError(try client.streamEvent(from: SSEMessage(event: "text", data: #"{"text":"four"}"#)))
        XCTAssertThrowsError(try client.streamEvent(from: SSEMessage(event: "text", data: #""four""#)))
        XCTAssertThrowsError(try client.streamEvent(from: SSEMessage(event: "text", data: "four")))
    }
}
