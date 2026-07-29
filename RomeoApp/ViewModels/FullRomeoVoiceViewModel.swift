import Foundation
import Observation

@MainActor
@Observable
final class FullRomeoVoiceViewModel {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case thinking
        case speaking
        case done
        case failed(String)
    }

    var state: State = .idle
    var transcript = ""
    var submittedText = ""
    var replyText = ""
    var statusText = "Idle"
    var transportText = "Gateway"

    private let makeTranscriber: @Sendable (
        _ provider: FullRomeoSTTProvider,
        _ elevenLabsAPIKey: String,
        _ duckingLevel: RomeoDuckingLevel
    ) -> any Transcriber
    private let fullRomeoClient: any FullRomeoStreaming
    private let playbackQueue: SpeechPlaybackQueue
    private let cuePlayer: any RomeoCuePlaying
    private let startupTimeout: Duration
    private let restartDelay: Duration
    private var listenTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var thinkingAcknowledgmentTask: Task<Void, Never>?
    private var startupWatchdogTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var activeTranscriber: (any Transcriber)?

    init(
        makeTranscriber: @escaping @Sendable (
            _ provider: FullRomeoSTTProvider,
            _ elevenLabsAPIKey: String,
            _ duckingLevel: RomeoDuckingLevel
        ) -> any Transcriber = { provider, apiKey, duckingLevel in
            switch provider {
            case .elevenLabsScribe:
                ElevenLabsScribeTranscriber(apiKey: apiKey, duckingLevel: duckingLevel)
            case .appleSpeechAnalyzer:
                AppleSpeechAnalyzerTranscriber(duckingLevel: duckingLevel)
            }
        },
        fullRomeoClient: any FullRomeoStreaming = FullRomeoClient(),
        speaker: any TextToSpeechSpeaking = ElevenLabsTTSClient(),
        cuePlayer: any RomeoCuePlaying = RomeoCuePlayer(),
        startupTimeout: Duration = .seconds(3),
        restartDelay: Duration = .milliseconds(900)
    ) {
        self.makeTranscriber = makeTranscriber
        self.fullRomeoClient = fullRomeoClient
        self.startupTimeout = startupTimeout
        self.restartDelay = restartDelay
        self.cuePlayer = cuePlayer
        playbackQueue = SpeechPlaybackQueue(speaker: speaker)
    }

    var canStart: Bool {
        listenTask == nil && turnTask == nil && restartTask == nil
    }

    func start(
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        sttProvider: FullRomeoSTTProvider = .elevenLabsScribe,
        duckingLevel: RomeoDuckingLevel = .max,
        startupRetriesRemaining: Int = 1
    ) {
        guard canStart else {
            if let activeTurnID {
                TimingTrace(operation: "full_romeo_voice", turnID: activeTurnID).mark("start_reset_in_flight")
            }
            restart(
                baseURL: baseURL,
                elevenLabsAPIKey: elevenLabsAPIKey,
                elevenLabsVoiceID: elevenLabsVoiceID,
                source: source,
                sttProvider: sttProvider,
                duckingLevel: duckingLevel,
                startupRetriesRemaining: startupRetriesRemaining
            )
            return
        }

        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if sttProvider == .elevenLabsScribe, apiKey.isEmpty {
            statusText = "Error"
            state = .failed(ElevenLabsTTSError.missingAPIKey.localizedDescription)
            return
        }

        let turnID = UUID()
        activeTurnID = turnID
        let trace = TimingTrace(operation: "full_romeo_voice", turnID: turnID)
        trace.mark("listening_start_requested", detail: "source=\(source) stt=\(sttProvider.rawValue) duck=\(duckingLevel.rawValue)")

        transcript = ""
        submittedText = ""
        replyText = ""
        statusText = "Starting \(sttProvider.displayName)"
        transportText = "Gateway"
        state = .starting

        let transcriber = makeTranscriber(sttProvider, apiKey, duckingLevel)
        activeTranscriber = transcriber
        scheduleStartupWatchdog(
            turnID: turnID,
            trace: trace,
            baseURL: baseURL,
            elevenLabsAPIKey: elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID,
            source: source,
            sttProvider: sttProvider,
            duckingLevel: duckingLevel,
            startupRetriesRemaining: startupRetriesRemaining
        )

        listenTask = Task {
            var transcriptState = StreamingTranscriptState()

            defer {
                if activeTurnID == turnID {
                    listenTask = nil
                }
            }

            do {
                trace.mark("activation_cue_started")
                await cuePlayer.playActivationCue()
                trace.mark("activation_cue_finished")
                guard activeTurnID == turnID, !Task.isCancelled else {
                    return
                }

                for try await update in transcriber.start() {
                    guard activeTurnID == turnID else {
                        return
                    }

                    if update.didStart {
                        startupWatchdogTask?.cancel()
                        startupWatchdogTask = nil
                        trace.mark("listening_started")
                        statusText = "Listening with \(sttProvider.displayName)"
                        state = .listening
                        continue
                    }

                    let displayedTranscript = transcriptState.apply(update)
                    transcript = displayedTranscript
                    trace.mark(
                        "transcription_update",
                        detail: "chars=\(displayedTranscript.count) final=\(update.isFinal)"
                    )

                    if await submitIfReady(
                        transcript: displayedTranscript,
                        baseURL: baseURL,
                        elevenLabsAPIKey: elevenLabsAPIKey,
                        elevenLabsVoiceID: elevenLabsVoiceID,
                        source: source,
                        turnID: turnID,
                        trace: trace,
                        duckingLevel: duckingLevel
                    ) {
                        return
                    }
                }
            } catch {
                guard activeTurnID == turnID else {
                    return
                }

                trace.mark("transcription_failed", detail: error.localizedDescription)
                statusText = "Error"
                state = .failed(error.localizedDescription)
                activeTurnID = nil
                listenTask = nil
                activeTranscriber = nil
                startupWatchdogTask?.cancel()
                startupWatchdogTask = nil
                try? RomeoAudioSession.deactivateNotifyingOthers()
            }
        }
    }

    func submitCurrentTranscript(
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        duckingLevel: RomeoDuckingLevel = .max
    ) {
        guard (state == .starting || state == .listening), let turnID = activeTurnID else {
            return
        }

        let trace = TimingTrace(operation: "full_romeo_voice", turnID: turnID)
        Task {
            await submitIfReady(
                transcript: transcript,
                baseURL: baseURL,
                elevenLabsAPIKey: elevenLabsAPIKey,
                elevenLabsVoiceID: elevenLabsVoiceID,
                source: source,
                turnID: turnID,
                trace: trace,
                duckingLevel: duckingLevel,
                allowMissingDonePhrase: true
            )
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        let turnID = activeTurnID
        if let turnID {
            TimingTrace(operation: "full_romeo_voice", turnID: turnID).mark("cancel_tapped")
        }

        listenTask?.cancel()
        listenTask = nil
        turnTask?.cancel()
        turnTask = nil
        restartTask?.cancel()
        restartTask = nil
        thinkingAcknowledgmentTask?.cancel()
        thinkingAcknowledgmentTask = nil
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        let transcriber = activeTranscriber
        let queue = playbackQueue
        activeTurnID = nil
        activeTranscriber = nil
        statusText = "Cancelled"
        state = .idle

        return Task.detached {
            await transcriber?.stop()
            await queue.stop()
            try? RomeoAudioSession.deactivateNotifyingOthers()
        }
    }

    @discardableResult
    func handleAudioInterruption() -> Task<Void, Never>? {
        switch state {
        case .starting, .listening:
            return cancel()
        case .thinking, .speaking:
            if let activeTurnID {
                TimingTrace(operation: "full_romeo_voice", turnID: activeTurnID)
                    .mark("audio_interruption_reply_preserved")
            }
            return nil
        case .idle, .done, .failed:
            return nil
        }
    }

    func acknowledgeStillThinking(elevenLabsAPIKey: String, elevenLabsVoiceID: String) {
        guard state == .thinking,
              thinkingAcknowledgmentTask == nil,
              let turnID = activeTurnID
        else {
            return
        }

        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !voiceID.isEmpty else {
            return
        }

        let queue = playbackQueue
        thinkingAcknowledgmentTask = Task {
            await queue.configure(apiKey: apiKey, voiceID: voiceID)
            guard activeTurnID == turnID, state == .thinking, !Task.isCancelled else {
                thinkingAcknowledgmentTask = nil
                return
            }

            await queue.enqueue("I'm still thinking.")
            do {
                try await queue.flush()
            } catch is CancellationError {
                // The explicit Stop or Live shortcut owns cancellation.
            } catch {
                AppTimingLogger.fullRomeo.error(
                    "thinking_acknowledgment_failed detail=\(error.localizedDescription, privacy: .public)"
                )
            }

            if activeTurnID == turnID, state == .thinking {
                try? RomeoAudioSession.deactivateNotifyingOthers()
            }
            thinkingAcknowledgmentTask = nil
        }
    }

    func restart(
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        sttProvider: FullRomeoSTTProvider = .elevenLabsScribe,
        duckingLevel: RomeoDuckingLevel = .max,
        startupRetriesRemaining: Int = 1
    ) {
        let cleanup = cancel()
        restartTask = Task {
            await cleanup.value
            do {
                try await Task.sleep(for: restartDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            restartTask = nil
            start(
                baseURL: baseURL,
                elevenLabsAPIKey: elevenLabsAPIKey,
                elevenLabsVoiceID: elevenLabsVoiceID,
                source: source,
                sttProvider: sttProvider,
                duckingLevel: duckingLevel,
                startupRetriesRemaining: startupRetriesRemaining
            )
        }
    }

    private func scheduleStartupWatchdog(
        turnID: UUID,
        trace: TimingTrace,
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        sttProvider: FullRomeoSTTProvider,
        duckingLevel: RomeoDuckingLevel,
        startupRetriesRemaining: Int
    ) {
        startupWatchdogTask?.cancel()
        let timeout = startupTimeout
        startupWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else {
                return
            }

            self?.handleStartupTimeout(
                turnID: turnID,
                trace: trace,
                baseURL: baseURL,
                elevenLabsAPIKey: elevenLabsAPIKey,
                elevenLabsVoiceID: elevenLabsVoiceID,
                source: source,
                sttProvider: sttProvider,
                duckingLevel: duckingLevel,
                startupRetriesRemaining: startupRetriesRemaining
            )
        }
    }

    private func handleStartupTimeout(
        turnID: UUID,
        trace: TimingTrace,
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        sttProvider: FullRomeoSTTProvider,
        duckingLevel: RomeoDuckingLevel,
        startupRetriesRemaining: Int
    ) {
        guard activeTurnID == turnID, state == .starting else {
            return
        }

        startupWatchdogTask = nil
        trace.mark("listening_start_timeout", detail: "retries_remaining=\(startupRetriesRemaining)")

        guard startupRetriesRemaining > 0 else {
            let cleanup = cancel()
            Task {
                await cleanup.value
                statusText = "Error"
                state = .failed("Microphone did not start. Try Romeo mode again.")
            }
            return
        }

        restart(
            baseURL: baseURL,
            elevenLabsAPIKey: elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID,
            source: source,
            sttProvider: sttProvider,
            duckingLevel: duckingLevel,
            startupRetriesRemaining: startupRetriesRemaining - 1
        )
    }

    @discardableResult
    private func submitIfReady(
        transcript: String,
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        turnID: UUID,
        trace: TimingTrace,
        duckingLevel: RomeoDuckingLevel = .max,
        allowMissingDonePhrase: Bool = false
    ) async -> Bool {
        guard activeTurnID == turnID, state == .starting || state == .listening else {
            return false
        }

        let text: String?
        if allowMissingDonePhrase {
            text = RomeoCommandDetector.textByStrippingDonePhrase(from: transcript)
                ?? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = RomeoCommandDetector.textByStrippingDonePhrase(from: transcript)
        }

        guard let text, !text.isEmpty else {
            return false
        }

        trace.mark("done_phrase_detected", detail: "text_chars=\(text.count)")
        statusText = "Thinking..."
        state = .thinking
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        let transcriber = activeTranscriber
        await transcriber?.stop()

        // Cancel can run while the transcriber is settling its final result.
        // Never let that old task submit after the turn has been replaced.
        guard activeTurnID == turnID, !Task.isCancelled else {
            return false
        }

        try? RomeoAudioSession.deactivateNotifyingOthers()
        activeTranscriber = nil
        listenTask = nil
        submit(
            text: text,
            baseURL: baseURL,
            elevenLabsAPIKey: elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID,
            source: source,
            turnID: turnID,
            trace: trace,
            duckingLevel: duckingLevel
        )
        return true
    }

    private func submit(
        text: String,
        baseURL: String,
        elevenLabsAPIKey: String,
        elevenLabsVoiceID: String,
        source: String,
        turnID: UUID,
        trace: TimingTrace,
        duckingLevel: RomeoDuckingLevel
    ) {
        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            state = .failed(ElevenLabsTTSError.missingAPIKey.localizedDescription)
            statusText = "Error"
            activeTurnID = nil
            try? RomeoAudioSession.deactivateNotifyingOthers()
            return
        }

        guard !voiceID.isEmpty else {
            state = .failed(ElevenLabsTTSError.missingVoiceID.localizedDescription)
            statusText = "Error"
            activeTurnID = nil
            try? RomeoAudioSession.deactivateNotifyingOthers()
            return
        }

        submittedText = text
        statusText = "Thinking..."
        state = .thinking

        // Creating the stream starts the agent request immediately. Consume its
        // buffered events only after the short acknowledgment cue releases audio.
        let responseStream = fullRomeoClient.streamFullRomeo(
            baseURL: baseURL,
            text: text,
            source: source
        )

        turnTask = Task {
            defer {
                if activeTurnID == turnID {
                    turnTask = nil
                    activeTurnID = nil
                }
            }

            do {
                trace.mark("submission_cue_started")
                await cuePlayer.playSubmissionCue()
                trace.mark("submission_cue_finished")
                guard activeTurnID == turnID, !Task.isCancelled else {
                    return
                }

                trace.mark("elevenlabs_api_key_ready")
                await playbackQueue.configure(apiKey: apiKey, voiceID: voiceID)

                var pendingSpeech = ""
                var receivedFirstText = false
                var queuedFirstSpeech = false
                for try await event in responseStream {
                    guard activeTurnID == turnID else {
                        return
                    }

                    switch event {
                    case .status(let value):
                        trace.mark("voice_status", detail: value)
                        switch value {
                        case "thinking":
                            statusText = "Thinking..."
                        case "using_cli_fallback":
                            trace.mark("transport_detected", detail: "transport=cli_fallback")
                            transportText = "CLI fallback"
                        case "done":
                            let finalClause = pendingSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !finalClause.isEmpty {
                                if !queuedFirstSpeech {
                                    queuedFirstSpeech = true
                                    trace.mark("first_tts_clause_queued", detail: "chars=\(finalClause.count)")
                                }
                                await playbackQueue.enqueue(finalClause)
                            }

                            statusText = "Speaking"
                            state = .speaking
                            try await playbackQueue.flush()
                            statusText = "Done"
                            state = .done
                            try? RomeoAudioSession.deactivateNotifyingOthers()
                        default:
                            trace.mark("unknown_status_ignored", detail: value)
                        }
                    case .text(let delta):
                        if !receivedFirstText {
                            receivedFirstText = true
                            trace.mark("first_reply_text_received", detail: "chars=\(delta.count)")
                        }
                        trace.mark("voice_text_delta", detail: "chars=\(delta.count)")
                        replyText += delta
                        pendingSpeech += delta

                        let clauses = extractCompletedClauses(from: &pendingSpeech)
                        if !clauses.isEmpty {
                            statusText = "Speaking"
                            state = .speaking
                        }

                        for clause in clauses {
                            if !queuedFirstSpeech {
                                queuedFirstSpeech = true
                                trace.mark("first_tts_clause_queued", detail: "chars=\(clause.count)")
                            }
                            await playbackQueue.enqueue(clause)
                        }
                    case .error(let message):
                        throw MiniClientError.streamError(message)
                    }
                }

                // Robustness: if the stream ends without an explicit `status: done`
                // (e.g. the agent closes the connection early), still flush any
                // remaining speech, finalize the turn, and release the audio
                // session so the duck does not stay stuck on background audio.
                if state == .thinking || state == .speaking {
                    let finalClause = pendingSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalClause.isEmpty {
                        statusText = "Speaking"
                        state = .speaking
                        if !queuedFirstSpeech {
                            queuedFirstSpeech = true
                            trace.mark("first_tts_clause_queued", detail: "chars=\(finalClause.count)")
                        }
                        await playbackQueue.enqueue(finalClause)
                    }
                    try await playbackQueue.flush()
                    statusText = "Done"
                    state = .done
                    try? RomeoAudioSession.deactivateNotifyingOthers()
                }
            } catch is CancellationError {
                trace.mark("voice_cancelled")
            } catch {
                trace.mark("voice_failed", detail: error.localizedDescription)
                await playbackQueue.stop()
                statusText = "Error"
                state = .failed(error.localizedDescription)
                try? RomeoAudioSession.deactivateNotifyingOthers()
            }
        }
    }

    private func extractCompletedClauses(from pendingSpeech: inout String) -> [String] {
        var clauses: [String] = []

        while let boundary = Self.sentenceBoundaryIndex(in: pendingSpeech) {
            let clause = String(pendingSpeech[...boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clause.isEmpty {
                clauses.append(clause)
            }
            pendingSpeech = String(pendingSpeech[pendingSpeech.index(after: boundary)...])
        }

        // Safety valve: if a single run gets very long with no sentence break
        // (e.g. a long comma-separated list), break at the last space so playback
        // can start — at a space, never inside a number.
        if pendingSpeech.count > 220,
           let space = pendingSpeech.lastIndex(of: " ") {
            let clause = String(pendingSpeech[..<space])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clause.isEmpty {
                clauses.append(clause)
            }
            pendingSpeech = String(pendingSpeech[pendingSpeech.index(after: space)...])
        }

        return clauses
    }

    /// The index (inclusive) of the end of the first complete sentence in `text`,
    /// or `nil` if there is no confirmed sentence break yet.
    ///
    /// A break is a newline, or one of `.`/`!`/`?` immediately followed by
    /// whitespace. Requiring trailing whitespace keeps `10:00`, `3.5`, and `a.m.`
    /// whole, and `:`/`;`/`,` are deliberately not breaks — so times, decimals, and
    /// list items go to TTS as one piece instead of being split into choppy spurts.
    static func sentenceBoundaryIndex(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                return index
            }
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isWhitespace {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    func clausesForTesting(_ text: String) -> [String] {
        var buffer = text
        return extractCompletedClauses(from: &buffer)
    }

    func combinedTranscriptForTesting(accumulated: String, update: String) -> String {
        StreamingTranscriptState.combinedTranscript(accumulated: accumulated, update: update)
    }

    func streamingTranscriptForTesting(_ updates: [TranscriptionUpdate]) -> [String] {
        var state = StreamingTranscriptState()
        return updates.map { update in
            guard !update.didStart else {
                return state.current
            }
            return state.apply(update)
        }
    }
}

private struct StreamingTranscriptState {
    private var finalizedTranscript = ""
    private var volatileTranscript = ""

    var current: String {
        Self.combinedTranscript(
            accumulated: finalizedTranscript,
            update: volatileTranscript
        )
    }

    mutating func apply(_ update: TranscriptionUpdate) -> String {
        let trimmedUpdate = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if update.isFinal {
            finalizedTranscript = Self.combinedTranscript(
                accumulated: finalizedTranscript,
                update: trimmedUpdate
            )
            volatileTranscript = ""
        } else {
            volatileTranscript = trimmedUpdate
        }

        return current
    }

    static func combinedTranscript(accumulated: String, update: String) -> String {
        let trimmedAccumulated = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdate = update.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAccumulated.isEmpty else {
            return trimmedUpdate
        }

        guard !trimmedUpdate.isEmpty else {
            return trimmedAccumulated
        }

        if trimmedUpdate.hasPrefix(trimmedAccumulated) {
            return trimmedUpdate
        }

        let overlap = suffixPrefixOverlap(accumulated: trimmedAccumulated, update: trimmedUpdate)
        if overlap > 0 {
            let remainderStart = trimmedUpdate.index(trimmedUpdate.startIndex, offsetBy: overlap)
            return trimmedAccumulated + String(trimmedUpdate[remainderStart...])
        }

        return "\(trimmedAccumulated) \(trimmedUpdate)"
    }

    private static func suffixPrefixOverlap(accumulated: String, update: String) -> Int {
        let maxLength = min(accumulated.count, update.count)
        guard maxLength > 0 else {
            return 0
        }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let accumulatedSuffix = accumulated.suffix(length)
            let updatePrefix = update.prefix(length)
            if accumulatedSuffix.caseInsensitiveCompare(updatePrefix) == .orderedSame {
                return length
            }
        }

        return 0
    }
}
