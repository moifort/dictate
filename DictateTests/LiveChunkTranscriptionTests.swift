import Foundation
import Testing
@testable import Dictate

struct LiveChunkTranscriptionTests {
    private let rate = AudioAnalysis.sampleRate

    private func audio(_ parts: (seconds: Double, speech: Bool)...) -> [Float] {
        parts.flatMap { part in
            let count = Int(part.seconds * Double(rate))
            return (0..<count).map { part.speech ? ($0.isMultiple(of: 2) ? Float(0.3) : Float(-0.3)) : Float(0.001) }
        }
    }

    private func makeLive(engine: FakeEngine) async -> LiveChunkTranscription {
        let live = LiveChunkTranscription(engine: engine, vocabulary: ["push"], pollInterval: .milliseconds(10), minimumSpeech: 1)
        await live.start()
        return live
    }

    @Test(.timeLimit(.minutes(1))) func everythingInOnePassWithoutPauses() async throws {
        let engine = FakeEngine()
        let live = await makeLive(engine: engine)
        live.append(audio((2, true)))
        let text = try await live.finish()
        #expect(text == "chunk1")
        #expect(engine.chunks.map(\.count) == [2 * rate])
        #expect(engine.vocabularies == [["push"]])
    }

    @Test(.timeLimit(.minutes(1))) func speechBeforeAPauseIsDecodedWhileRecording() async throws {
        let engine = FakeEngine()
        let live = await makeLive(engine: engine)
        live.append(audio((2, true), (0.6, false)))
        try await engine.waitForCalls(1)
        live.append(audio((1, true)))
        let text = try await live.finish()
        #expect(text == "chunk1 chunk2")
        #expect(engine.chunks.map(\.count) == [Int(2.5 * Double(rate)), Int(1.1 * Double(rate))])
    }

    @Test(.timeLimit(.minutes(1))) func silentTailIsNotDecoded() async throws {
        let engine = FakeEngine()
        let live = await makeLive(engine: engine)
        live.append(audio((2, true), (0.6, false)))
        try await engine.waitForCalls(1)
        live.append(audio((1, false)))
        let text = try await live.finish()
        #expect(text == "chunk1")
        #expect(engine.chunks.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func passInFlightOnFinishIsDroppedAndRedone() async throws {
        let engine = FakeEngine(delay: .seconds(10))
        let live = await makeLive(engine: engine)
        live.append(audio((2, true), (0.6, false)))
        try await engine.waitForCalls(1)
        live.append(audio((1, true)))
        engine.delay = .zero
        let text = try await live.finish()
        #expect(text == "chunk2")
        #expect(engine.cancelledCalls == 1)
        #expect(engine.chunks.last?.count == Int(3.6 * Double(rate)))
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsDecoding() async throws {
        let engine = FakeEngine(delay: .seconds(10))
        let live = await makeLive(engine: engine)
        live.append(audio((2, true), (0.6, false)))
        try await engine.waitForCalls(1)
        live.cancel()
        try await engine.waitForCancelledCalls(1)
        live.append(audio((2, true), (0.6, false)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.chunks.count == 1)
    }
}

private final class FakeEngine: ChunkTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [[Float]] = []
    private var _vocabularies: [[String]] = []
    private var _cancelled = 0
    private var _delay: Duration

    init(delay: Duration = .zero) { _delay = delay }

    var chunks: [[Float]] { lock.withLock { _chunks } }
    var vocabularies: [[String]] { lock.withLock { _vocabularies } }
    var cancelledCalls: Int { lock.withLock { _cancelled } }
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    func transcribe(chunk: [Float], vocabulary: [String]) async throws -> String {
        let index = lock.withLock {
            _chunks.append(chunk)
            _vocabularies.append(vocabulary)
            return _chunks.count
        }
        do {
            try await Task.sleep(for: delay)
        } catch {
            lock.withLock { _cancelled += 1 }
            throw error
        }
        return "chunk\(index)"
    }

    func waitForCalls(_ count: Int) async throws {
        while chunks.count < count { try await Task.sleep(for: .milliseconds(5)) }
    }

    func waitForCancelledCalls(_ count: Int) async throws {
        while cancelledCalls < count { try await Task.sleep(for: .milliseconds(5)) }
    }
}
