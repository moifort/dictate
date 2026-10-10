import Testing
@testable import Dictate

struct AudioAnalysisTests {
    @Test func zerosAreSilent() {
        #expect(AudioAnalysis.isSilent([Float](repeating: 0, count: 16_000)))
    }

    @Test func lowNoiseIsSilent() {
        #expect(AudioAnalysis.isSilent([Float](repeating: 0.002, count: 16_000)))
    }

    @Test func shortBurstOfSpeechIsNotSilent() {
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 8_000..<9_600 { samples[i] = i.isMultiple(of: 2) ? 0.3 : -0.3 }
        #expect(!AudioAnalysis.isSilent(samples))
    }

    @Test func meterLevelFollowsADecibelScale() {
        #expect(AudioAnalysis.meterLevel(rms: 0) == 0)
        #expect(AudioAnalysis.meterLevel(rms: 0.001) < 0.05)        // -60 dB: silence
        #expect(abs(AudioAnalysis.meterLevel(rms: 0.056) - 0.62) < 0.05) // -25 dB: normal speech
        #expect(AudioAnalysis.meterLevel(rms: 0.5) == 1)             // -6 dB: full scale
    }
}
