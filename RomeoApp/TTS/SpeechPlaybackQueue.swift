import Foundation

/// Plays a turn's clauses in order, but synthesizes upcoming clauses *ahead* of
/// playback so there is no network/synthesis gap between them.
///
/// Each clause is played strictly in enqueue order, while up to `prefetchLimit`
/// clauses are synthesized concurrently. By the time the player finishes one
/// clause, the next clause's audio is usually already in hand, so speech flows
/// continuously instead of stuttering between clauses.
actor SpeechPlaybackQueue {
    private struct PendingClause {
        let text: String
        var synth: Task<Data, Error>?
    }

    private let speaker: any TextToSpeechSpeaking
    private let prefetchLimit: Int

    private var clauses: [PendingClause] = []
    private var isPlaying = false
    private var apiKey = ""
    private var voiceID = ""
    private var generation = 0
    private var firstPlaybackError: (any Error)?

    init(speaker: any TextToSpeechSpeaking, prefetchLimit: Int = 2) {
        self.speaker = speaker
        self.prefetchLimit = max(1, prefetchLimit)
    }

    func configure(apiKey: String, voiceID: String) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        firstPlaybackError = nil
    }

    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        clauses.append(PendingClause(text: trimmed))
        startSynthesisWithinWindow()

        guard !isPlaying else {
            return
        }

        isPlaying = true
        let processingGeneration = generation
        Task {
            await playLoop(generation: processingGeneration)
        }
    }

    func flush() async throws {
        while isPlaying || !clauses.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if let firstPlaybackError {
            throw firstPlaybackError
        }
    }

    func stop() async {
        generation += 1
        for clause in clauses {
            clause.synth?.cancel()
        }
        clauses = []
        isPlaying = false
        firstPlaybackError = nil
        await speaker.stop()
    }

    /// Start synthesizing the first `prefetchLimit` clauses that don't yet have a
    /// task, so audio for upcoming clauses is fetched while earlier ones play.
    /// This is what removes the network gap between clauses.
    private func startSynthesisWithinWindow() {
        let window = min(prefetchLimit, clauses.count)
        guard window > 0 else {
            return
        }

        let speaker = self.speaker
        let key = apiKey
        let voice = voiceID
        for index in 0..<window where clauses[index].synth == nil {
            let text = clauses[index].text
            clauses[index].synth = Task {
                try await speaker.synthesize(text: text, apiKey: key, voiceID: voice)
            }
        }
    }

    private func playLoop(generation processingGeneration: Int) async {
        while processingGeneration == generation, !clauses.isEmpty {
            startSynthesisWithinWindow()
            guard let synth = clauses.first?.synth else {
                break
            }

            do {
                let audio = try await synth.value
                guard processingGeneration == generation else {
                    return
                }
                try await speaker.play(audio)
            } catch is CancellationError {
                return
            } catch {
                if firstPlaybackError == nil {
                    firstPlaybackError = error
                }
                AppTimingLogger.fullRomeo.error(
                    "tts_playback_failed detail=\(error.localizedDescription, privacy: .public)"
                )
            }

            guard processingGeneration == generation else {
                return
            }

            if !clauses.isEmpty {
                clauses.removeFirst()
            }
            // The window shifted forward; prefetch the next clause(s).
            startSynthesisWithinWindow()
        }

        if processingGeneration == generation {
            isPlaying = false
        }
    }
}
