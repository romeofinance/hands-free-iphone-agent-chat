import XCTest
@testable import Romeo

@MainActor
final class FullRomeoViewModelTests: XCTestCase {
    func testSendWhileRequestIsInFlightIsIgnored() async {
        let client = ControllableFullRomeoClient()
        let viewModel = FullRomeoViewModel(client: client)

        viewModel.send(text: "first", baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await Task.yield()

        XCTAssertEqual(client.sentTexts, ["first"])
        XCTAssertEqual(viewModel.state, .streaming)
        XCTAssertEqual(viewModel.statusText, "Thinking...")

        viewModel.send(text: "second", baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await Task.yield()

        XCTAssertEqual(client.sentTexts, ["first"])
        XCTAssertEqual(viewModel.state, .streaming)
    }

    func testSecondSendAfterFirstFinishesStartsFreshRequest() async {
        let client = ControllableFullRomeoClient()
        let viewModel = FullRomeoViewModel(client: client)

        viewModel.send(text: "first", baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await Task.yield()

        client.continuations[0].yield(.status("done"))
        client.continuations[0].finish()
        await waitUntil(viewModel.canSend)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(viewModel.replyText, "")

        viewModel.send(text: "second", baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await Task.yield()

        XCTAssertEqual(client.sentTexts, ["first", "second"])
        XCTAssertEqual(viewModel.state, .streaming)
        XCTAssertEqual(viewModel.statusText, "Thinking...")

        client.continuations[1].yield(.text("second reply"))
        client.continuations[1].yield(.status("done"))
        client.continuations[1].finish()
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.replyText, "second reply")
        XCTAssertEqual(viewModel.state, .done)
    }

    func testTransportDiagnosticUpdatesOnlyForCliFallbackStatus() async {
        let client = ControllableFullRomeoClient()
        let viewModel = FullRomeoViewModel(client: client)

        viewModel.send(text: "hello", baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await Task.yield()

        XCTAssertEqual(viewModel.transportText, "Gateway")
        client.continuations[0].yield(.status("future_status"))
        await Task.yield()

        XCTAssertEqual(viewModel.statusText, "Thinking...")
        XCTAssertEqual(viewModel.transportText, "Gateway")

        client.continuations[0].yield(.status("using_cli_fallback"))
        client.continuations[0].yield(.text("reply"))
        client.continuations[0].yield(.status("done"))
        client.continuations[0].finish()
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.transportText, "CLI fallback")
        XCTAssertEqual(viewModel.replyText, "reply")
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<20 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class ControllableFullRomeoClient: FullRomeoStreaming, @unchecked Sendable {
    var continuations: [AsyncThrowingStream<FullRomeoStreamEvent, Error>.Continuation] = []
    var sentTexts: [String] = []

    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        sentTexts.append(text)

        return AsyncThrowingStream { continuation in
            continuations.append(continuation)
        }
    }
}
