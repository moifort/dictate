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
