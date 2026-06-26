import Foundation

struct FullRomeoRequest: Encodable, Equatable {
    struct ModeMetadata: Encodable, Equatable {
        let source: String
    }

    let text: String
    let modeMetadata: ModeMetadata

    enum CodingKeys: String, CodingKey {
        case text
        case modeMetadata = "mode_metadata"
    }
}

enum FullRomeoStreamEvent: Equatable {
    case status(String)
    case text(String)
    case error(String)
}

enum FullRomeoSTTProvider: String, CaseIterable, Identifiable {
    case elevenLabsScribe
    case appleSpeechAnalyzer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabsScribe:
            "ElevenLabs Scribe v2"
        case .appleSpeechAnalyzer:
            "Apple SpeechAnalyzer"
        }
    }

    var shortName: String {
        switch self {
        case .elevenLabsScribe:
            "Scribe v2"
        case .appleSpeechAnalyzer:
            "Apple"
        }
    }
}

struct FullRomeoStatusPayload: Decodable {
    let value: String
}

struct FullRomeoTextPayload: Decodable {
    let delta: String
}

struct FullRomeoErrorPayload: Decodable {
    let message: String
}
