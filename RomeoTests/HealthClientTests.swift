import XCTest
@testable import Romeo

final class HealthClientTests: XCTestCase {
    func testNewInstallHasNoFakeTailnetURLDefault() {
        XCTAssertEqual(AppDefaults.miniBaseURL, "")
    }

    func testHealthResponseDecodesContractShape() throws {
        let data = #"{"status":"ok","version":"0.1.0"}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(HealthResponse.self, from: data)

        XCTAssertEqual(response, HealthResponse(status: "ok", version: "0.1.0"))
    }

    func testRejectsNonHTTPSRemoteURL() async {
        let client = HealthClient()

        do {
            _ = try await client.checkHealth(baseURL: "http://agent-host.your-tailnet.ts.net:8443")
            XCTFail("Expected invalidBaseURL")
        } catch let error as HealthClientError {
            XCTAssertEqual(error, .invalidBaseURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBuildsHealthRequestFromContractBaseURL() throws {
        let client = HealthClient()

        let request = try client.makeHealthRequest(
            baseURL: " https://agent-host.your-tailnet.ts.net/ "
        )

        XCTAssertEqual(request.url?.absoluteString, "https://agent-host.your-tailnet.ts.net/health")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDropsAccidentalQueryAndFragmentFromBaseURL() throws {
        let client = HealthClient()

        let request = try client.makeHealthRequest(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443?debug=true#section"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://agent-host.your-tailnet.ts.net:8443/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPreservesBasePathWithoutExplicitPort() throws {
        let client = HealthClient()

        let request = try client.makeHealthRequest(
            baseURL: "https://agent-host.your-tailnet.ts.net/romeo"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://agent-host.your-tailnet.ts.net/romeo/health"
        )
    }

    func testHealthErrorsUseAgentTerminology() {
        XCTAssertEqual(
            HealthClientError.invalidBaseURL.localizedDescription,
            "Enter a valid agent Tailnet URL."
        )
        XCTAssertEqual(
            HealthClientError.invalidResponse.localizedDescription,
            "The agent service returned an unexpected response."
        )
        XCTAssertEqual(
            HealthClientError.serverStatus(503).localizedDescription,
            "The agent service returned HTTP 503."
        )
    }
}
