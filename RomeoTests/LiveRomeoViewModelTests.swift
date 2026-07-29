import XCTest
@testable import Romeo

@MainActor
final class LiveRomeoViewModelTests: XCTestCase {
    func testBareDonePhraseEndsLiveSessionAndPostsTranscriptSoFar() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let cuePlayer = RecordingLiveCuePlayer()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient,
            cuePlayer: cuePlayer
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("What's my name?"))
        liveSession.yield(.assistantTranscript("Sam."))
        liveSession.yield(.userTranscript("Romeo over"))

        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(liveSession.stopCount, 1)
        XCTAssertEqual(transcriptClient.transcripts, ["User: What's my name?\nRomeo: Sam."])
        XCTAssertFalse(viewModel.transcript.contains("Romeo over"))
        let cueCounts = await cuePlayer.counts
        XCTAssertEqual(cueCounts.activation, 1)
        XCTAssertEqual(cueCounts.submission, 1)
    }

    func testDonePhraseSuffixAppendsStrippedUserTextBeforeEnding() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient,
            cuePlayer: SilentCuePlayer()
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)

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
            transcriptClient: transcriptClient,
            cuePlayer: SilentCuePlayer()
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Hello"))
        liveSession.yield(.assistantTranscript("Hi."))
        viewModel.stop(baseURL: "https://agent-host.your-tailnet.ts.net:8443")

        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(liveSession.stopCount, 1)
        XCTAssertEqual(transcriptClient.baseURLs, ["https://agent-host.your-tailnet.ts.net:8443"])
        XCTAssertEqual(transcriptClient.transcripts, ["User: Hello\nRomeo: Hi."])
        XCTAssertEqual(viewModel.transcriptPostStatusText, "Live transcript posted.")
    }

    func testManualEndBeforeTranscriptSkipsEmptyPost() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let cuePlayer = RecordingLiveCuePlayer()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient,
            cuePlayer: cuePlayer
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)

        viewModel.stop(baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        await waitUntil(viewModel.state == .done)

        XCTAssertTrue(transcriptClient.transcripts.isEmpty)
        XCTAssertEqual(liveSession.stopCount, 1)
        XCTAssertEqual(viewModel.transcriptPostStatusText, "No live transcript to post.")
        let cueCounts = await cuePlayer.counts
        XCTAssertEqual(cueCounts.submission, 1)
    }

    func testStopDuringPendingRestartPreventsDelayedStart() async {
        let liveSession = ControllableLiveRealtimeSession()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: RecordingLiveTranscriptClient(),
            cuePlayer: SilentCuePlayer()
        )

        viewModel.restart(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        viewModel.stop(baseURL: "https://agent-host.your-tailnet.ts.net:8443")
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertFalse(liveSession.isStarted)
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.canStart)
    }

    func testDiscardDoesNotPostLiveTranscript() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient,
            cuePlayer: SilentCuePlayer()
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)

        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Hello"))
        viewModel.cancel()
        await Task.yield()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(transcriptClient.transcripts, [])
    }

    func testCancelDuringCompletionCueDoesNotPostTranscript() async {
        let liveSession = ControllableLiveRealtimeSession()
        let transcriptClient = RecordingLiveTranscriptClient()
        let cuePlayer = BlockingSubmissionCuePlayer()
        let viewModel = LiveRomeoViewModel(
            makeRealtimeSession: { liveSession },
            transcriptClient: transcriptClient,
            cuePlayer: cuePlayer
        )

        viewModel.start(
            baseURL: "https://agent-host.your-tailnet.ts.net:8443",
            openAIAPIKey: "sk-test"
        )
        await waitUntil(liveSession.isStarted)
        liveSession.yield(.connected)
        liveSession.yield(.userTranscript("Do not post Romeo over"))

        for _ in 0..<50 {
            if await cuePlayer.submissionStarted {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let submissionStarted = await cuePlayer.submissionStarted
        XCTAssertTrue(submissionStarted)

        await viewModel.cancel().value
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(transcriptClient.transcripts, [])
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct SilentCuePlayer: RomeoCuePlaying {
    func playActivationCue() async {}
    func playSubmissionCue() async {}
}

private actor RecordingLiveCuePlayer: RomeoCuePlaying {
    private var activationCount = 0
    private var submissionCount = 0

    var counts: (activation: Int, submission: Int) {
        (activationCount, submissionCount)
    }

    func playActivationCue() async {
        activationCount += 1
    }

    func playSubmissionCue() async {
        submissionCount += 1
    }
}

private actor BlockingSubmissionCuePlayer: RomeoCuePlaying {
    private(set) var submissionStarted = false

    func playActivationCue() async {}

    func playSubmissionCue() async {
        submissionStarted = true
        try? await Task.sleep(for: .seconds(60))
    }
}

@MainActor
private final class ControllableLiveRealtimeSession: LiveRealtimeSessioning, @unchecked Sendable {
    private var continuation: AsyncStream<LiveRealtimeEvent>.Continuation?
    var isStarted = false
    var stopCount = 0

    func start(apiKey: String, duckingLevel: RomeoDuckingLevel = .max) -> AsyncStream<LiveRealtimeEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            isStarted = true
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
