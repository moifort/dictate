import Foundation

/// One finished dictation as kept for the statistics: when, how much, how
/// long each step took. Never the text itself.
nonisolated struct DictationRecord: Codable, Equatable, Sendable {
    let date: Date
    /// Words of the text that was inserted, after Claude's cleanup.
    let words: Int
    /// Seconds of speech recorded while `fn` was held.
    let audio: TimeInterval
    /// Whisper, in seconds.
    let transcription: TimeInterval
    /// Claude, in seconds; nil when the cleanup is turned off.
    let enhancement: TimeInterval?
    /// Pasting or copying, in seconds.
    let insertion: TimeInterval

    /// From releasing `fn` to the text being on screen.
    var latency: TimeInterval { transcription + (enhancement ?? 0) + insertion }

    /// Words as the system segments them: punctuation alone is not a word.
    static func wordCount(of text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
