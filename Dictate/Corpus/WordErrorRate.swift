import Foundation

/// Word error rate: the substitutions, deletions and insertions needed to turn
/// the hypothesis into the reference, over the number of reference words.
nonisolated enum WordErrorRate {
    /// How both texts are reduced to words before comparing them.
    struct Normalization: Equatable, Sendable {
        /// "Push" and "push" count as the same word.
        var lowercase = true
        /// Punctuation becomes a word break: "push," is "push", "l'API" is "l API".
        var stripPunctuation = true
        /// "évènement" and "evenement" count as the same word.
        var foldDiacritics = false

        static let standard = Normalization()
    }

    /// Edit counts, to add up over a corpus before dividing.
    struct Count: Equatable, Sendable {
        var errors = 0
        var referenceWords = 0

        /// Nil without reference words: nothing to be wrong about.
        var rate: Double? {
            referenceWords > 0 ? Double(errors) / Double(referenceWords) : nil
        }

        static func + (lhs: Count, rhs: Count) -> Count {
            Count(errors: lhs.errors + rhs.errors, referenceWords: lhs.referenceWords + rhs.referenceWords)
        }
    }

    static func count(reference: String, hypothesis: String, normalization: Normalization = .standard) -> Count {
        let reference = words(in: reference, normalization: normalization)
        let hypothesis = words(in: hypothesis, normalization: normalization)
        return Count(errors: editDistance(reference, hypothesis), referenceWords: reference.count)
    }

    static func rate(reference: String, hypothesis: String, normalization: Normalization = .standard) -> Double? {
        count(reference: reference, hypothesis: hypothesis, normalization: normalization).rate
    }

    static func words(in text: String, normalization: Normalization = .standard) -> [String] {
        var text = text
        if normalization.lowercase { text = text.lowercased() }
        if normalization.foldDiacritics { text = text.folding(options: .diacriticInsensitive, locale: nil) }
        if normalization.stripPunctuation {
            text = String(text.unicodeScalars.map { scalar in
                CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                    ? " " : Character(scalar)
            })
        }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Levenshtein distance over words, every edit costing one.
    static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        guard !hypothesis.isEmpty else { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let substitution = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }
}
