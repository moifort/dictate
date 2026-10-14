import Testing
@testable import Dictate

struct TranscriptionTests {
    @Test func subWordTokensFormWordsAtTheirWeakestPiece() {
        let words = Transcription.words(fromTokens: [
            (" dé", 0.99), ("ploie", 0.9), (" sur", 0.98), (" Ku", 0.95), ("ber", 0.4), ("netis", 0.7),
        ])
        #expect(words == [
            .init(text: "déploie", confidence: 0.9),
            .init(text: "sur", confidence: 0.98),
            .init(text: "Kubernetis", confidence: 0.4),
        ])
    }

    @Test func sentencePieceBoundaryMarkerOpensAWordToo() {
        let words = Transcription.words(fromTokens: [("▁fais", 0.9), ("▁un", 0.8), ("▁pu", 0.7), ("sh", 0.6)])
        #expect(words.map(\.text) == ["fais", "un", "push"])
        #expect(words.map(\.confidence) == [0.9, 0.8, 0.6])
    }

    @Test func firstTokenWithoutLeadingSpaceStillStartsAWord() {
        let words = Transcription.words(fromTokens: [("Bon", 0.9), ("jour", 0.8), (" à", 0.95)])
        #expect(words.map(\.text) == ["Bonjour", "à"])
    }

    @Test func punctuationStaysOnItsWordWithoutLoweringIt() {
        let words = Transcription.words(fromTokens: [(" push", 0.95), (",", 0.3), (" puis", 0.9), (".", 0.2)])
        #expect(words == [.init(text: "push,", confidence: 0.95), .init(text: "puis.", confidence: 0.9)])
    }

    @Test func aWordOfPunctuationAloneKeepsItsConfidence() {
        let words = Transcription.words(fromTokens: [(" ok", 0.9), (" ?", 0.3)])
        #expect(words.last == .init(text: "?", confidence: 0.3))
    }

    @Test func emptyAndBlankTokensAreSkipped() {
        #expect(Transcription.words(fromTokens: [("", 0.1), (" ", 0.2)]).isEmpty)
        #expect(Transcription.words(fromTokens: []).isEmpty)
    }

    @Test func lowestConfidenceIsNilWithoutWords() {
        #expect(Transcription(text: "x").lowestConfidence == nil)
        let words = [Transcription.Word(text: "a", confidence: 0.9), .init(text: "b", confidence: 0.3)]
        #expect(Transcription(text: "a b", words: words).lowestConfidence == 0.3)
    }
}
