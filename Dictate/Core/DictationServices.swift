import Foundation

/// Captures microphone audio as 16 kHz mono samples.
protocol AudioRecording: AnyObject {
    func start() throws
    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float]
}

@MainActor protocol Transcriber: AnyObject, Sendable {
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String
}

@MainActor protocol Enhancer: AnyObject, Sendable {
    /// Must honour task cancellation: the controller cancels on timeout.
    func enhance(transcript: String, category: AppCategory) async throws -> String
}

protocol FocusInspecting: AnyObject {
    func frontmostBundleID() -> String?
    /// Whether the focused UI element accepts text input.
    func hasEditableFocus() -> Bool
}

protocol TextInserting: AnyObject {
    /// Pastes into the focused field, then restores the previous pasteboard.
    func paste(_ text: String) async
    /// Leaves the text in the pasteboard for the user to paste.
    func copyToPasteboard(_ text: String)
}

nonisolated enum AudioAnalysis {
    static let sampleRate = 16_000

    /// Maps an RMS value to a 0...1 meter level on a decibel scale: quiet
    /// speech (-45 dB) barely registers, normal speech (-25 dB) sits mid-way,
    /// and anything above -10 dB is full scale.
    static func meterLevel(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 50) / 40))
    }

    /// True when no 100 ms window rises above the speech energy threshold.
    static func isSilent(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        let window = sampleRate / 10
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            if (sum / Float(end - index)).squareRoot() > threshold { return false }
            index = end
        }
        return true
    }
}
