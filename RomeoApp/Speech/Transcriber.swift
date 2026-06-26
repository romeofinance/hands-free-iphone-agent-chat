import Foundation

struct TranscriptionUpdate: Sendable, Equatable {
    let text: String
    let isFinal: Bool
    let didStart: Bool

    init(text: String, isFinal: Bool, didStart: Bool = false) {
        self.text = text
        self.isFinal = isFinal
        self.didStart = didStart
    }

    static let started = TranscriptionUpdate(text: "", isFinal: false, didStart: true)
}

protocol Transcriber: Sendable {
    func start() -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func stop() async
}
