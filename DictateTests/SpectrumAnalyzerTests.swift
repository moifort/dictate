import Foundation
import Testing
@testable import Dictate

struct SpectrumAnalyzerTests {
    /// About 21 ms at 16 kHz, what a 1 024-frame tap delivers at 48 kHz.
    private static let chunkSize = 341

    private static func tone(_ frequency: Double, amplitude: Float = 0.2, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / Double(AudioAnalysis.sampleRate))) }
    }

    /// Feeds the signal chunk by chunk, like the tap, and returns the last reading.
    private static func analyze(_ samples: [Float], with analyzer: SpectrumAnalyzer = SpectrumAnalyzer()) -> VoiceSpectrum {
        var spectrum = VoiceSpectrum.silent
        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            spectrum = analyzer.process(Array(samples[index..<end]))
            index = end
        }
        return spectrum
    }

    @Test func silenceStaysFlat() {
        let spectrum = Self.analyze([Float](repeating: 0, count: 8_000))
        #expect(spectrum.level == 0)
        #expect(spectrum.low == 0 && spectrum.mid == 0 && spectrum.high == 0)
        #expect(spectrum.tilt == 0)
    }

    @Test func lowToneLightsTheLowBandAndLeansLeft() {
        let spectrum = Self.analyze(Self.tone(150, count: 8_000))
        #expect(spectrum.level > 0.5)
        #expect(spectrum.low > 0.5)
        #expect(spectrum.high < 0.2)
        #expect(spectrum.tilt < -0.3)
    }

    @Test func highToneLightsTheHighBandAndLeansRight() {
        let spectrum = Self.analyze(Self.tone(4_000, count: 8_000))
        #expect(spectrum.high > 0.5)
        #expect(spectrum.low < 0.2)
        #expect(spectrum.tilt > 0.3)
    }

    @Test func midToneLightsTheMidBand() {
        let spectrum = Self.analyze(Self.tone(800, count: 8_000))
        #expect(spectrum.mid > 0.5)
        #expect(spectrum.low < 0.2 && spectrum.high < 0.2)
    }

    /// A quiet band is measured against its own recent peak: sibilants carry far
    /// less energy than vowels, yet must swell the high wave just as much.
    @Test func eachBandIsScaledToItsOwnPeak() {
        let analyzer = SpectrumAnalyzer()
        _ = Self.analyze(Self.tone(150, amplitude: 0.3, count: 8_000), with: analyzer)
        let sibilant = Self.analyze(Self.tone(5_000, amplitude: 0.03, count: 4_000), with: analyzer)
        #expect(sibilant.high > 0.5)
        #expect(sibilant.tilt > 0)
    }

    @Test func levelFallsBackAfterSpeechStops() {
        let analyzer = SpectrumAnalyzer()
        let speaking = Self.analyze(Self.tone(300, count: 8_000), with: analyzer)
        let after = Self.analyze([Float](repeating: 0, count: 24_000), with: analyzer)
        #expect(speaking.level > 0.5)
        #expect(after.level < 0.05)
        #expect(abs(after.tilt) < 0.05)
    }

    /// Between two syllables, about 200 ms, the waves must come most of the
    /// way down, or every syllable blurs into the next.
    @Test func bandsDropWithinASyllable() {
        let analyzer = SpectrumAnalyzer()
        let speaking = Self.analyze(Self.tone(300, count: 8_000), with: analyzer)
        let pause = Self.analyze([Float](repeating: 0, count: 3_200), with: analyzer)
        #expect(speaking.low > 0.8)
        #expect(pause.low < speaking.low * 0.35)
    }
}
