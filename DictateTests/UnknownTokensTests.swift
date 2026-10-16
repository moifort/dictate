import Testing
@testable import Dictate

/// Parakeet has no quotation marks in its vocabulary: it writes `<unk>` where
/// it hears one. Claude picks the right character from the context; this is
/// the fallback when Claude does not run or leaves one in.
struct UnknownTokensTests {
    @Test func aPairBecomesFrenchGuillemets() {
        #expect(UnknownTokens.resolved("s'appelait <unk> routine <unk> et") == "s'appelait « routine » et")
    }

    @Test func punctuationStaysGluedToTheClosingGuillemet() {
        #expect(
            UnknownTokens.resolved("dire <unk> je ne suis pas intéressé <unk>, etc.")
                == "dire « je ne suis pas intéressé », etc."
        )
    }

    @Test func guillemetsGetTheirSpacesWhenTheWordsAreGlued() {
        #expect(UnknownTokens.resolved("dire <unk>oui<unk> puis") == "dire « oui » puis")
        #expect(UnknownTokens.resolved("<unk>Routine<unk>.") == "« Routine ».")
    }

    @Test func anUnpairedTokenIsDropped() {
        #expect(UnknownTokens.resolved("il dit <unk> bonjour") == "il dit bonjour")
        #expect(UnknownTokens.resolved("il dit <unk>, bonjour") == "il dit, bonjour")
        #expect(UnknownTokens.resolved("a <unk> b <unk> c <unk>") == "a « b » c")
    }

    @Test func aTokenInsideAWordIsDroppedNotQuoted() {
        // Most likely an @ or a &, which the vocabulary lacks too.
        #expect(UnknownTokens.resolved("écris à moi<unk>exemple.com") == "écris à moiexemple.com")
    }

    @Test func textWithoutUnknownTokenIsUntouched() {
        #expect(UnknownTokens.resolved("Fais un push.") == "Fais un push.")
        #expect(UnknownTokens.resolved("  deux  espaces ") == "  deux  espaces ")
    }

    // MARK: - Pieces, before Claude

    private func quotedText(_ pieces: [String]) -> String {
        UnknownTokens.text(fromPieces: UnknownTokens.quoted(pieces))
    }

    @Test func piecesPairIntoGuillemets() {
        #expect(quotedText(["▁s'", "appelait", "▁", "<unk>", "▁routine", "▁", "<unk>", "▁et"]) == "s'appelait « routine » et")
        let pieces = ["▁dire", "▁", "<unk>", "▁je", "▁ne", "▁suis", "▁pas", "▁intéressé", "▁", "<unk>", ",", "▁etc", "."]
        #expect(quotedText(pieces) == "dire « je ne suis pas intéressé », etc.")
        #expect(quotedText(["▁dire", "▁<unk>", "oui", "<unk>", "▁puis"]) == "dire « oui » puis")
    }

    @Test func singleAndInnerTokensAreLeftForClaude() {
        #expect(quotedText(["▁ticket", "▁", "<unk>", "▁42"]) == "ticket <unk> 42")
        #expect(quotedText(["▁moi", "<unk>", "exemple", ".", "com"]) == "moi<unk>exemple.com")
        #expect(quotedText(["▁a", "▁", "<unk>", "▁b", "▁", "<unk>", "▁c", "▁", "<unk>"]) == "a « b » c <unk>")
    }

    @Test func quotedPiecesKeepTheirCountForTheTimings() {
        let pieces = ["▁", "<unk>", "▁routine", "▁", "<unk>", "▁", "<unk>"]
        #expect(UnknownTokens.quoted(pieces).count == pieces.count)
    }

    @Test func guillemetsAreWordsOfTheirOwn() {
        let pieces = UnknownTokens.quoted(["▁la", "▁", "<unk>", "▁routine", "▁", "<unk>", ","])
        let words = Transcription.words(fromTokens: pieces.map { ($0, 0.9) })
        #expect(words.map(\.text) == ["la", "«", "routine", "»,"])
    }

    @Test func piecesWithoutUnknownTokenAreUntouched() {
        let pieces = ["▁fais", "▁un", "▁pu", "sh", "."]
        #expect(UnknownTokens.quoted(pieces) == pieces)
        #expect(!UnknownTokens.containsUnknown(pieces))
        #expect(UnknownTokens.containsUnknown(["▁", "<unk>"]))
    }
}
