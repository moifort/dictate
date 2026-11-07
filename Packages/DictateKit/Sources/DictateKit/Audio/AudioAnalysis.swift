import Foundation

public nonisolated enum AudioAnalysis {
    public static let sampleRate = 16_000

    /// Maps an RMS value to a 0...1 meter level on a decibel scale: quiet
    /// speech (-45 dB) barely registers, normal speech (-25 dB) sits mid-way,
    /// and anything above -10 dB is full scale.
    public static func meterLevel(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 50) / 40))
    }

    /// Below the quietest speech peak measured on a MacBook Pro microphone at
    /// half input volume (0.012 RMS) and above its noise floor (0.0021 at most).
    public static let silenceThreshold: Float = 0.004

    /// True when no 100 ms window rises above the speech energy threshold.
    public static func isSilent(_ samples: [Float], threshold: Float = silenceThreshold) -> Bool {
        peakRMS(samples) <= threshold
    }

    /// The RMS of the loudest 100 ms window, 0 for no samples.
    public static func peakRMS(_ samples: [Float]) -> Float {
        let window = sampleRate / 10
        var peak: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(end - index)).squareRoot())
            index = end
        }
        return peak
    }
}
