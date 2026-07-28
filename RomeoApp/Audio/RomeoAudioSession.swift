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

    static func configureForCue() throws {
        startRouteChangeLoggingIfNeeded()
        startInterruptionLoggingIfNeeded()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
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

protocol RomeoCuePlaying: Sendable {
    func playActivationCue() async
    func playSubmissionCue() async
}

actor RomeoCuePlayer: RomeoCuePlaying {
    func playActivationCue() async {
        // Listening immediately reconfigures this active session. Keeping it
        // active avoids a brief full-volume music pop between cue and mic.
        await play(ringCount: 1, deactivateAfterPlayback: false)
    }

    func playSubmissionCue() async {
        await play(ringCount: 2, deactivateAfterPlayback: true)
    }

    private func play(ringCount: Int, deactivateAfterPlayback: Bool) async {
        let sampleRate = 44_100.0
        let fundamental = 660.0
        let toneDuration = 0.32
        let gapDuration = 0.10
        let tailDuration = 0.04
        let totalDuration = Double(ringCount) * toneDuration
            + Double(max(0, ringCount - 1)) * gapDuration
            + tailDuration

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalDuration * sampleRate)
        ),
        let samples = buffer.floatChannelData?[0]
        else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = 0
        }

        for toneIndex in 0..<ringCount {
            let startTime = Double(toneIndex) * (toneDuration + gapDuration)
            let startFrame = Int(startTime * sampleRate)
            let toneFrames = Int(toneDuration * sampleRate)

            for offset in 0..<toneFrames {
                let elapsed = Double(offset) / sampleRate
                let attack = min(1, elapsed / 0.004)
                let envelope = attack * exp(-8 * elapsed)
                let phase = 2 * Double.pi * fundamental * elapsed
                let metallicTone = 0.62 * sin(phase)
                    + 0.20 * sin(phase * 2.01)
                    + 0.11 * sin(phase * 2.72)
                    + 0.07 * sin(phase * 4.13)
                samples[startFrame + offset] = Float(0.76 * envelope * metallicTone)
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var shouldDeactivate = deactivateAfterPlayback

        do {
            try RomeoAudioSession.configureForCue()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack,
                completionHandler: nil
            )
            player.play()
            try await Task.sleep(for: .seconds(totalDuration + 0.08))
        } catch is CancellationError {
            // A cancelled turn should stop its cue immediately and quietly.
            shouldDeactivate = true
        } catch {
            shouldDeactivate = true
            AppTimingLogger.fullRomeo.error(
                "audio_cue_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }

        player.stop()
        engine.stop()
        if shouldDeactivate {
            try? RomeoAudioSession.deactivateNotifyingOthers()
        }
    }
}
