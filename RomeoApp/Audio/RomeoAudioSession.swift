import AVFoundation
import Foundation

enum RomeoAudioSessionError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is off for Romeo."
        }
    }
}

enum RomeoAudioSession {
    static let didBeginInterruptionNotification = Notification.Name("romeo.audio.interruption.began")

    nonisolated(unsafe) private static var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private static var interruptionObserver: NSObjectProtocol?

    static func ensureRecordPermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw RomeoAudioSessionError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            if !granted {
                throw RomeoAudioSessionError.microphonePermissionDenied
            }
        @unknown default:
            return
        }
    }

    static func configureForListening() throws {
        startRouteChangeLoggingIfNeeded()
        startInterruptionLoggingIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .duckOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    static func configureForPlayback() throws {
        startRouteChangeLoggingIfNeeded()
        startInterruptionLoggingIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    static func deactivateNotifyingOthers() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func startRouteChangeLoggingIfNeeded() {
        guard routeChangeObserver == nil else {
            return
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            AppTimingLogger.fullRomeo.info(
                "audio_route_changed reason=\(String(describing: reason), privacy: .public)"
            )
        }
    }

    private static func startInterruptionLoggingIfNeeded() {
        guard interruptionObserver == nil else {
            return
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) ?? .began
            AppTimingLogger.fullRomeo.info(
                "audio_interruption type=\(String(describing: type), privacy: .public)"
            )

            if type == .began {
                NotificationCenter.default.post(
                    name: RomeoAudioSession.didBeginInterruptionNotification,
                    object: nil
                )
            }
        }
    }
}
