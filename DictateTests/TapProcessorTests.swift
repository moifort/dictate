import AVFoundation
import Testing
@testable import Dictate

struct TapProcessorTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private func buffer(_ value: Float) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        let channel = try #require(buffer.floatChannelData)[0]
        for frame in 0..<1_024 { channel[frame] = value }
        return buffer
    }

    private func makeProcessor() throws -> (TapProcessor, AVAudioNodeTapBlock) {
        let processor = try TapProcessor(inputFormat: format, onSpectrum: { _ in })
        return (processor, processor.makeBlock())
    }

    /// A Bluetooth headset switching to its call profile hands over digital
    /// silence for seconds: it is not the microphone hearing the room yet.
    @Test func digitalSilenceIsNotASignal() async throws {
        let (processor, block) = try makeProcessor()
        block(try buffer(0), AVAudioTime(hostTime: 0))

        let heard = await processor.waitForSignal(within: .milliseconds(50))

        #expect(!heard)
    }

    @Test func theFirstBufferWithSoundEndsTheWait() async throws {
        let (processor, block) = try makeProcessor()
        block(try buffer(0), AVAudioTime(hostTime: 0))
        let sound = try buffer(0.001)

        let waiting = Task { await processor.waitForSignal(within: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        block(sound, AVAudioTime(hostTime: 0))

        #expect(await waiting.value)
    }

    @Test func soundHeardBeforeTheWaitReturnsAtOnce() async throws {
        let (processor, block) = try makeProcessor()
        block(try buffer(0.001), AVAudioTime(hostTime: 0))

        #expect(await processor.waitForSignal(within: .seconds(10)))
    }

    /// The key released while the headset switches: nothing left to wait for.
    @Test func cancellingEndsTheWait() async throws {
        let (processor, _) = try makeProcessor()

        let waiting = Task { await processor.waitForSignal(within: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()

        #expect(await waiting.value == false)
    }
}
