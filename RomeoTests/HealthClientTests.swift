import XCTest
@testable import Romeo

final class HealthClientTests: XCTestCase {
    func testHealthResponseDecodesContractShape() throws {
        let data = #"{"status":"ok","version":"0.1.0"}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(HealthResponse.self, from: data)

        XCTAssertEqual(response, HealthResponse(status: "ok", version: "0.1.0"))
    }

    func testRejectsNonHTTPSRemoteURL() async {
        let client = HealthClient()

        do {
            _ = try await client.checkHealth(baseURL: "http://mini.tailnet.ts.net:8443")
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
            baseURL: " https://mini.tailnet.ts.net:8443/ "
        )

        XCTAssertEqual(request.url?.absoluteString, "https://mini.tailnet.ts.net:8443/health")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDropsAccidentalQueryAndFragmentFromBaseURL() throws {
        let client = HealthClient()

        let request = try client.makeHealthRequest(
            baseURL: "https://mini.tailnet.ts.net:8443?debug=true#section"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://mini.tailnet.ts.net:8443/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
