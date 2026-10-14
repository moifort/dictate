import Foundation
import Testing
@testable import Dictate

struct InsertedSegmentTests {
    private func caret(_ text: String, at offset: Int? = nil) -> FieldSnapshot {
        FieldSnapshot(text: text, selection: NSRange(location: offset ?? (text as NSString).length, length: 0))
    }

    @Test func untouchedPasteIsFoundAsIs() {
        let corrected = InsertedSegment.locate(
            inserted: "Fais un push.", before: caret("Salut, "), after: "Salut, Fais un push."
        )
        #expect(corrected == "Fais un push.")
    }

    @Test func fixesInsideThePasteAreKept() {
        let corrected = InsertedSegment.locate(
            inserted: "Fais un pouche.", before: caret("Salut, "), after: "Salut, fais un push."
        )
        #expect(corrected == "fais un push.")
    }

    @Test func textAfterTheCaretIsLeftOut() {
        let before = caret("Bonjour  à demain", at: 8)
        let corrected = InsertedSegment.locate(
            inserted: "je relis la PR", before: before, after: "Bonjour je relis la pull request à demain"
        )
        #expect(corrected == "je relis la pull request")
    }

    @Test func aReplacedSelectionIsNotPartOfTheReference() {
        let before = FieldSnapshot(text: "Il faut XXX demain.", selection: NSRange(location: 8, length: 3))
        let corrected = InsertedSegment.locate(
            inserted: "merger", before: before, after: "Il faut merger demain."
        )
        #expect(corrected == "merger")
    }

    @Test func editsEarlierInTheFieldAreSkippedThanksToTheAnchor() {
        let prefix = "Bonjour Guillaume, voici le point de la semaine sur le projet. "
        let after = "Bonjour Guillaume et Marie, voici le point de la semaine sur le projet. On livre lundi."
        let corrected = InsertedSegment.locate(inserted: "On livre lundi.", before: caret(prefix), after: after)
        #expect(corrected == "On livre lundi.")
    }

    @Test func aClearedFieldHasNoReference() {
        #expect(InsertedSegment.locate(inserted: "Fais un push.", before: caret("Salut, "), after: "") == nil)
    }

    @Test func aFieldNowHoldingSomethingElseHasNoReference() {
        let other = String(repeating: "Un tout autre message, bien plus long. ", count: 10)
        #expect(InsertedSegment.locate(inserted: "OK", before: caret(""), after: other) == nil)
    }

    @Test func utf16OffsetsAreHonoured() {
        // The emoji takes two UTF-16 units, like AX ranges count it.
        let before = caret("👋 ", at: 3)
        #expect(InsertedSegment.locate(inserted: "salut", before: before, after: "👋 salut") == "salut")
    }
}

@MainActor
struct PostInsertionObserverTests {
    @Test func readsTheSameFieldAgainAfterTheDelay() async {
        let field = FakeField(text: "Salut, ")
        let observer = PostInsertionObserver(reader: FakeReader(field: field), delay: .milliseconds(20))
        let watch = observer.watchFocusedField()
        #expect(watch?.before.text == "Salut, ")

        field.text = "Salut, Fais un pouche."
        let followUp = Task { await observer.followUp(watch!, inserted: "Fais un pouche.") }
        // The user fixes the word before the delay is up.
        field.text = "Salut, fais un push."
        let result = await followUp.value
        #expect(result?.after.text == "Salut, fais un push.")
        #expect(result?.corrected == "fais un push.")
        #expect(!observer.hasPendingFollowUps)
    }

    @Test func settleReadsWaitingFieldsAtOnce() async {
        let field = FakeField(text: "")
        let observer = PostInsertionObserver(reader: FakeReader(field: field), delay: .seconds(60))
        let watch = observer.watchFocusedField()!
        field.text = "Premier."
        let followUp = Task { await observer.followUp(watch, inserted: "Premier.") }
        while !observer.hasPendingFollowUps { await Task.yield() }
        observer.settle()
        field.text = "Premier. Second."
        #expect(await followUp.value?.corrected == "Premier.")
    }

    @Test func noFocusedFieldMeansNothingToWatch() {
        let observer = PostInsertionObserver(reader: FakeReader(field: nil))
        #expect(observer.watchFocusedField() == nil)
    }

    @Test func aFieldGoneByThenGivesNoFollowUp() async {
        let field = FakeField(text: "Salut, ")
        let observer = PostInsertionObserver(reader: FakeReader(field: field), delay: .milliseconds(10))
        let watch = observer.watchFocusedField()!
        field.readable = false
        #expect(await observer.followUp(watch, inserted: "OK") == nil)
    }
}

@MainActor
private final class FakeField: ReadableField {
    var text: String
    var readable = true

    init(text: String) { self.text = text }

    /// The caret at the end, as after typing or pasting.
    func snapshot() -> FieldSnapshot? {
        readable ? FieldSnapshot(text: text, selection: NSRange(location: (text as NSString).length, length: 0)) : nil
    }
}

@MainActor
private final class FakeReader: FieldReading {
    let field: FakeField?

    init(field: FakeField?) { self.field = field }

    func focusedField() -> (any ReadableField)? { field }
}
