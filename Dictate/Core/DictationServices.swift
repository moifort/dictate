import Foundation

/// Captures microphone audio as 16 kHz mono samples.
protocol AudioRecording: AnyObject {
    /// Receives every captured chunk while recording, on an arbitrary thread.
    /// Set before `start()`.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    func start() throws
    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float]
}

@MainActor protocol Transcriber: AnyObject, Sendable {
    /// Starts transcribing audio while it is still being recorded.
    /// `vocabulary` biases decoding towards the listed spellings, at a cost
    /// of one decoder pass per prompt token; pass `[]` for the fastest result.
    func startLive(vocabulary: [String]) -> any LiveTranscription
}

/// One dictation being transcribed as it is spoken: audio is appended as it
/// arrives, and `finish()` returns the text once the last of it is decoded.
nonisolated protocol LiveTranscription: AnyObject, Sendable {
    func append(_ samples: [Float])
    /// Decodes whatever has not been decoded yet and returns the whole text.
    func finish() async throws -> String
    /// Drops the dictation; nothing more will be decoded.
    func cancel()
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
            if rms(samples[index..<end]) > threshold { return false }
            index = end
        }
        return true
    }

    /// Where a live transcription can cut the audio: the latest point, after
    /// `start`, where a pause of `minimumPause` seconds has just completed and
    /// at least `minimumSpeech` seconds of speech were heard since `start`.
    /// Decoded chunks therefore end in silence, never in the middle of a word.
    static func chunkBoundary(
        in samples: [Float],
        from start: Int,
        minimumSpeech: Double = 3,
        minimumPause: Double = 0.5,
        threshold: Float = 0.01
    ) -> Int? {
        let window = sampleRate / 10
        let pauseWindows = Int((minimumPause * 10).rounded(.up))
        let speechWindows = Int((minimumSpeech * 10).rounded(.up))
        var boundary: Int?
        var speech = 0
        var silence = 0
        var index = start
        while index + window <= samples.count {
            let end = index + window
            if rms(samples[index..<end]) > threshold {
                speech += 1
                silence = 0
            } else {
                silence += 1
                if silence == pauseWindows, speech >= speechWindows { boundary = end }
            }
            index = end
        }
        return boundary
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
