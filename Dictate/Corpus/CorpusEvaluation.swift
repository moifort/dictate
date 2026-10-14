import Foundation

/// Word error rates over the corpus, against what the user left in the field.
///
/// Rates are pooled (total errors over total reference words), so a long
/// dictation weighs more than a one-word one. The reference starts as the
/// inserted text and only differs where the user fixed it: an unfixed mistake
/// counts as correct, so both rates are lower bounds, the "with Claude" one
/// most of all.
nonisolated struct CorpusEvaluation: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// Dictations with a reference.
        var dictations = 0
        /// The engine's transcript alone.
        var transcript = WordErrorRate.Count()
        /// What was inserted, for the dictations Claude reviewed.
        var enhanced = WordErrorRate.Count()
        var enhancedDictations = 0
    }

    /// What produced the transcripts of a line.
    struct Setup: Hashable, Sendable {
        var engine: TranscriptionEngine
        /// The transcript was rescored against the vocabulary.
        var vocabularyBoosted = false
    }

    /// Every entry, references or not.
    var total = 0
    /// One line per setup that has entries with a reference, so the rates
    /// with and without vocabulary boosting can be compared.
    var lines: [Setup: Line] = [:]

    init(entries: [CorpusEntry], normalization: WordErrorRate.Normalization = .standard) {
        total = entries.count
        for entry in entries {
            guard let reference = entry.reference else { continue }
            let setup = Setup(engine: entry.engine, vocabularyBoosted: entry.vocabularyBoosted ?? false)
            var line = lines[setup] ?? Line()
            line.dictations += 1
            line.transcript = line.transcript + WordErrorRate.count(
                reference: reference, hypothesis: entry.transcript, normalization: normalization
            )
            if entry.enhanced {
                line.enhancedDictations += 1
                line.enhanced = line.enhanced + WordErrorRate.count(
                    reference: reference, hypothesis: entry.inserted, normalization: normalization
                )
            }
            lines[setup] = line
        }
    }

    /// Plain-text summary, for the log and the alert.
    var summary: String {
        let withReference = lines.values.reduce(0) { $0 + $1.dictations }
        var summary = ["\(total) dictées, \(withReference) avec une référence."]
        for engine in TranscriptionEngine.allCases {
            for boosted in [false, true] {
                guard let line = lines[Setup(engine: engine, vocabularyBoosted: boosted)] else { continue }
                let name = engine.displayName + (boosted ? " avec lexique renforcé" : "")
                summary.append("\(name) seul : WER \(Self.format(line.transcript)) sur \(line.dictations) dictées")
                if line.enhancedDictations > 0 {
                    summary.append("\(name) + Claude : WER \(Self.format(line.enhanced)) sur \(line.enhancedDictations) dictées")
                }
            }
        }
        return summary.joined(separator: "\n")
    }

    private static func format(_ count: WordErrorRate.Count) -> String {
        guard let rate = count.rate else { return "—" }
        return "\(rate.formatted(.percent.precision(.fractionLength(1)))) (\(count.errors)/\(count.referenceWords) mots)"
    }
}
