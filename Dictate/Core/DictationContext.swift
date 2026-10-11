import Foundation

/// What the enhancer knows about where the dictation will be inserted.
nonisolated struct DictationContext: Equatable, Sendable {
    var category: AppCategory = .other
    /// Name of the frontmost app, e.g. "Slack".
    var appName: String?
    /// End of the text already in the focused field, up to the cursor.
    var precedingText: String?
}
