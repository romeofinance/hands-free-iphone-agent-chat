import Foundation
import OSLog

enum AppTimingLogger {
    static let fullRomeo = Logger(subsystem: "com.example.romeo", category: "FullRomeoTiming")
    static let liveRomeo = Logger(subsystem: "com.example.romeo", category: "LiveRomeo")
    static let liveTranscript = Logger(subsystem: "com.example.romeo", category: "LiveTranscript")
}

struct TimingTrace: Sendable {
    let operation: String
    let turnID: UUID
    private let start = ContinuousClock.now

    init(operation: String, turnID: UUID) {
        self.operation = operation
        self.turnID = turnID
    }

    func mark(_ event: String, detail: String = "") {
        let duration = start.duration(to: ContinuousClock.now)
        let milliseconds = Double(duration.components.seconds * 1_000)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        let turn = turnID.uuidString

        if detail.isEmpty {
            AppTimingLogger.fullRomeo.info(
                "\(operation, privacy: .public) turn_id=\(turn, privacy: .public) elapsed_ms=\(milliseconds, format: .fixed(precision: 1), privacy: .public) event=\(event, privacy: .public)"
            )
        } else {
            AppTimingLogger.fullRomeo.info(
                "\(operation, privacy: .public) turn_id=\(turn, privacy: .public) elapsed_ms=\(milliseconds, format: .fixed(precision: 1), privacy: .public) event=\(event, privacy: .public) detail=\(detail, privacy: .public)"
            )
        }
    }
}
