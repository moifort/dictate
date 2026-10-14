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

    /// Every entry, references or not.
    var total = 0
    /// One line per engine that has entries with a reference.
    var engines: [TranscriptionEngine: Line] = [:]

    init(entries: [CorpusEntry], normalization: WordErrorRate.Normalization = .standard) {
        total = entries.count
        for entry in entries {
            guard let reference = entry.reference else { continue }
            var line = engines[entry.engine] ?? Line()
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
            engines[entry.engine] = line
        }
    }

    /// Plain-text summary, for the log and the alert.
    var summary: String {
        let withReference = engines.values.reduce(0) { $0 + $1.dictations }
        var lines = ["\(total) dictées, \(withReference) avec une référence."]
        for engine in TranscriptionEngine.allCases {
            guard let line = engines[engine] else { continue }
            lines.append("\(engine.displayName) seul : WER \(Self.format(line.transcript)) sur \(line.dictations) dictées")
            if line.enhancedDictations > 0 {
                lines.append("\(engine.displayName) + Claude : WER \(Self.format(line.enhanced)) sur \(line.enhancedDictations) dictées")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ count: WordErrorRate.Count) -> String {
        guard let rate = count.rate else { return "—" }
        return "\(rate.formatted(.percent.precision(.fractionLength(1)))) (\(count.errors)/\(count.referenceWords) mots)"
    }
}
