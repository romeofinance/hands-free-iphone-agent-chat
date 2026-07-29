import Foundation

protocol FullRomeoStreaming: Sendable {
    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error>
}

struct FullRomeoClient {
    var session: URLSession = .shared
    var decoder: JSONDecoder = JSONDecoder()
    var encoder: JSONEncoder = JSONEncoder()
    /// Idle timeout for the agent request. The agent can take a long time to think
    /// before it starts streaming a reply, and URLSession's default is only 60s.
    /// This is an *idle* timeout — it resets every time a byte (a status or text
    /// event) arrives — so a long initial "thinking" pause no longer trips it.
    var requestTimeout: TimeInterval = 300

    func makeFullRomeoRequest(
        baseURL rawBaseURL: String,
        text: String,
        source: String = "tap"
    ) throws -> URLRequest {
        let url = try MiniURLBuilder.url(baseURL: rawBaseURL, path: "/voice/full-romeo")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = FullRomeoRequest(
            text: text,
            modeMetadata: .init(source: source)
        )
        request.httpBody = try encoder.encode(body)

        return request
    }

    func streamFullRomeo(
        baseURL: String,
        text: String,
        source: String = "tap"
    ) -> AsyncThrowingStream<FullRomeoStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let trace = TimingTrace(operation: "full_romeo_stream", turnID: UUID())
                trace.mark("stream_task_started", detail: "text_chars=\(text.count)")

                do {
                    let request = try makeFullRomeoRequest(
                        baseURL: baseURL,
                        text: text,
                        source: source
                    )

                    trace.mark("request_built", detail: request.url?.absoluteString ?? "missing_url")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        trace.mark("invalid_response")
                        throw MiniClientError.invalidResponse
                    }

                    trace.mark("response_headers", detail: "status=\(httpResponse.statusCode)")
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw MiniClientError.serverStatus(httpResponse.statusCode)
                    }

                    var parser = SSEParser()
                    var sawFirstText = false
                    for try await line in bytes.lines {
                        for message in parser.parse(line: line) {
                            trace.mark(
                                "sse_event",
                                detail: "event=\(message.event) data_bytes=\(message.data.utf8.count)"
                            )

                            if message.event == "text", !sawFirstText {
                                sawFirstText = true
                                trace.mark("first_text_delta")
                            }

                            if try yield(message: message, to: continuation) {
                                trace.mark("terminal_done")
                                continuation.finish()
                                return
                            }
                        }
                    }

                    if let message = parser.flush() {
                        trace.mark(
                            "sse_event",
                            detail: "event=\(message.event) data_bytes=\(message.data.utf8.count) source=final_flush"
                        )
                        _ = try yield(message: message, to: continuation)
                    }

                    trace.mark("stream_finished")
                    continuation.finish()
                } catch {
                    trace.mark("stream_failed", detail: error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                AppTimingLogger.fullRomeo.info(
                    "full_romeo_stream event=stream_terminated"
                )
                task.cancel()
            }
        }
    }

    private func yield(
        message: SSEMessage,
        to continuation: AsyncThrowingStream<FullRomeoStreamEvent, Error>.Continuation
    ) throws -> Bool {
        guard let event = try streamEvent(from: message) else {
            return false
        }

        continuation.yield(event)

        if case .error(let message) = event {
            throw MiniClientError.streamError(message)
        }

        if case .status("done") = event {
            return true
        }

        return false
    }

    func streamEvent(from message: SSEMessage) throws -> FullRomeoStreamEvent? {
        let data = Data(message.data.utf8)

        switch message.event {
        case "status":
            do {
                let payload = try decoder.decode(FullRomeoStatusPayload.self, from: data)
                return .status(payload.value)
            } catch {
                throw MiniClientError.invalidStreamEvent(event: message.event, data: message.data)
            }
        case "text":
            do {
                let payload = try decoder.decode(FullRomeoTextPayload.self, from: data)
                return .text(payload.delta)
            } catch {
                throw MiniClientError.invalidStreamEvent(event: message.event, data: message.data)
            }
        case "error":
            do {
                let payload = try decoder.decode(FullRomeoErrorPayload.self, from: data)
                return .error(payload.message)
            } catch {
                throw MiniClientError.invalidStreamEvent(event: message.event, data: message.data)
            }
        default:
            return nil
        }
    }
}

extension FullRomeoClient: FullRomeoStreaming, @unchecked Sendable {}
