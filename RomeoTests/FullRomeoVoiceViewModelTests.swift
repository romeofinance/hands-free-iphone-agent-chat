import XCTest
@testable import Romeo

@MainActor
final class FullRomeoVoiceViewModelTests: XCTestCase {
    func testListeningStateWaitsForTranscriberStart() async {
        let transcriber = ControllableTranscriber()
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: EmptyFullRomeoStreamer(),
            speaker: NoopSpeaker()
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
            startupTimeout: .milliseconds(20),
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
        let viewModel = FullRomeoVoiceViewModel(
            makeTranscriber: { _, _, _ in transcriber },
            fullRomeoClient: FixedFullRomeoStreamer([
                .text("Crisp reply."),
                .status("done")
            ]),
            speaker: speaker
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
            speaker: speaker
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
            speaker: speaker
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

    func testClauseSplitterKeepsTimesAndNumbersWhole() {
        let viewModel = FullRomeoVoiceViewModel(speaker: NoopSpeaker())

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
    var isStarted = false
    var stopCount = 0

    func start() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            isStarted = true
        }
    }

    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ update: TranscriptionUpdate) {
        continuation?.yield(update)
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
