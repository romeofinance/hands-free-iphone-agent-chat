import AVFAudio
import Foundation

enum RomeoDuckingLevel: String, CaseIterable, Identifiable {
    case systemDefault = "default"
    case min
    case mid
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault:
            "Default"
        case .min:
            "Min"
        case .mid:
            "Mid"
        case .max:
            "Max"
        }
    }

    var avAudioLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level {
        switch self {
        case .systemDefault:
            .default
        case .min:
            .min
        case .mid:
            .mid
        case .max:
            .max
        }
    }
}
