import Foundation

/// Marks the words the transcriber was unsure of, so Claude knows where a
/// correction may be due and where to leave the text alone.
nonisolated enum DoubtfulWords {
    static let open = "<?>"
    static let close = "</?>"

    /// Parakeet's confidence is the probability its decoder gave the token it
    /// emitted. Below one half, the alternatives together were likelier than
    /// that token: the model was guessing. Clearly spoken words sit above 0.9,
    /// so this leaves them alone and flags only real doubts.
    static let threshold: Float = 0.5

    /// The transcript with each word below `threshold` wrapped in markers,
    /// punctuation kept outside: `<?>Kubernetis</?>,`.
    ///
    /// Words are matched in order against the transcript's own words, so a
    /// transcript the engine rewrote after decoding is left unmarked rather
    /// than marked in the wrong place.
    static func mark(_ transcription: Transcription, threshold: Float = threshold) -> String {
        guard transcription.words.contains(where: { $0.confidence < threshold }) else { return transcription.text }
        var remaining = transcription.words[...]
        return transcription.text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { chunk -> String in
                let word = String(chunk)
                // Allows for a word the transcript has but the timings lack, or the reverse.
                guard !word.isEmpty,
                      let index = remaining.prefix(3).firstIndex(where: { $0.text == word })
                else { return word }
                let confidence = remaining[index].confidence
                remaining = remaining[(index + 1)...]
                return confidence < threshold ? wrap(word) : word
            }
            .joined(separator: " ")
    }

    /// Removes any marker Claude copied into its reply.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: close, with: "").replacingOccurrences(of: open, with: "")
    }

    private static func wrap(_ word: String) -> String {
        // Claude has its own rule for it, and `<<?>unk</?>>` would hide it.
        guard !word.contains(UnknownTokens.token) else { return word }
        let scalars = word.unicodeScalars
        guard let first = scalars.firstIndex(where: { CharacterSet.alphanumerics.contains($0) }),
              let last = scalars.lastIndex(where: { CharacterSet.alphanumerics.contains($0) })
        else { return word }
        let core = String(scalars[first...last])
        return String(scalars[..<first]) + open + core + close + String(scalars[scalars.index(after: last)...])
    }
}
