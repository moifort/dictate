import Foundation

/// One finished dictation as kept for the statistics: when, how much, how
/// long each step took. Never the text itself.
nonisolated struct DictationRecord: Codable, Equatable, Sendable {
    let date: Date
    /// Words of the text that was inserted, after Claude's cleanup.
    let words: Int
    /// Seconds of speech recorded while `fn` was held.
    let audio: TimeInterval
    /// The model that transcribed the speech; nil for an engine no longer
    /// offered, such as Whisper.
    let engine: TranscriptionEngine?
    /// Transcription, in seconds.
    let transcription: TimeInterval
    /// Cleanup, in seconds; nil when it is turned off.
    let enhancement: TimeInterval?
    /// The model that cleaned up the text, the one that stepped in offline
    /// included; nil when the cleanup is turned off.
    let reviewer: Reviewer?
    /// Pasting or copying, in seconds.
    let insertion: TimeInterval

    init(
        date: Date,
        words: Int,
        audio: TimeInterval,
        engine: TranscriptionEngine? = .parakeet,
        transcription: TimeInterval,
        enhancement: TimeInterval?,
        reviewer: Reviewer? = .claude,
        insertion: TimeInterval
    ) {
        self.date = date
        self.words = words
        self.audio = audio
        self.engine = engine
        self.transcription = transcription
        self.enhancement = enhancement
        self.reviewer = enhancement == nil ? nil : reviewer
        self.insertion = insertion
    }

    /// Lines written before the engine was recorded all come from Whisper:
    /// like the lines naming it, they keep their words but no engine. Lines
    /// written before the reviewer was recorded were all cleaned up by
    /// Claude, the only reviewer there was.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        words = try container.decode(Int.self, forKey: .words)
        audio = try container.decode(TimeInterval.self, forKey: .audio)
        engine = try container.decodeIfPresent(String.self, forKey: .engine).flatMap(TranscriptionEngine.init(rawValue:))
        transcription = try container.decode(TimeInterval.self, forKey: .transcription)
        enhancement = try container.decodeIfPresent(TimeInterval.self, forKey: .enhancement)
        reviewer = enhancement == nil ? nil : try container.decodeIfPresent(Reviewer.self, forKey: .reviewer) ?? .claude
        insertion = try container.decode(TimeInterval.self, forKey: .insertion)
    }

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
