import Foundation

/// Decodes one chunk of audio. Must honour task cancellation promptly.
nonisolated protocol ChunkTranscribing: Sendable {
    func transcribe(chunk: [Float], vocabulary: [String]) async throws -> String
}

/// Transcribes a dictation while it is being spoken.
///
/// Every Whisper pass pays a fixed price (the encoder, plus one decoder step
/// per vocabulary token) before decoding a single word, so the audio is not
/// re-decoded on every poll. Instead, each time a pause completes after enough
/// speech, everything up to that pause is decoded once, in the background,
/// while the user keeps talking. On release only the audio after the last
/// pause remains to be decoded.
actor LiveChunkTranscription: LiveTranscription {
    private let engine: any ChunkTranscribing
    private let vocabulary: [String]
    private let pollInterval: Duration
    private let minimumSpeech: Double
    private let audio = SampleBuffer()

    private var confirmed: [String] = []
    /// Everything before this index has been decoded.
    private var processedEnd = 0
    private var loop: Task<Void, Never>?
    private var pass: Task<String, Error>?
    private var finishing = false

    /// Shorter tails cannot hold a word; they are not worth a pass.
    private static let minimumTailSamples = AudioAnalysis.sampleRate * 3 / 10

    init(
        engine: any ChunkTranscribing,
        vocabulary: [String],
        pollInterval: Duration = .milliseconds(200),
        minimumSpeech: Double = 3
    ) {
        self.engine = engine
        self.vocabulary = vocabulary
        self.pollInterval = pollInterval
        self.minimumSpeech = minimumSpeech
    }

    /// Starts watching the audio for chunks to decode.
    func start() {
        guard loop == nil, !finishing else { return }
        loop = Task { await run() }
    }

    nonisolated func append(_ samples: [Float]) {
        audio.append(samples)
    }

    func finish() async throws -> String {
        finishing = true
        // A pass still in the encoder or in the vocabulary prefix would delay
        // the final pass more than it could save: drop it and decode its audio
        // together with the tail.
        pass?.cancel()
        loop?.cancel()
        await loop?.value

        let samples = audio.snapshot()
        var parts = confirmed
        let tail = Array(samples[min(processedEnd, samples.count)...])
        if tail.count >= Self.minimumTailSamples, !AudioAnalysis.isSilent(tail) {
            let start = ContinuousClock.now
            let text = try await engine.transcribe(chunk: tail, vocabulary: vocabulary)
            Log.dictation.info("final pass: \(Self.seconds(tail), format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(since: start)) ms")
            parts.append(text)
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated func cancel() {
        Task { await tearDown() }
    }

    private func tearDown() {
        finishing = true
        pass?.cancel()
        loop?.cancel()
    }

    private func run() async {
        while !finishing, !Task.isCancelled {
            let samples = audio.snapshot()
            if let boundary = AudioAnalysis.chunkBoundary(in: samples, from: processedEnd, minimumSpeech: minimumSpeech) {
                await decode(Array(samples[processedEnd..<boundary]), upTo: boundary)
            } else {
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func decode(_ chunk: [Float], upTo end: Int) async {
        let start = ContinuousClock.now
        let task = Task { [engine, vocabulary] in try await engine.transcribe(chunk: chunk, vocabulary: vocabulary) }
        pass = task
        defer { pass = nil }
        guard let text = try? await task.value else {
            Log.dictation.info("live pass dropped after \(Self.milliseconds(since: start)) ms")
            return
        }
        Log.dictation.info("live pass: \(Self.seconds(chunk), format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(since: start)) ms")
        confirmed.append(text)
        processedEnd = end
    }

    private static func seconds(_ samples: [Float]) -> Double {
        Double(samples.count) / Double(AudioAnalysis.sampleRate)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Audio appended from the capture thread and read from the decoding actor.
nonisolated final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
