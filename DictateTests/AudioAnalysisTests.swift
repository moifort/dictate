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
}
