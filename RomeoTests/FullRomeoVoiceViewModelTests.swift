import XCTest
@testable import Romeo

@MainActor
final class FullRomeoVoiceViewModelTests: XCTestCase {
    func testListeningStateWaitsForTranscriberStart() async {
        let transcriber = ControllableTranscriber()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: EmptyFullRomeoStreamer(),
            speaker: NoopSpeaker(),
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "",
            elevenLabsVoiceID: "",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(transcriber.isStarted)
        XCTAssertEqual(viewModel.state, .starting)

        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)

        XCTAssertEqual(viewModel.state, .listening)
        await viewModel.cancel().value
    }

    func testStartupTimeoutRetriesOnceBeforeListening() async {
        let firstTranscriber = ControllableTranscriber()
        let secondTranscriber = ControllableTranscriber()
        let factory = QueuedTranscriberFactory([firstTranscriber, secondTranscriber])
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in factory.next() },
            fullRomeoClient: EmptyFullRomeoStreamer(),
            speaker: NoopSpeaker(),
            cuePlayer: NoopCuePlayer(),
            startupTimeout: .milliseconds(100),
            restartDelay: .milliseconds(10)
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "",
            elevenLabsVoiceID: "",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(factory.startCount == 2)

        XCTAssertEqual(firstTranscriber.stopCount, 1)
        XCTAssertEqual(viewModel.state, .starting)

        secondTranscriber.yield(.started)
        await waitUntil(viewModel.state == .listening)

        XCTAssertEqual(viewModel.state, .listening)
        await viewModel.cancel().value
    }

    func testFullRomeoReplyUsesPlaybackOnlyAudioSession() async {
        let transcriber = ControllableTranscriber()
        let speaker = RecordingSpeaker()
        let cuePlayer = RecordingCuePlayer()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: FixedFullRomeoStreamer([
                .text("Crisp reply."),
                .status("done")
            ]),
            speaker: speaker,
            cuePlayer: cuePlayer
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        transcriber.yield(TranscriptionUpdate(text: "What is my name Romeo over", isFinal: true))
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.state, .done)
        XCTAssertEqual(speaker.spokenTexts, ["Crisp reply."])
        let cueCounts = await cuePlayer.counts
        XCTAssertEqual(cueCounts.activation, 1)
        XCTAssertEqual(cueCounts.submission, 1)
    }

    func testCliFallbackStatusUpdatesTransportDiagnosticWithoutSpeakingIt() async {
        let transcriber = ControllableTranscriber()
        let speaker = RecordingSpeaker()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: FixedFullRomeoStreamer([
                .status("thinking"),
                .status("using_cli_fallback"),
                .status("future_status"),
                .text("Crisp reply."),
                .status("done")
            ]),
            speaker: speaker,
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        transcriber.yield(TranscriptionUpdate(text: "What is my name Romeo over", isFinal: true))
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(viewModel.transportText, "CLI fallback")
        XCTAssertEqual(viewModel.replyText, "Crisp reply.")
        XCTAssertEqual(speaker.spokenTexts, ["Crisp reply."])
    }

    func testFullRomeoRejectsMissingVoiceIDBeforeSpeaking() async {
        let transcriber = ControllableTranscriber()
        let speaker = RecordingSpeaker()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: FixedFullRomeoStreamer([.text("Should not speak."), .status("done")]),
            speaker: speaker,
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        transcriber.yield(TranscriptionUpdate(text: "Hello Romeo over", isFinal: true))
        await waitUntil({
            if case .failed = viewModel.state {
                return true
            }
            return false
        }())

        XCTAssertEqual(speaker.spokenTexts, [])
    }

    func testCancelWhileManualSubmissionSettlesDoesNotSend() async {
        let transcriber = ControllableTranscriber(stopDelay: .milliseconds(150))
        let streamer = RecordingFullRomeoStreamer()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: streamer,
            speaker: NoopSpeaker(),
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )

        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        viewModel.transcript = "Do not send this"
        viewModel.submitCurrentTranscript(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test"
        )
        await waitUntil(viewModel.state == .thinking)

        await viewModel.cancel().value
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(streamer.requestCount, 0)
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testRapidManualSubmitOnlySendsOnce() async {
        let transcriber = ControllableTranscriber(stopDelay: .milliseconds(50))
        let streamer = RecordingFullRomeoStreamer()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: streamer,
            speaker: NoopSpeaker(),
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )
        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        viewModel.transcript = "Send this once"

        viewModel.submitCurrentTranscript(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test"
        )
        viewModel.submitCurrentTranscript(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test"
        )

        await waitUntil(viewModel.state == .done)
        XCTAssertEqual(streamer.requestCount, 1)
    }

    func testAudioInterruptionWhileThinkingPreservesPendingReply() async {
        let transcriber = ControllableTranscriber()
        let streamer = ControllableFullRomeoStreamer()
        let speaker = RecordingSpeaker()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: streamer,
            speaker: speaker,
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )
        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        transcriber.yield(TranscriptionUpdate(text: "Keep waiting Romeo over", isFinal: true))
        await waitUntil(viewModel.state == .thinking && streamer.requestCount == 1)

        let cleanup = viewModel.handleAudioInterruption()

        XCTAssertNil(cleanup)
        XCTAssertEqual(viewModel.state, .thinking)
        XCTAssertEqual(streamer.requestCount, 1)

        streamer.yield(.text("Still here."))
        streamer.yield(.status("done"))
        streamer.finish()
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(speaker.spokenTexts, ["Still here."])
    }

    func testRepeatedFullRequestAcknowledgesThinkingWithoutSecondMiniRequest() async {
        let transcriber = ControllableTranscriber()
        let streamer = ControllableFullRomeoStreamer()
        let speaker = RecordingSpeaker()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: streamer,
            speaker: speaker,
            cuePlayer: NoopCuePlayer()
        )

        viewModel.start(
            baseURL: "https://mini.tailnet.ts.net:8443",
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test",
            source: "test",
            sttProvider: .appleSpeechAnalyzer
        )
        await waitUntil(transcriber.isStarted)
        transcriber.yield(.started)
        await waitUntil(viewModel.state == .listening)
        transcriber.yield(TranscriptionUpdate(text: "Take your time Romeo over", isFinal: true))
        await waitUntil(viewModel.state == .thinking && streamer.requestCount == 1)

        viewModel.acknowledgeStillThinking(
            elevenLabsAPIKey: "eleven-test",
            elevenLabsVoiceID: "voice-test"
        )
        await waitUntil(speaker.spokenTexts == ["I'm still thinking."])

        XCTAssertEqual(viewModel.state, .thinking)
        XCTAssertEqual(streamer.requestCount, 1)

        streamer.yield(.text("Finished."))
        streamer.yield(.status("done"))
        streamer.finish()
        await waitUntil(viewModel.state == .done)

        XCTAssertEqual(speaker.spokenTexts, ["I'm still thinking.", "Finished."])
    }

    func testClauseSplitterKeepsTimesAndNumbersWhole() {
        let viewModel = FullRomeoVoiceViewModel(speaker: NoopSpeaker(), cuePlayer: NoopCuePlayer())

        // Times (colon) and list commas must not split — the whole line is one clause.
        XCTAssertEqual(
            viewModel.clausesForTesting("10:00 get coffee, 10:30 go to library. "),
            ["10:00 get coffee, 10:30 go to library."]
        )
        // Decimals must not split on the period.
        XCTAssertEqual(viewModel.clausesForTesting("Pi is 3.14 today. "), ["Pi is 3.14 today."])
        // Real sentence ends still split; trailing unterminated text is left buffered.
        XCTAssertEqual(viewModel.clausesForTesting("First. Second"), ["First."])
        // Newlines split.
        XCTAssertEqual(viewModel.clausesForTesting("Line one\nLine two\n"), ["Line one", "Line two"])
    }

    func testCombinesQuestionThenCommandSegment() {
        let viewModel = FullRomeoVoiceViewModel()

        let first = viewModel.combinedTranscriptForTesting(
            accumulated: "",
            update: "what's my name"
        )
        let second = viewModel.combinedTranscriptForTesting(
            accumulated: first,
            update: "Romeo over"
        )

        XCTAssertEqual(second, "what's my name Romeo over")
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: second),
            "what's my name"
        )
    }

    func testProgressiveTranscriptUpdateDoesNotDuplicateText() {
        let viewModel = FullRomeoVoiceViewModel()

        let combined = viewModel.combinedTranscriptForTesting(
            accumulated: "what's my",
            update: "what's my name"
        )

        XCTAssertEqual(combined, "what's my name")
    }

    func testOverlappingPartialCommandUpdatesDoNotDuplicateText() {
        let viewModel = FullRomeoVoiceViewModel()

        let first = viewModel.combinedTranscriptForTesting(
            accumulated: "What's my name? R",
            update: "Rome"
        )
        let second = viewModel.combinedTranscriptForTesting(
            accumulated: first,
            update: "Romeo"
        )

        XCTAssertEqual(first, "What's my name? Rome")
        XCTAssertEqual(second, "What's my name? Romeo")
    }

    func testVolatileThenFinalResultDoesNotDuplicateText() {
        let viewModel = FullRomeoVoiceViewModel()

        let transcripts = viewModel.streamingTranscriptForTesting([
            TranscriptionUpdate(text: "five plus one", isFinal: false),
            TranscriptionUpdate(text: "five plus one", isFinal: false),
            TranscriptionUpdate(text: "five plus one", isFinal: true)
        ])

        XCTAssertEqual(transcripts, [
            "five plus one",
            "five plus one",
            "five plus one"
        ])
    }

    func testVolatileResultIsReplacedUntilFinalized() {
        let viewModel = FullRomeoVoiceViewModel()

        let transcripts = viewModel.streamingTranscriptForTesting([
            TranscriptionUpdate(text: "what's my", isFinal: false),
            TranscriptionUpdate(text: "what's my name", isFinal: false),
            TranscriptionUpdate(text: "what's my name", isFinal: true),
            TranscriptionUpdate(text: "Romeo over", isFinal: false)
        ])

        XCTAssertEqual(transcripts, [
            "what's my",
            "what's my name",
            "what's my name",
            "what's my name Romeo over"
        ])
    }

    func testFullFinalHypothesisCanReplaceCommittedPrefix() {
        let viewModel = FullRomeoVoiceViewModel()

        let transcripts = viewModel.streamingTranscriptForTesting([
            TranscriptionUpdate(text: "what's my name", isFinal: true),
            TranscriptionUpdate(text: "what's my name Romeo over", isFinal: false),
            TranscriptionUpdate(text: "what's my name Romeo over", isFinal: true)
        ])

        XCTAssertEqual(transcripts, [
            "what's my name",
            "what's my name Romeo over",
            "what's my name Romeo over"
        ])
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class ControllableTranscriber: Transcriber, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?
    private let stopDelay: Duration
    var isStarted = false
    var stopCount = 0

    init(stopDelay: Duration = .zero) {
        self.stopDelay = stopDelay
    }

    func start() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            isStarted = true
        }
    }

    func stop() async {
        stopCount += 1
        try? await Task.sleep(for: stopDelay)
        continuation?.finish()
        continuation = nil
    }

    func yield(_ update: TranscriptionUpdate) {
        continuation?.yield(update)
    }
}

private final class RecordingFullRomeoStreamer: FullRomeoStreaming, @unchecked Sendable {
    private(set) var requestCount = 0

    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class ControllableFullRomeoStreamer: FullRomeoStreaming, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<FullRomeoStreamEvent, Error>.Continuation?
    private(set) var requestCount = 0

    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func yield(_ event: FullRomeoStreamEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
    }
}

private final class QueuedTranscriberFactory: @unchecked Sendable {
    private var transcribers: [ControllableTranscriber]
    private(set) var startCount = 0

    init(_ transcribers: [ControllableTranscriber]) {
        self.transcribers = transcribers
    }

    func next() -> ControllableTranscriber {
        startCount += 1
        return transcribers.removeFirst()
    }
}

private struct EmptyFullRomeoStreamer: FullRomeoStreaming {
    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct FixedFullRomeoStreamer: FullRomeoStreaming {
    let events: [FullRomeoStreamEvent]

    init(_ events: [FullRomeoStreamEvent]) {
        self.events = events
    }

    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private final class RecordingSpeaker: TextToSpeechSpeaking, @unchecked Sendable {
    var spokenTexts: [String] = []
    var stopCount = 0

    // Encode the text into the "audio" so play() can record clauses in playback
    // order (synthesis may complete out of order due to prefetch).
    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data {
        Data(text.utf8)
    }

    func play(_ audio: Data) async throws {
        spokenTexts.append(String(decoding: audio, as: UTF8.self))
    }

    func stop() async {
        stopCount += 1
    }
}

private struct NoopSpeaker: TextToSpeechSpeaking {
    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data { Data() }
    func play(_ audio: Data) async throws {}
    func stop() async {}
}

private struct NoopCuePlayer: RomeoCuePlaying {
    func playActivationCue() async {}
    func playSubmissionCue() async {}
}

private actor RecordingCuePlayer: RomeoCuePlaying {
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
