import Foundation
import OSLog

protocol LiveTranscriptPosting: Sendable {
    func postLiveTranscript(baseURL: String, transcript: String) async throws
}

struct LiveTranscriptClient {
    var session: URLSession = .shared
    var encoder = JSONEncoder()
    var decoder = JSONDecoder()

    func makeLiveTranscriptRequest(
        baseURL rawBaseURL: String,
        transcript: String
    ) throws -> URLRequest {
        let url = try MiniURLBuilder.url(baseURL: rawBaseURL, path: "/voice/live-transcript")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(LiveTranscriptRequest(transcript: transcript))

        return request
    }

    func postLiveTranscript(baseURL: String, transcript: String) async throws {
        let request = try makeLiveTranscriptRequest(baseURL: baseURL, transcript: transcript)
        let start = ContinuousClock.now
        let url = request.url?.absoluteString ?? "<missing-url>"
        AppTimingLogger.liveTranscript.info(
            "live_transcript.request url=\(url, privacy: .public) chars=\(transcript.count, privacy: .public)"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            AppTimingLogger.liveTranscript.error(
                "live_transcript.invalid_response url=\(url, privacy: .public)"
            )
            throw MiniClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let elapsed = Self.elapsedMilliseconds(since: start)
            AppTimingLogger.liveTranscript.error(
                "live_transcript.http_error url=\(url, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public) body_bytes=\(data.count, privacy: .public)"
            )
            throw MiniClientError.serverStatus(httpResponse.statusCode)
        }

        let decoded = try decoder.decode(LiveTranscriptResponse.self, from: data)
        guard decoded.status == "ok" else {
            AppTimingLogger.liveTranscript.error(
                "live_transcript.bad_body url=\(url, privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
            )
            throw MiniClientError.invalidResponse
        }

        let elapsed = Self.elapsedMilliseconds(since: start)
        AppTimingLogger.liveTranscript.info(
            "live_transcript.success url=\(url, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds * 1_000)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

extension LiveTranscriptClient: LiveTranscriptPosting, @unchecked Sendable {}
