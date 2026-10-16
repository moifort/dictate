import Testing
@testable import Dictate

struct DoubtfulWordsTests {
    private func transcription(_ text: String, _ confidences: [Float]) -> Transcription {
        let words = zip(text.split(separator: " "), confidences).map { Transcription.Word(text: String($0), confidence: $1) }
        return Transcription(text: text, words: words)
    }

    @Test func wrapsOnlyWordsBelowTheThreshold() {
        let marked = DoubtfulWords.mark(transcription("déploie sur Kubernetis demain", [0.99, 0.95, 0.3, 0.9]))
        #expect(marked == "déploie sur <?>Kubernetis</?> demain")
    }

    @Test func keepsPunctuationOutsideTheMarkers() {
        let marked = DoubtfulWords.mark(transcription("fais un pouche, puis (rebaise).", [0.9, 0.9, 0.2, 0.9, 0.1]))
        #expect(marked == "fais un <?>pouche</?>, puis (<?>rebaise</?>).")
    }

    @Test func neverWrapsTheUnknownToken() {
        let marked = DoubtfulWords.mark(transcription("dire <unk> oui <unk>, moi<unk>exemple", [0.9, 0.1, 0.2, 0.1, 0.1]))
        #expect(marked == "dire <unk> <?>oui</?> <unk>, moi<unk>exemple")
    }

    @Test func leavesTheTextAloneWhenEveryWordIsConfident() {
        #expect(DoubtfulWords.mark(transcription("fais un push", [0.9, 0.8, 0.5])) == "fais un push")
    }

    @Test func leavesTheTextAloneWithoutConfidences() {
        #expect(DoubtfulWords.mark(Transcription(text: "fais un pouche")) == "fais un pouche")
    }

    @Test func skipsWordsTheTimingsDoNotHave() {
        // The transcript has a word the timings lack: the rest still lines up.
        let words = [Transcription.Word(text: "fais", confidence: 0.9), .init(text: "pouche", confidence: 0.2)]
        let marked = DoubtfulWords.mark(Transcription(text: "fais un pouche", words: words))
        #expect(marked == "fais un <?>pouche</?>")
    }

    @Test func leavesAWordUnmarkedWhenTheTimingsDisagree() {
        let words = [Transcription.Word(text: "pouch", confidence: 0.2)]
        #expect(DoubtfulWords.mark(Transcription(text: "fais un pouche", words: words)) == "fais un pouche")
    }

    @Test func repeatedWordsAreMatchedInOrder() {
        let marked = DoubtfulWords.mark(transcription("le test le", [0.9, 0.9, 0.2]))
        #expect(marked == "le test <?>le</?>")
    }

    @Test func stripRemovesEveryMarker() {
        #expect(DoubtfulWords.strip("déploie sur <?>Kubernetes</?>, <?>puis</?>") == "déploie sur Kubernetes, puis")
        #expect(DoubtfulWords.strip("rien à retirer") == "rien à retirer")
    }
}
