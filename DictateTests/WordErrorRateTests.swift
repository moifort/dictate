import Foundation
import Testing
@testable import Dictate

struct WordErrorRateTests {
    @Test func identicalTextsHaveNoErrors() {
        #expect(WordErrorRate.rate(reference: "fais un push sur main", hypothesis: "fais un push sur main") == 0)
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        // "pouche" for "push", "sur" dropped, "la" added: three edits over five words.
        let count = WordErrorRate.count(reference: "fais un push sur main", hypothesis: "fais un pouche main la")
        #expect(count == WordErrorRate.Count(errors: 3, referenceWords: 5))
        #expect(count.rate == 0.6)
    }

    @Test func caseAndPunctuationAreIgnoredByDefault() {
        #expect(WordErrorRate.rate(reference: "Fais un push, sur main.", hypothesis: "fais un push sur Main") == 0)
    }

    @Test func punctuationSplitsWordsOnBothSides() {
        #expect(WordErrorRate.words(in: "l'API — c'est prêt !") == ["l", "api", "c", "est", "prêt"])
    }

    @Test func normalizationCanBeTurnedOff() {
        let strict = WordErrorRate.Normalization(lowercase: false, stripPunctuation: false)
        #expect(WordErrorRate.count(reference: "Push.", hypothesis: "push", normalization: strict).errors == 1)
    }

    @Test func diacriticsCanBeFolded() {
        let folded = WordErrorRate.Normalization(foldDiacritics: true)
        #expect(WordErrorRate.rate(reference: "évènement", hypothesis: "evenement", normalization: folded) == 0)
        #expect(WordErrorRate.rate(reference: "évènement", hypothesis: "evenement") == 1)
    }

    @Test func emptyReferenceHasNoRate() {
        let count = WordErrorRate.count(reference: " ", hypothesis: "bonjour")
        #expect(count.errors == 1)
        #expect(count.rate == nil)
    }

    @Test func emptyHypothesisDeletesEveryWord() {
        #expect(WordErrorRate.rate(reference: "un deux trois", hypothesis: "") == 1)
    }

    @Test func countsAddUp() {
        let total = WordErrorRate.Count(errors: 1, referenceWords: 4) + WordErrorRate.Count(errors: 2, referenceWords: 6)
        #expect(total == WordErrorRate.Count(errors: 3, referenceWords: 10))
        #expect(total.rate == 0.3)
    }
}

struct SequenceAlignmentTests {
    @Test func theCommonSubsequenceKeepsTheOrder() {
        let pairs = SequenceAlignment.commonSubsequence(["a", "b", "c", "d"], ["a", "x", "c", "d"])
        #expect(pairs.map(\.0) == [0, 2, 3])
        #expect(pairs.map(\.1) == [0, 2, 3])
        #expect(SequenceAlignment.commonSubsequence([String](), ["a"]).isEmpty)
    }

    @Test func theEditDistanceCountsEveryEdit() {
        #expect(SequenceAlignment.editDistance(Array("kitten"), Array("sitting")) == 3)
        #expect(SequenceAlignment.editDistance(["a", "b"], []) == 2)
        #expect(SequenceAlignment.editDistance([Int](), [1, 2, 3]) == 3)
    }

    @Test func durationsReadInMillisecondsAndSeconds() {
        #expect(Duration.milliseconds(1_234).milliseconds == 1_234)
        #expect(Duration.milliseconds(1_500).timeInterval == 1.5)
    }

    /// The newest bundled CLI is found by comparing versions as numbers.
    @Test func versionsCompareAsNumbers() {
        #expect(Version("2.1.10") > Version("2.1.9"))
        #expect(!(Version("2.1") < Version("2.1.0")))
    }
}
