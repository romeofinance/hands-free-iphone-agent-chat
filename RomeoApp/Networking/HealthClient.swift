import Foundation

enum HealthClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter a valid agent Tailnet URL."
        case .invalidResponse:
            "The agent service returned an unexpected response."
        case .serverStatus(let code):
            "The agent service returned HTTP \(code)."
        }
    }
}

struct HealthClient {
    var session: URLSession = .shared

    func checkHealth(baseURL rawBaseURL: String) async throws -> HealthResponse {
        let request = try makeHealthRequest(baseURL: rawBaseURL)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HealthClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HealthClientError.serverStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw HealthClientError.invalidResponse
        }
    }

    func makeHealthRequest(baseURL rawBaseURL: String) throws -> URLRequest {
        let url: URL
        do {
            url = try MiniURLBuilder.url(baseURL: rawBaseURL, path: "/health")
        } catch {
            throw HealthClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }
}
