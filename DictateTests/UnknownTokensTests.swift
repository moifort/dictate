import Testing
@testable import Dictate

/// Parakeet has no quotation marks in its vocabulary: it writes its unknown
/// token where it hears one, after a bare `▁` piece.
struct UnknownTokensTests {
    private func text(_ pieces: [String]) -> String {
        UnknownTokens.text(fromPieces: UnknownTokens.resolved(pieces))
    }

    @Test func aPairBecomesFrenchGuillemets() {
        #expect(text(["▁s'", "appelait", "▁", "<unk>", "▁routine", "▁", "<unk>", "▁et"]) == "s'appelait « routine » et")
    }

    @Test func punctuationStaysGluedToTheClosingGuillemet() {
        let pieces = ["▁dire", "▁", "<unk>", "▁je", "▁ne", "▁suis", "▁pas", "▁intéressé", "▁", "<unk>", ",", "▁etc", "."]
        #expect(text(pieces) == "dire « je ne suis pas intéressé », etc.")
    }

    @Test func guillemetsGetTheirSpacesWhenTheModelGluesTheWords() {
        #expect(text(["▁dire", "▁<unk>", "oui", "<unk>", "▁puis"]) == "dire « oui » puis")
    }

    @Test func anUnpairedLastTokenIsDropped() {
        #expect(text(["▁il", "▁dit", "▁", "<unk>", "▁bonjour"]) == "il dit bonjour")
        #expect(text(["▁a", "▁", "<unk>", "▁b", "▁", "<unk>", "▁c", "▁", "<unk>"]) == "a « b » c")
    }

    @Test func aTokenInsideAWordIsDroppedNotQuoted() {
        // Most likely an @ or a &, which the vocabulary lacks too.
        #expect(text(["▁moi", "<unk>", "exemple", ".", "com"]) == "moiexemple.com")
    }

    @Test func piecesKeepTheirCountForTheTimings() {
        let pieces = ["▁", "<unk>", "▁routine", "▁", "<unk>"]
        #expect(UnknownTokens.resolved(pieces).count == pieces.count)
    }

    @Test func guillemetsAreWordsOfTheirOwn() {
        let pieces = UnknownTokens.resolved(["▁la", "▁", "<unk>", "▁routine", "▁", "<unk>", ","])
        let words = Transcription.words(fromTokens: pieces.map { ($0, 0.9) })
        #expect(words.map(\.text) == ["la", "«", "routine", "»,"])
    }

    @Test func piecesWithoutUnknownTokenAreUntouched() {
        let pieces = ["▁fais", "▁un", "▁pu", "sh", "."]
        #expect(UnknownTokens.resolved(pieces) == pieces)
        #expect(!UnknownTokens.containsUnknown(pieces))
        #expect(UnknownTokens.containsUnknown(["▁", "<unk>"]))
    }

    @Test func textAloneLosesItsUnknownTokens() {
        #expect(UnknownTokens.stripped("dire <unk> oui <unk>, puis") == "dire oui, puis")
        #expect(UnknownTokens.stripped("rien à signaler") == "rien à signaler")
    }
}
