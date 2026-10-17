import Accelerate

/// What the recording indicator draws: how loud the voice is and how it spreads
/// across lows, mids and highs.
nonisolated struct VoiceSpectrum: Equatable, Sendable {
    /// Overall input level in 0...1, see `AudioAnalysis.meterLevel`.
    var level: Float
    /// Each band in 0...1, gated by the overall level so silence stays flat.
    var low: Float
    var mid: Float
    var high: Float
    /// -1 when the voice sits in the lows, 1 on sibilants.
    var tilt: Float

    static let silent = VoiceSpectrum(level: 0, low: 0, mid: 0, high: 0, tilt: 0)
}

/// Runs on the audio thread: splits the 16 kHz stream into three bands with an
/// FFT over the last 32 ms, then smooths the readings for the indicator.
nonisolated final class SpectrumAnalyzer {
    private static let size = 512
    /// Band edges in Hz; 8 kHz is the Nyquist frequency at 16 kHz. Tuned on the
    /// evaluation corpus: with the lows stopping at 300 Hz, lows and mids rose
    /// and fell as one, since a vowel's pitch and formants swell together.
    private static let bands: [(low: Double, high: Double)] = [(80, 700), (700, 3_000), (3_000, 8_000)]
    /// How far below its reference a band reads as empty, in dB.
    private static let bandRange: Float = 12
    /// A band's reference never drops further than this below the loudest band:
    /// the faint highs of a vowel must not fill the scale on their own.
    private static let loudestAllowance: Float = 12
    /// How fast a band forgets its loudest moment, in dB per second.
    private static let peakDecay: Float = 8
    private static let peakFloor: Float = -90
    /// The level and bands rise instantly and keep a quarter of their value
    /// 200 ms later, about one syllable: each syllable swells the waves and
    /// lets them drop before the next, like the landing page's hero.
    private static let fallPerSecond: Float = 0.001
    /// Lifts the bands so a normal voice fills the waves on each syllable;
    /// the gate still keeps silence flat.
    private static let bandGain: Float = 1.4
    /// Time constant of the tilt, in seconds.
    private static let tiltSmoothing: Float = 0.08
    /// How fast the speaker's usual balance follows the voice, per second of
    /// speech. The tilt swings around it, so a voice rich in lows still leans
    /// both ways.
    private static let balanceRate: Float = 1
    private static let tiltGain: Float = 1.5

    private let fft = vDSP.FFT(log2n: vDSP_Length(9), radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private let bandBins: [Range<Int>]
    /// The last `size` samples, oldest first.
    private var history = [Float](repeating: 0, count: size)
    /// Recent loudest reading of each band, in dB.
    private var peaks = [Float](repeating: peakFloor, count: bands.count)
    private var smoothed = VoiceSpectrum.silent
    /// Median of highs minus lows while speaking: unlike the mean, the brief
    /// spikes of sibilants do not pull it to the right.
    private var balance: Float = 0

    init() {
        let binWidth = Double(AudioAnalysis.sampleRate) / Double(Self.size)
        bandBins = Self.bands.map { band in
            Int((band.low / binWidth).rounded())..<min(Self.size / 2, Int((band.high / binWidth).rounded()))
        }
    }

    func process(_ chunk: [Float]) -> VoiceSpectrum {
        guard !chunk.isEmpty else { return smoothed }
        let seconds = Float(chunk.count) / Float(AudioAnalysis.sampleRate)
        history.append(contentsOf: chunk.suffix(Self.size))
        history.removeFirst(history.count - Self.size)

        let level = AudioAnalysis.meterLevel(rms: vDSP.rootMeanSquare(chunk))
        let decibels = bandDecibels()
        let loudest = decibels.max() ?? Self.peakFloor
        var shapes = [Float](repeating: 0, count: decibels.count)
        for index in decibels.indices {
            peaks[index] = max(decibels[index], max(peaks[index] - Self.peakDecay * seconds, Self.peakFloor))
            let reference = max(peaks[index], loudest - Self.loudestAllowance)
            shapes[index] = min(1, max(0, (decibels[index] - reference + Self.bandRange) / Self.bandRange))
        }
        // Quieter sounds such as sibilants still need to show: the square root
        // lifts them while keeping silence at zero.
        let gate = level.squareRoot()
        let lift = min(1, gate * Self.bandGain)

        let fall = pow(Self.fallPerSecond, seconds)
        let tiltBlend = 1 - exp(-seconds / Self.tiltSmoothing)
        let spread = shapes[2] - shapes[0]
        // Only speech moves the balance: silence would drag it towards noise.
        let step = Self.balanceRate * seconds * gate
        balance += min(step, max(-step, spread - balance))
        let tilt = min(1, max(-1, (spread - balance) * gate * Self.tiltGain))
        smoothed = VoiceSpectrum(
            level: max(level, smoothed.level * fall),
            low: max(shapes[0] * lift, smoothed.low * fall),
            mid: max(shapes[1] * lift, smoothed.mid * fall),
            high: max(shapes[2] * lift, smoothed.high * fall),
            tilt: smoothed.tilt + (tilt - smoothed.tilt) * tiltBlend
        )
        return smoothed
    }

    /// Power of each band over the window, in dB on the same scale as the RMS
    /// level: a full-band signal reads the same either way.
    private func bandDecibels() -> [Float] {
        let half = Self.size / 2
        let windowed = vDSP.multiply(history, window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // vDSP's real FFT doubles the amplitudes; one side of the spectrum holds
        // half the power; the Hann window keeps 37.5 % of it.
        let scale = 1 / (2 * Float(Self.size * Self.size) * 0.375)
        return bandBins.map { bins in
            let meanSquare = power[bins].reduce(0, +) * scale
            return 10 * log10(max(meanSquare, 1e-12))
        }
    }
}
