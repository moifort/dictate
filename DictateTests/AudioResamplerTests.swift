import AVFoundation
import Testing
@testable import Dictate

struct AudioResamplerTests {
    /// Voice processing hands over nine channels; only the first carries the processed voice.
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
}
