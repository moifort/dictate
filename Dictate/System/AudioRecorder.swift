@preconcurrency import AVFoundation
import Observation

/// Records the default microphone into memory as 16 kHz mono samples.
@Observable
final class AudioRecorder: AudioRecording {
    /// Recent input level in 0...1, for the recording indicator.
    private(set) var level: Float = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var tap: TapProcessor?

    enum RecorderError: LocalizedError {
        case noInputDevice

        var errorDescription: String? { "Aucun micro disponible." }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let processor = try TapProcessor(inputFormat: format) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        tap = processor
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: processor.makeBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tap = nil
            throw error
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        defer { tap = nil }
        return tap?.drain() ?? []
    }
}

/// Runs on the audio thread: resamples each buffer and accumulates samples.
nonisolated final class TapProcessor: @unchecked Sendable {
    private let resampler: AudioResampler
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothedLevel: Float = 0

    init(inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        resampler = try AudioResampler(inputFormat: inputFormat)
        self.onLevel = onLevel
    }

    func makeBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in process(buffer) }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let level = AudioAnalysis.meterLevel(rms: (sum / Float(chunk.count)).squareRoot())
        // Rises instantly, falls over a few buffers: the meter breathes instead of flickering.
        smoothedLevel = max(level, smoothedLevel * 0.8)
        onLevel(smoothedLevel)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }
}

/// Converts PCM buffers of any format to 16 kHz mono Float32.
nonisolated final class AudioResampler: @unchecked Sendable {
    enum ResamplerError: Error { case unsupportedFormat }

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioAnalysis.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw ResamplerError.unsupportedFormat
        }
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Reads a whole audio file as 16 kHz mono samples.
    static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        return try AudioResampler(inputFormat: file.processingFormat).convert(buffer)
    }
}
