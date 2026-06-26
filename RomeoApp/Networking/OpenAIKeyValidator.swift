import Foundation

struct OpenAIKeyValidator {
    var session: URLSession = .shared

    func validate(apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveRealtimeError.providerError("OpenAI returned an unexpected response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = body.isEmpty ? "OpenAI returned HTTP \(httpResponse.statusCode)." : body
            throw LiveRealtimeError.providerError(message)
        }
    }
}
