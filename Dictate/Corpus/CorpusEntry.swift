import Foundation

/// One dictation kept to measure accuracy: what the engine heard, what was
/// inserted, and what the user left in the field a few seconds later.
nonisolated struct CorpusEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    /// Name of the WAV file next to the entries, 16 kHz mono.
    let audioFile: String
    /// Seconds of speech.
    let audio: TimeInterval
    let engine: TranscriptionEngine
    /// ISO 639-1 code of the language being dictated.
    let language: String
    let bundleID: String?
    /// `AppCategory` raw value.
    let category: String
    /// What the engine produced, before Claude.
    let transcript: String
    /// What was pasted: Claude's version, or the transcript when Claude was off or failed.
    let inserted: String
    /// Whether `inserted` went through Claude.
    let enhanced: Bool
    /// The inserted text as the user left it; nil when the field could not
    /// be read again or no longer held it.
    let reference: String?
}

/// What the controller knows about a dictation it pasted, for the corpus.
struct DictationSample {
    let date: Date
    let samples: [Float]
    let engine: TranscriptionEngine
    let language: String
    let bundleID: String?
    let category: AppCategory
    let transcript: String
    let inserted: String
    let enhanced: Bool
    /// The field before the paste and a few seconds after; nil when it could
    /// not be read before the paste.
    let followUp: Task<InsertionFollowUp?, Never>?
}
