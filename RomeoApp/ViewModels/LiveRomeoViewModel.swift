import Foundation
import Observation

@MainActor
@Observable
final class LiveRomeoViewModel {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case postingTranscript
        case done
        case failed(String)
    }

    var state: State = .idle
    var statusText = "Idle"
    var transcript = ""
    var latestUserText = ""
    var latestRomeoText = ""
    var transcriptPostStatusText = ""

    private let makeRealtimeSession: @MainActor () -> any LiveRealtimeSessioning
    private let transcriptClient: any LiveTranscriptPosting
    private let cuePlayer: any RomeoCuePlaying
    private var realtimeSession: (any LiveRealtimeSessioning)?
    private var sessionTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var transcriptLines: [String] = []

    init(
        makeRealtimeSession: @escaping @MainActor () -> any LiveRealtimeSessioning = {
            LiveRealtimeOpenAISession()
        },
        transcriptClient: any LiveTranscriptPosting = LiveTranscriptClient(),
        cuePlayer: any RomeoCuePlaying = RomeoCuePlayer()
    ) {
        self.makeRealtimeSession = makeRealtimeSession
        self.transcriptClient = transcriptClient
        self.cuePlayer = cuePlayer
    }

    var canStart: Bool {
        sessionTask == nil && restartTask == nil
    }

    func start(baseURL: String, openAIAPIKey: String, duckingLevel: RomeoDuckingLevel = .max) {
        guard canStart else {
            if let activeTurnID {
                TimingTrace(operation: "live_romeo", turnID: activeTurnID).mark("start_reset_in_flight")
            }
            restart(baseURL: baseURL, openAIAPIKey: openAIAPIKey, duckingLevel: duckingLevel)
            return
        }

        let apiKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            state = .failed(LiveRealtimeError.missingAPIKey.localizedDescription)
            statusText = "Error"
            return
        }

        let turnID = UUID()
        activeTurnID = turnID
        let trace = TimingTrace(operation: "live_romeo", turnID: turnID)
        trace.mark("live_start_requested", detail: "duck=\(duckingLevel.rawValue)")

        transcript = ""
        latestUserText = ""
        latestRomeoText = ""
        transcriptPostStatusText = ""
        transcriptLines = []
        statusText = "Connecting"
        state = .connecting

        sessionTask = Task {
            defer {
                if activeTurnID == turnID {
                    sessionTask = nil
                    if state != .postingTranscript {
                        activeTurnID = nil
                    }
                }
            }

            trace.mark("activation_cue_started")
            await cuePlayer.playActivationCue()
            trace.mark("activation_cue_finished")
            guard activeTurnID == turnID, state == .connecting, !Task.isCancelled else {
                return
            }

            let session = makeRealtimeSession()
            realtimeSession = session
            let events = session.start(apiKey: apiKey, duckingLevel: duckingLevel)

            for await event in events {
                guard activeTurnID == turnID else {
                    return
                }

                switch event {
                case .connected:
                    trace.mark("live_connected")
                    statusText = "Live"
                    state = .live
                case .userTranscript(let text):
                    handleUserTranscript(text, baseURL: baseURL, turnID: turnID, trace: trace)
                    if state == .postingTranscript || state == .done || isFailed {
                        return
                    }
                case .assistantTranscript(let text):
                    appendAssistantTranscript(text)
                case .error(let message):
                    trace.mark("live_failed", detail: message)
                    statusText = "Error"
                    state = .failed(message)
                    await session.stop()
                    try? RomeoAudioSession.deactivateNotifyingOthers()
                    return
                case .ended:
                    trace.mark("live_ended")
                    return
                }
            }
        }
    }

    func stop(baseURL: String) {
        guard let turnID = activeTurnID else {
            if restartTask != nil {
                cancel()
            }
            return
        }

        let trace = TimingTrace(operation: "live_romeo", turnID: turnID)
        trace.mark("stop_tapped")
        scheduleFinish(baseURL: baseURL, turnID: turnID, trace: trace, settleTranscript: true)
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        let turnID = activeTurnID
        if let turnID {
            TimingTrace(operation: "live_romeo", turnID: turnID).mark("cancel_tapped_no_transcript_post")
        }

        sessionTask?.cancel()
        sessionTask = nil
        restartTask?.cancel()
        restartTask = nil
        finishTask?.cancel()
        finishTask = nil
        let session = realtimeSession
        realtimeSession = nil
        activeTurnID = nil
        statusText = "Cancelled"
        state = .idle

        return Task {
            await session?.stop()
            try? RomeoAudioSession.deactivateNotifyingOthers()
        }
    }

    func restart(baseURL: String, openAIAPIKey: String, duckingLevel: RomeoDuckingLevel = .max) {
        let cleanup = cancel()
        restartTask = Task {
            await cleanup.value
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            restartTask = nil
            start(baseURL: baseURL, openAIAPIKey: openAIAPIKey, duckingLevel: duckingLevel)
        }
    }

    private var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private func handleUserTranscript(
        _ rawText: String,
        baseURL: String,
        turnID: UUID,
        trace: TimingTrace
    ) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        latestUserText = trimmed
        if RomeoCommandDetector.isDonePhraseOnly(trimmed) {
            trace.mark("done_phrase_detected", detail: "bare_command")
            scheduleFinish(baseURL: baseURL, turnID: turnID, trace: trace)
        } else if let stripped = RomeoCommandDetector.textByStrippingDonePhrase(from: trimmed) {
            let finalUserText = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalUserText.isEmpty {
                appendLine("User", finalUserText)
            }
            trace.mark("done_phrase_detected", detail: "suffix_command")
            scheduleFinish(baseURL: baseURL, turnID: turnID, trace: trace)
        } else {
            appendLine("User", trimmed)
        }
    }

    private func appendAssistantTranscript(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        latestRomeoText = trimmed
        appendLine("Romeo", trimmed)
    }

    private func appendLine(_ role: String, _ text: String) {
        let line = "\(role): \(text)"
        guard transcriptLines.last != line else {
            return
        }

        transcriptLines.append(line)
        transcript = transcriptLines.joined(separator: "\n")
    }

    private func scheduleFinish(
        baseURL: String,
        turnID: UUID,
        trace: TimingTrace,
        settleTranscript: Bool = false
    ) {
        guard finishTask == nil else {
            return
        }

        finishTask = Task {
            defer {
                finishTask = nil
            }

            if settleTranscript {
                trace.mark("manual_end_settling_transcript")
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }

            guard activeTurnID == turnID, !Task.isCancelled else {
                return
            }
            await finish(baseURL: baseURL, turnID: turnID, trace: trace)
        }
    }

    private func finish(baseURL: String, turnID: UUID, trace: TimingTrace) async {
        // Idempotent: a manual stop and an end-phrase (or two end-phrase
        // transcripts) can both reach finish(). state flips to .postingTranscript
        // synchronously before the first await, so any later caller bails here
        // and the transcript is posted exactly once.
        guard activeTurnID == turnID, state != .postingTranscript, state != .done else {
            return
        }

        statusText = "Posting transcript"
        transcriptPostStatusText = "Posting live transcript..."
        state = .postingTranscript
        await realtimeSession?.stop()
        realtimeSession = nil
        try? RomeoAudioSession.deactivateNotifyingOthers()
        trace.mark("submission_cue_started")
        await cuePlayer.playSubmissionCue()
        trace.mark("submission_cue_finished")
        guard activeTurnID == turnID, !Task.isCancelled else {
            return
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trace.mark("live_transcript_skipped_empty")
            transcriptPostStatusText = "No live transcript to post."
            statusText = "Done"
            state = .done
            sessionTask?.cancel()
            sessionTask = nil
            activeTurnID = nil
            return
        }

        do {
            trace.mark("posting_live_transcript", detail: "chars=\(transcript.count) base_url=\(baseURL)")
            try await transcriptClient.postLiveTranscript(baseURL: baseURL, transcript: transcript)
            trace.mark("live_transcript_posted")
            transcriptPostStatusText = "Live transcript posted."
            statusText = "Done"
            state = .done
            sessionTask?.cancel()
            sessionTask = nil
            activeTurnID = nil
        } catch {
            trace.mark("post_live_transcript_failed", detail: error.localizedDescription)
            transcriptPostStatusText = "Live transcript post failed: \(error.localizedDescription)"
            statusText = "Error"
            state = .failed(error.localizedDescription)
            sessionTask?.cancel()
            sessionTask = nil
            activeTurnID = nil
        }
    }
}
