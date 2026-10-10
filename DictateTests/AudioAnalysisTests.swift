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

struct ChunkBoundaryTests {
    private let rate = AudioAnalysis.sampleRate

    private func audio(_ parts: (seconds: Double, speech: Bool)...) -> [Float] {
        parts.flatMap { part in
            let count = Int(part.seconds * Double(rate))
            return (0..<count).map { part.speech ? ($0.isMultiple(of: 2) ? Float(0.3) : Float(-0.3)) : Float(0.001) }
        }
    }

    @Test func noPauseMeansNoBoundary() {
        #expect(AudioAnalysis.chunkBoundary(in: audio((6, true)), from: 0) == nil)
    }

    @Test func boundaryEndsWhereThePauseIsEstablished() {
        let samples = audio((4, true), (0.8, false), (2, true))
        // 4 s of speech, then the pause counts as complete after 0.5 s.
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: 0) == Int(4.5 * Double(rate)))
    }

    @Test func tooLittleSpeechBeforeThePauseIsNotCut() {
        let samples = audio((2, true), (0.8, false), (2, true))
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: 0) == nil)
    }

    @Test func shortPausesAreIgnored() {
        let samples = audio((4, true), (0.3, false), (2, true))
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: 0) == nil)
    }

    @Test func latestEligiblePauseWins() {
        let samples = audio((4, true), (0.6, false), (4, true), (0.6, false), (1, true))
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: 0) == Int(9.1 * Double(rate)))
    }

    @Test func speechIsCountedFromTheStartIndex() {
        let samples = audio((4, true), (0.6, false), (2, true), (0.6, false), (1, true))
        let first = Int(4.5 * Double(rate))
        // Only 2 s of speech after the first cut: not enough for a second chunk.
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: first) == nil)
        #expect(AudioAnalysis.chunkBoundary(in: samples, from: first, minimumSpeech: 1.5) == Int(7.1 * Double(rate)))
    }
}
