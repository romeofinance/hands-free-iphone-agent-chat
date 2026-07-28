import AppIntents
import Foundation

struct RomeoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Romeo Mode"
    static let description = IntentDescription("Start a Full Romeo voice turn.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        RomeoShortcutRequest.requestFullRomeoListening()
        return .result()
    }
}

struct RomeoLiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Romeo Live"
    static let description = IntentDescription("Start a Live Romeo conversation.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        RomeoShortcutRequest.requestLiveRomeoListening()
        return .result()
    }
}

struct RomeoStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Romeo Stop"
    static let description = IntentDescription("Stop the current Romeo session or pending reply.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        RomeoShortcutRequest.requestFullRomeoStop()
        return .result()
    }
}

struct RomeoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RomeoModeIntent(),
            phrases: [
                "\(.applicationName) mode"
            ],
            shortTitle: "Romeo Mode",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RomeoLiveIntent(),
            phrases: [
                "\(.applicationName) live"
            ],
            shortTitle: "Romeo Live",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: RomeoStopIntent(),
            phrases: [
                "\(.applicationName) stop"
            ],
            shortTitle: "Romeo Stop",
            systemImageName: "speaker.slash"
        )
    }
}
