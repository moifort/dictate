import Foundation
import Observation

/// A term Dictate proposes to add to the vocabulary.
nonisolated struct VocabularySuggestion: Codable, Equatable, Identifiable, Sendable {
    enum Reason: Codable, Equatable, Sendable {
        /// The user replaced `from` with the term after a dictation.
        case corrected(from: String)
        /// The term was in the text before the cursor in this many dictations.
        case recurring(count: Int)
    }

    let term: String
    let reason: Reason
    let date: Date

    var id: String { VocabularySuggestionState.key(of: term) }

    /// Why the term comes up, for the settings and the menu.
    var reasonDescription: String {
        switch reason {
        case .corrected(let wrong): String(localized: "Corrigé depuis « \(wrong) »")
        case .recurring(let count): String(localized: "Déjà écrit dans \(count) dictées")
        }
    }
}

/// What the suggestions remember: the terms waiting for an answer, those the
/// user turned down, and how often each recurring term was seen so far.
nonisolated struct VocabularySuggestionState: Codable, Equatable, Sendable {
    /// Dictations a term must appear in before it is suggested.
    static let recurrenceThreshold = 5
    /// Terms counted at most: the rarest, then the oldest, go first.
    static let maxSightings = 300
    /// Waiting suggestions at most: the oldest go first.
    static let maxPending = 10

    struct Sighting: Codable, Equatable, Sendable {
        var term: String
        var count: Int
        var lastSeen: Date
    }

    var pending: [VocabularySuggestion] = []
    /// Keys of the terms the user turned down: they never come back.
    var ignored: Set<String> = []
    /// Recurring terms by key.
    var sightings: [String: Sighting] = [:]

    /// Case and accents ignored: "Aurelien" in the vocabulary covers "Aurélien".
    static func key(of term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Suggests each corrected term at once: the user spelled it out. Returns the number added.
    @discardableResult
    mutating func note(_ corrections: [TermCorrection], vocabulary: [String], date: Date) -> Int {
        let known = Set(vocabulary.map(Self.key))
        var added = 0
        for correction in corrections where isNew(correction.right, known: known) {
            sightings[Self.key(of: correction.right)] = nil
            suggest(VocabularySuggestion(term: correction.right, reason: .corrected(from: correction.wrong), date: date))
            added += 1
        }
        return added
    }

    /// Counts the terms of one dictation's preceding text, each once, and
    /// suggests those seen often enough. Returns the number added.
    @discardableResult
    mutating func noteRecurring(_ terms: [String], vocabulary: [String], date: Date) -> Int {
        let known = Set(vocabulary.map(Self.key))
        var added = 0
        for term in terms {
            let key = Self.key(of: term)
            guard isNew(term, known: known) else {
                if known.contains(key) { sightings[key] = nil }
                continue
            }
            var sighting = sightings[key] ?? Sighting(term: term, count: 0, lastSeen: date)
            sighting.term = term
            sighting.count += 1
            sighting.lastSeen = date
            if sighting.count >= Self.recurrenceThreshold {
                sightings[key] = nil
                suggest(VocabularySuggestion(term: term, reason: .recurring(count: sighting.count), date: date))
                added += 1
            } else {
                sightings[key] = sighting
            }
        }
        trimSightings()
        return added
    }

    /// Drops a suggestion, once added to the vocabulary.
    mutating func remove(_ term: String) {
        let key = Self.key(of: term)
        pending.removeAll { $0.id == key }
        sightings[key] = nil
    }

    /// Drops a suggestion for good.
    mutating func ignore(_ term: String) {
        remove(term)
        ignored.insert(Self.key(of: term))
    }

    private func isNew(_ term: String, known: Set<String>) -> Bool {
        let key = Self.key(of: term)
        return !key.isEmpty && !known.contains(key) && !ignored.contains(key) && !pending.contains { $0.id == key }
    }

    private mutating func suggest(_ suggestion: VocabularySuggestion) {
        pending.append(suggestion)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    private mutating func trimSightings() {
        guard sightings.count > Self.maxSightings else { return }
        let evicted = sightings
            .sorted { ($0.value.count, $0.value.lastSeen) < ($1.value.count, $1.value.lastSeen) }
            .prefix(sightings.count - Self.maxSightings)
        for (key, _) in evicted { sightings[key] = nil }
    }
}

/// Terms Dictate noticed and proposes to add to the vocabulary: those the
/// user fixed right after a dictation, and the names that keep coming back
/// in the text before the cursor.
///
/// Opt-in, never uploaded: the terms stay in one JSON file on this Mac, and
/// logs and error reports give counts, never the words.
@Observable
final class VocabularySuggestions {
    private(set) var state: VocabularySuggestionState

    @ObservationIgnored let file: URL

    /// One folder per bundle identifier, like the corpus.
    static var defaultFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "Dictate/Vocabulary", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier ?? "Dictate", directoryHint: .isDirectory)
            .appending(path: "suggestions.json")
    }

    init(file: URL = VocabularySuggestions.defaultFile) {
        self.file = file
        state = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(VocabularySuggestionState.self, from: $0) }
            ?? VocabularySuggestionState()
    }

    /// The waiting suggestions not in the vocabulary yet, which the user may have edited by hand.
    func pending(excluding vocabulary: [String]) -> [VocabularySuggestion] {
        let known = Set(vocabulary.map(VocabularySuggestionState.key))
        return state.pending.filter { !known.contains($0.id) }
    }

    /// Looks for the terms the user fixed in a pasted dictation.
    func consider(_ followUp: InsertionFollowUp, vocabulary: [String], date: Date = .now) {
        guard let corrected = followUp.corrected else { return }
        let corrections = CorrectedTerms.corrections(inserted: followUp.inserted, corrected: corrected)
        guard !corrections.isEmpty else { return }
        let added = state.note(corrections, vocabulary: vocabulary, date: date)
        Log.app.info("vocabulary: \(corrections.count) corrections, \(added) new suggestions")
        save()
    }

    /// Counts the terms already written in the field.
    func consider(precedingText: String, vocabulary: [String], date: Date = .now) {
        let terms = RecurringTerms.terms(in: precedingText)
        guard !terms.isEmpty else { return }
        let added = state.noteRecurring(terms, vocabulary: vocabulary, date: date)
        if added > 0 { Log.app.info("vocabulary: \(added) recurring terms suggested") }
        save()
    }

    /// Once the term is in the vocabulary.
    func remove(_ suggestion: VocabularySuggestion) {
        state.remove(suggestion.term)
        save()
    }

    func ignore(_ suggestion: VocabularySuggestion) {
        state.ignore(suggestion.term)
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: file, options: .atomic)
        } catch {
            Log.app.error("could not save vocabulary suggestions: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "vocabulary suggestions could not be saved", category: "vocabulary")
        }
    }

    /// Dates as plain numbers: ISO 8601 would round them to the second.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
