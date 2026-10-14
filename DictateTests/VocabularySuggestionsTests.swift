import Foundation
import Testing
@testable import Dictate

struct VocabularySuggestionStateTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aCorrectionIsSuggestedAtOnce() {
        var state = VocabularySuggestionState()
        let added = state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        #expect(added == 1)
        #expect(state.pending == [VocabularySuggestion(term: "Claude", reason: .corrected(from: "cloud"), date: date)])
    }

    @Test func termsAlreadyInTheVocabularyAreSkipped() {
        var state = VocabularySuggestionState()
        state.note([TermCorrection(wrong: "get hub", right: "GitHub")], vocabulary: ["github"], date: date)
        state.note([TermCorrection(wrong: "Orélien", right: "Aurélien")], vocabulary: ["Aurelien"], date: date)
        #expect(state.pending.isEmpty)
    }

    @Test func aTermIsSuggestedOnce() {
        var state = VocabularySuggestionState()
        state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        state.note([TermCorrection(wrong: "clode", right: "claude")], vocabulary: [], date: date)
        #expect(state.pending.count == 1)
    }

    @Test func ignoredTermsNeverComeBack() {
        var state = VocabularySuggestionState()
        state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        state.ignore("Claude")
        #expect(state.pending.isEmpty)
        state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        for _ in 0..<10 { state.noteRecurring(["Claude"], vocabulary: [], date: date) }
        #expect(state.pending.isEmpty)
        #expect(state.sightings.isEmpty)
    }

    @Test func recurringTermsAreSuggestedPastTheThreshold() {
        var state = VocabularySuggestionState()
        for _ in 1..<VocabularySuggestionState.recurrenceThreshold {
            state.noteRecurring(["Guillaume", "GitHub"], vocabulary: ["GitHub"], date: date)
        }
        #expect(state.pending.isEmpty)
        #expect(state.sightings["guillaume"]?.count == VocabularySuggestionState.recurrenceThreshold - 1)
        #expect(state.sightings["github"] == nil)

        let added = state.noteRecurring(["Guillaume"], vocabulary: ["GitHub"], date: date)
        #expect(added == 1)
        #expect(state.pending.map(\.term) == ["Guillaume"])
        #expect(state.pending.first?.reason == .recurring(count: VocabularySuggestionState.recurrenceThreshold))
        #expect(state.sightings.isEmpty)
    }

    @Test func sightingsAreCappedDroppingTheRarestFirst() {
        var state = VocabularySuggestionState()
        state.noteRecurring(["Frequent"], vocabulary: [], date: date)
        state.noteRecurring(["Frequent"], vocabulary: [], date: date)
        for index in 0..<VocabularySuggestionState.maxSightings {
            state.noteRecurring(["Term\(index)x"], vocabulary: [], date: date.addingTimeInterval(Double(index)))
        }
        #expect(state.sightings.count == VocabularySuggestionState.maxSightings)
        #expect(state.sightings["frequent"]?.count == 2)
        #expect(state.sightings["term0x"] == nil)
    }

    @Test func pendingSuggestionsAreCappedDroppingTheOldest() {
        var state = VocabularySuggestionState()
        for index in 0...VocabularySuggestionState.maxPending {
            state.note([TermCorrection(wrong: "x", right: "Name\(index)")], vocabulary: [], date: date)
        }
        #expect(state.pending.count == VocabularySuggestionState.maxPending)
        #expect(state.pending.first?.term == "Name1")
    }

    @Test func removedTermsMayComeBackLater() {
        var state = VocabularySuggestionState()
        state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        state.remove("claude")
        #expect(state.pending.isEmpty)
        state.note([TermCorrection(wrong: "cloud", right: "Claude")], vocabulary: [], date: date)
        #expect(state.pending.count == 1)
    }
}

@MainActor
struct VocabularySuggestionsTests {
    private let file = FileManager.default.temporaryDirectory
        .appending(path: "VocabularySuggestionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "suggestions.json")

    private func followUp(inserted: String, after: String) -> InsertionFollowUp {
        InsertionFollowUp(
            before: FieldSnapshot(text: "", selection: NSRange(location: 0, length: 0)),
            after: FieldSnapshot(text: after, selection: NSRange(location: (after as NSString).length, length: 0)),
            inserted: inserted
        )
    }

    @Test func missingFileStartsEmpty() {
        #expect(VocabularySuggestions(file: file).state == VocabularySuggestionState())
    }

    @Test func aFixedTermIsSuggested() {
        let suggestions = VocabularySuggestions(file: file)
        suggestions.consider(followUp(inserted: "On voit ça avec cloud.", after: "On voit ça avec Claude."), vocabulary: [])
        #expect(suggestions.pending(excluding: []).map(\.term) == ["Claude"])
    }

    @Test func anUnreadableFollowUpSuggestsNothing() {
        let suggestions = VocabularySuggestions(file: file)
        suggestions.consider(followUp(inserted: "On voit ça avec cloud.", after: ""), vocabulary: [])
        #expect(suggestions.state.pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func recurringNamesAreCountedFromThePrecedingText() {
        let suggestions = VocabularySuggestions(file: file)
        for _ in 0..<VocabularySuggestionState.recurrenceThreshold {
            suggestions.consider(precedingText: "Salut Guillaume, voici la PR.", vocabulary: ["PR"])
        }
        #expect(suggestions.pending(excluding: ["PR"]).map(\.term) == ["Guillaume"])
    }

    @Test func termsAddedToTheVocabularyByHandAreHidden() {
        let suggestions = VocabularySuggestions(file: file)
        suggestions.consider(followUp(inserted: "Avec cloud.", after: "Avec Claude."), vocabulary: [])
        #expect(suggestions.pending(excluding: ["claude"]).isEmpty)
    }

    @Test func everythingSurvivesARelaunch() {
        let suggestions = VocabularySuggestions(file: file)
        suggestions.consider(followUp(inserted: "Avec cloud et Marc.", after: "Avec Claude et Marc."), vocabulary: [])
        suggestions.consider(followUp(inserted: "Merci Orélien.", after: "Merci Aurélien."), vocabulary: [])
        suggestions.consider(precedingText: "Salut Guillaume,", vocabulary: [])
        suggestions.ignore(suggestions.state.pending[1])

        let reloaded = VocabularySuggestions(file: file)
        #expect(reloaded.state == suggestions.state)
        #expect(reloaded.state.pending.map(\.term) == ["Claude"])
        #expect(reloaded.state.ignored == ["aurélien".folding(options: .diacriticInsensitive, locale: nil)])
        #expect(reloaded.state.sightings["guillaume"]?.count == 1)
    }

    @Test func removingASuggestionPersists() {
        let suggestions = VocabularySuggestions(file: file)
        suggestions.consider(followUp(inserted: "Avec cloud.", after: "Avec Claude."), vocabulary: [])
        suggestions.remove(suggestions.state.pending[0])
        #expect(VocabularySuggestions(file: file).state.pending.isEmpty)
    }

    @Test func aDamagedFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(VocabularySuggestions(file: file).state == VocabularySuggestionState())
    }
}
