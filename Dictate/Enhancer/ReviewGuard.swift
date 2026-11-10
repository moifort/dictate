import Foundation

/// Rejects a reply that is no longer a cleanup of the dictation, whatever the
/// reviewer. The field's text and the window title reach the reviewer, and
/// its reply is pasted, sometimes followed by Return: a model that answers
/// the field instead, or follows instructions written in it, must not have
/// its reply typed and sent. The raw transcript goes in instead.
nonisolated enum ReviewGuard {
    /// Dictations shorter than this are not judged on their errors: fixing one
    /// misheard word already changes half of a two-word one.
    static let minimumJudgedWords = 3
    /// Word error rate of the reply against the transcript beyond which the
    /// reply is no longer a cleanup. On 1 512 corpus dictations (2026-11-03)
    /// the on-device model's six bad replies ("/", "/ CI/CD", the field's text
    /// instead of the dictation) were all at 1.0 or more, its good ones at 0.5
    /// or less.
    static let maximumWordErrorRate = 0.6
    /// The words a dictated emoji may replace: its trigger and a description
    /// such as "qui pleure de rire".
    static let wordsPerEmoji = 5

    /// Whether `reply` left `transcript`: little of it is left, or the reply
    /// says far more than was dictated, however short the dictation.
    static func diverges(_ reply: String, from transcript: String) -> Bool {
        let transcriptWords = WordErrorRate.words(in: transcript)
        let replyWords = WordErrorRate.words(in: reply)
        // A dictated emoji takes the place of its words, which the error rate
        // would count as deleted: they are forgiven, the trigger included.
        let emojis = DictatedEmoji.isRequested(in: transcript) ? DictatedEmoji.count(in: reply) : 0
        if replyWords.isEmpty { return !transcriptWords.isEmpty && emojis == 0 }
        // A cleanup removes words and adds none: a reply twice as long, and
        // more, carries something nobody dictated.
        if replyWords.count > transcriptWords.count * 2 + 4 { return true }
        guard transcriptWords.count >= minimumJudgedWords else { return false }
        let count = WordErrorRate.count(reference: transcript, hypothesis: reply)
        let errors = max(0, count.errors - emojis * wordsPerEmoji)
        return Double(errors) / Double(count.referenceWords) > maximumWordErrorRate
    }
}
