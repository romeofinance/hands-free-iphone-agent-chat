import Foundation
import Observation

@MainActor
@Observable
final class FullRomeoViewModel {
    enum State: Equatable {
        case idle
        case streaming
        case done
        case failed(String)
    }

    var state: State = .idle
    var turnID: UUID?
    var replyText = ""
    var statusText = "Idle"
    var transportText = "Gateway"

    private let client: any FullRomeoStreaming
    private var streamTask: Task<Void, Never>?

    init(client: any FullRomeoStreaming = FullRomeoClient()) {
        self.client = client
    }

    var canSend: Bool {
        state != .streaming && streamTask == nil
    }

    func send(text: String, baseURL: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            state = .failed("Type a message before sending.")
            return
        }

        guard canSend else {
            if let turnID {
                TimingTrace(operation: "full_romeo_ui", turnID: turnID).mark("send_ignored_in_flight")
            }
            return
        }

        let id = UUID()
        let trace = TimingTrace(operation: "full_romeo_ui", turnID: id)
        trace.mark("send_started", detail: "text_chars=\(trimmedText.count)")

        turnID = id
        replyText = ""
        statusText = "Thinking..."
        transportText = "Gateway"
        state = .streaming

        streamTask = Task {
            defer {
                if turnID == id {
                    streamTask = nil
                    if state != .streaming {
                        turnID = nil
                    }
                }
            }

            do {
                for try await event in client.streamFullRomeo(
                    baseURL: baseURL,
                    text: trimmedText,
                    source: "tap"
                ) {
                    guard turnID == id else {
                        return
                    }

                    switch event {
                    case .status(let value):
                        trace.mark("ui_status", detail: value)
                        switch value {
                        case "thinking":
                            statusText = "Thinking..."
                        case "using_cli_fallback":
                            trace.mark("transport_detected", detail: "transport=cli_fallback")
                            transportText = "CLI fallback"
                        case "done":
                            statusText = "Done"
                            state = .done
                        default:
                            trace.mark("unknown_status_ignored", detail: value)
                        }
                    case .text(let delta):
                        trace.mark("ui_text_delta", detail: "chars=\(delta.count)")
                        replyText += delta
                    case .error(let message):
                        trace.mark("ui_error_event", detail: message)
                        statusText = "Error"
                        state = .failed(message)
                    }
                }

                guard turnID == id else {
                    return
                }

                if state == .streaming {
                    trace.mark("ui_stream_completed")
                    state = .done
                    statusText = "Done"
                }
            } catch is CancellationError {
                guard turnID == id else {
                    return
                }

                trace.mark("ui_cancelled")
                statusText = "Cancelled"
                state = .idle
            } catch {
                guard turnID == id else {
                    return
                }

                trace.mark("ui_failed", detail: error.localizedDescription)
                statusText = "Error"
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        let id = turnID
        if let id {
            TimingTrace(operation: "full_romeo_ui", turnID: id).mark("cancel_tapped")
        }

        streamTask?.cancel()
        streamTask = nil
        state = .idle
        statusText = "Cancelled"
        turnID = nil
    }

}
