import AVFoundation
import Testing

@testable import DictateKit

struct AudioResamplerTests {
    /// A discrete nine-channel input keeps its first channel rather than going silent.
    @Test func multichannelInputKeepsOnlyTheFirstChannel() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<1_600 {
            channels[0][frame] = 0.5
            for channel in 1..<9 { channels[channel][frame] = 0 }
        }

        let samples = try AudioResampler(inputFormat: format).convert(buffer)

        #expect(samples.count == 1_600)
        #expect(samples.allSatisfy { abs($0 - 0.5) < 0.001 })
    }

    /// A Bluetooth headset switching to its call profile drops the microphone
    /// to 24 kHz while the tap runs: the buffers that follow are converted at
    /// their own rate, not at the one the recording started with.
    @Test func bufferAtAnotherRateIsConvertedAtItsOwnRate() throws {
        let started = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let switched = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: switched, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        let channel = try #require(buffer.floatChannelData)[0]
        for frame in 0..<2_400 { channel[frame] = 0.5 }

        let samples = try AudioResampler(inputFormat: started).convert(buffer)

        #expect(abs(samples.count - 1_600) <= 32)
        #expect(samples.dropFirst(64).dropLast(64).allSatisfy { abs($0 - 0.5) < 0.01 })
    }
}
