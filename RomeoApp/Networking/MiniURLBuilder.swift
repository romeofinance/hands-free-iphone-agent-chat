import Foundation

enum MiniURLBuilder {
    static func url(baseURL rawBaseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme,
              scheme == "https" || components.host == "localhost" || components.host == "127.0.0.1"
        else {
            throw MiniClientError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = [basePath, routePath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/" + components.path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MiniClientError.invalidBaseURL
        }

        return url
    }
}

enum MiniClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case serverStatus(Int)
    case streamError(String)
    case invalidStreamEvent(event: String, data: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter a valid agent Tailnet URL."
        case .invalidResponse:
            "The agent service returned an unexpected response."
        case .serverStatus(let code):
            "The agent service returned HTTP \(code)."
        case .streamError(let message):
            message
        case .invalidStreamEvent(let event, let data):
            "Could not read \(event) stream event: \(data)"
        }
    }
}
