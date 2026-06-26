import Foundation

struct LiveTranscriptRequest: Encodable, Equatable {
    let transcript: String
}

struct LiveTranscriptResponse: Decodable, Equatable {
    let status: String
}

enum LiveRealtimeEvent: Equatable {
    case connected
    case userTranscript(String)
    case assistantTranscript(String)
    case error(String)
    case ended
}

enum LiveRealtimeError: LocalizedError, Equatable {
    case missingAPIKey
    case connectionTimedOut
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Enter an OpenAI API key."
        case .connectionTimedOut:
            "OpenAI realtime did not connect within 20 seconds."
        case .providerError(let message):
            message
        }
    }
}
