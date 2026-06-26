import XCTest
@testable import Romeo

@MainActor
final class LiveRomeoViewModelTests: XCTestCase {
    func testBareDonePhraseEndsLiveSessionAndPostsTranscriptSoFar() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await Task.yield()

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("What's my name?"))
        liveSession.yield(.assistantTranscript("Sam."))
        liveSession.yield(.userTranscript("Romeo over"))

        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(liveSession.stopCount, 1)
        XCTAssertEqual(transcriptClient.transcripts, ["User: What's my name?\nRomeo: Sam."])
        XCTAssertFalse(viewModel.transcript.contains("Romeo over"))
    }

    func testDonePhraseSuffixAppendsStrippedUserTextBeforeEnding() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await Task.yield()

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Tell Agent One this worked, Romeo, over."))

        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(transcriptClient.transcripts, ["User: Tell Agent One this worked"])
    }

    func testManualEndPostsLiveTranscript() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await Task.yield()

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Hello"))
        liveSession.yield(.assistantTranscript("Hi."))
        viewModel.stop(baseURL: "https://mini.tailnet.ts.net:8443")

        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(liveSession.stopCount, 1)
        XCTAssertEqual(transcriptClient.baseURLs, ["https://mini.tailnet.ts.net:8443"])
        XCTAssertEqual(transcriptClient.transcripts, ["User: Hello\nRomeo: Hi."])
        XCTAssertEqual(viewModel.transcriptPostStatusText, "Live transcript posted.")
    }

    func testDiscardDoesNotPostLiveTranscript() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await Task.yield()

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Hello"))
        viewModel.cancel()
        await Task.yield()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(transcriptClient.transcripts, [])
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class ControllableLiveRealtimeSession: LiveRealtimeSessioning, @unchecked Sendable {
    private var continuation: AsyncStream<LiveRealtimeEvent>.Continuation?
    var stopCount = 0

    func start(apiKey: String, duckingLevel: RomeoDuckingLevel = .max) -> AsyncStream<LiveRealtimeEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
        continuation?.yield(.ended)
        continuation?.finish()
    }

    func yield(_ event: LiveRealtimeEvent) {
        continuation?.yield(event)
    }
}

private final class RecordingLiveTranscriptClient: LiveTranscriptPosting, @unchecked Sendable {
    var baseURLs: [String] = []
    var transcripts: [String] = []

    func postLiveTranscript(baseURL: String, transcript: String) async throws {
        baseURLs.append(baseURL)
        transcripts.append(transcript)
    }
}
