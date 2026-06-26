@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(iOS 26.0, *)
final class AppleSpeechAnalyzerTranscriber: Transcriber, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let duckingLevel: RomeoDuckingLevel
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    init(duckingLevel: RomeoDuckingLevel = .max) {
        self.duckingLevel = duckingLevel
    }

    func start() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await RomeoAudioSession.ensureRecordPermission()
                    try RomeoAudioSession.configureForListening()

                    let transcriber = SpeechTranscriber(
                        locale: Locale.current,
                        preset: .progressiveTranscription
                    )
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    self.analyzer = analyzer

                    let inputNode = engine.inputNode
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false,
                            duckingLevel: duckingLevel.avAudioLevel
                        )
                    let inputFormat = inputNode.outputFormat(forBus: 0)
                    let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [transcriber],
                        considering: inputFormat
                    ) ?? inputFormat

                    try await analyzer.prepareToAnalyze(in: analysisFormat)

                    let inputStream = AsyncStream<AnalyzerInput> { inputContinuation in
                        self.inputContinuation = inputContinuation
                    }

                    resultsTask = Task {
                        do {
                            for try await result in transcriber.results {
                                let text = String(result.text.characters)
                                continuation.yield(
                                    TranscriptionUpdate(text: text, isFinal: result.isFinal)
                                )
                            }
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }

                    analysisTask = Task {
                        do {
                            try await analyzer.start(inputSequence: inputStream)
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }

                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                        let converted = self.convert(buffer: buffer, from: inputFormat, to: analysisFormat)
                        self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
                    }

                    engine.prepare()
                    try engine.start()
                    continuation.yield(.started)
                } catch {
                    continuation.finish(throwing: error)
                    await stop()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.stop()
                }
            }
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await analyzer.cancelAndFinishNow()
        }

        analyzer = nil
        analysisTask?.cancel()
        analysisTask = nil
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        guard inputFormat != outputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            return buffer
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return buffer
        }

        let inputProvider = AppleAudioConverterInputProvider(buffer: buffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            inputProvider.nextBuffer(status: status)
        }

        return error == nil ? outputBuffer : buffer
    }
}

private final class AppleAudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            status.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
