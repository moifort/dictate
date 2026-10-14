import Foundation

/// What a transcriber heard: the text, and how sure it was of each word when
/// the engine reports it.
nonisolated struct Transcription: Equatable, Sendable {
    /// One space-delimited word of the transcript, with any punctuation the
    /// model attached to it, e.g. `"push,"`.
    struct Word: Equatable, Sendable {
        var text: String
        /// Probability, from 0 to 1, the model gave its least certain sub-word token.
        var confidence: Float
    }

    var text: String
    /// In transcript order; empty when the engine reports no confidence.
    var words: [Word]
    /// The custom vocabulary was searched for in the audio and the transcript
    /// rescored against it, whether or not a word changed.
    var vocabularyBoosted: Bool

    init(text: String, words: [Word] = [], vocabularyBoosted: Bool = false) {
        self.text = text
        self.words = words
        self.vocabularyBoosted = vocabularyBoosted
    }

    /// The least certain word, nil when the engine reports no confidence.
    var lowestConfidence: Float? { words.map(\.confidence).min() }

    /// Groups SentencePiece sub-word tokens into words: a piece starting with a
    /// space or `▁` opens a new word, the others extend the current one.
    ///
    /// A word is only as reliable as its weakest piece, so it takes their
    /// minimum. Punctuation pieces are left out of it when the word has
    /// letters: a hesitant comma says nothing about the spelling of the word.
    static func words(fromTokens tokens: [(piece: String, confidence: Float)]) -> [Word] {
        var words: [Word] = []
        var text = ""
        var confidences: [(Float, spelled: Bool)] = []

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let spelled = confidences.filter(\.spelled).map(\.0)
            let confidence = (spelled.isEmpty ? confidences.map(\.0) : spelled).min() ?? 0
            words.append(Word(text: trimmed, confidence: confidence))
        }

        for (piece, confidence) in tokens where !piece.isEmpty {
            let normalized = piece.replacingOccurrences(of: "\u{2581}", with: " ")
            if normalized.hasPrefix(" ") {
                flush()
                text = ""
                confidences = []
            }
            text += normalized
            let spelled = normalized.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            confidences.append((confidence, spelled))
        }
        flush()
        return words
    }
}
