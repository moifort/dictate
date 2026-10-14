import Foundation
import Testing
@testable import Dictate

struct TermTokenizerTests {
    private func terms(_ text: String) -> [String] {
        TermTokenizer.tokens(in: text).filter(TermTokenizer.looksLikeTerm).map(\.text)
    }

    @Test func punctuationAndElisionAreStripped() {
        let tokens = TermTokenizer.tokens(in: "On ouvre l'API, puis « Xcode ».")
        #expect(tokens.map(\.text) == ["On", "ouvre", "API", "puis", "Xcode"])
        #expect(tokens.map(\.key) == ["on", "ouvre", "api", "puis", "xcode"])
    }

    @Test func keysFoldCaseAccentsAndPunctuation() {
        #expect(TermTokenizer.key(of: "Aurélien") == "aurelien")
        #expect(TermTokenizer.key(of: "node.js") == "nodejs")
    }

    @Test func sentenceStartsAreMarked() {
        let tokens = TermTokenizer.tokens(in: "Bonjour Guillaume. Merci !\nÀ demain")
        #expect(tokens.map(\.text) == ["Bonjour", "Guillaume", "Merci", "À", "demain"])
        #expect(tokens.map(\.sentenceInitial) == [true, false, true, true, false])
    }

    @Test func capitalisedWordsCountOnlyInsideASentence() {
        #expect(terms("Bonjour Guillaume, on se voit chez Marie.") == ["Guillaume", "Marie"])
        #expect(terms("Thanks Sarah, see you at Stripe tomorrow.") == ["Sarah", "Stripe"])
    }

    @Test(arguments: ["API", "GitHub", "iPhone", "M1", "GPT-4", "node.js", "snake_case", "C++", "C#", "Jean-Pierre"])
    func technicalShapesAreTerms(word: String) {
        #expect(terms("Il faut \(word)") == [word])
    }

    @Test(arguments: ["push", "peut-être", "e.g", "2026", "I'm", "OK", "Monday", "a@b.fr", "https://x.fr"])
    func ordinaryWordsAreNot(word: String) {
        #expect(terms("Il faut \(word)").isEmpty)
    }

    @Test func englishPossessiveIsDropped() {
        #expect(terms("This is Guillaume's branch") == ["Guillaume"])
    }
}

struct CorrectedTermsTests {
    private func corrections(_ inserted: String, _ corrected: String) -> [TermCorrection] {
        CorrectedTerms.corrections(inserted: inserted, corrected: corrected)
    }

    @Test func aMisheardNameIsFound() {
        #expect(corrections("On se voit chez cloud demain.", "On se voit chez Claude demain.")
            == [TermCorrection(wrong: "cloud", right: "Claude")])
    }

    @Test func englishNameIsFound() {
        #expect(corrections("I pushed it to get hub yesterday.", "I pushed it to GitHub yesterday.")
            == [TermCorrection(wrong: "get hub", right: "GitHub")])
    }

    @Test func severalWordsBecomingOneTermAreFound() {
        #expect(corrections("On déploie sur cube are net is ce soir.", "On déploie sur Kubernetes ce soir.")
            == [TermCorrection(wrong: "cube are net is", right: "Kubernetes")])
    }

    @Test func aShortPhraseIsFound() {
        #expect(corrections("Ouvre visuel studio pour voir.", "Ouvre Visual Studio pour voir.")
            == [TermCorrection(wrong: "visuel studio", right: "Visual Studio")])
    }

    @Test func anAcronymIsFound() {
        #expect(corrections("Envoie le fichier à la S N C F.", "Envoie le fichier à la SNCF.")
            == [TermCorrection(wrong: "S N C F", right: "SNCF")])
    }

    @Test func aNameAfterTheFirstWordIsFound() {
        #expect(corrections("Merci Orélien.", "Merci Aurélien.") == [TermCorrection(wrong: "Orélien", right: "Aurélien")])
    }

    @Test func aCapitalisedWordStartingTheDictationIsMissed() {
        // Nothing tells "Aurélien" from "Les" in "Le" → "Les" there.
        #expect(corrections("Orélien", "Aurélien").isEmpty)
    }

    @Test func aCaseChangeNextToTheFixBelongsToTheTerm() {
        #expect(corrections("Ouvre visual code.", "Ouvre Visual Studio Code.")
            == [TermCorrection(wrong: "visual code", right: "Visual Studio Code")])
    }

    @Test func severalFixesInOneDictationAreAllFound() {
        let found = corrections(
            "Dis à Guyom que la PR sur swift UI est prête.",
            "Dis à Guillaume que la PR sur SwiftUI est prête."
        )
        #expect(found == [
            TermCorrection(wrong: "Guyom", right: "Guillaume"),
            TermCorrection(wrong: "swift UI", right: "SwiftUI"),
        ])
    }

    @Test func caseOnlyEditsAreIgnored() {
        #expect(corrections("on part à paris demain", "On part à Paris demain.").isEmpty)
    }

    @Test func accentOnlyEditsAreIgnored() {
        #expect(corrections("Merci Aurelien.", "Merci Aurélien.").isEmpty)
    }

    @Test func punctuationOnlyEditsAreIgnored() {
        #expect(corrections("Salut Marc ca va", "Salut Marc, ça va ?").isEmpty)
    }

    @Test func deletionsAndAdditionsAreIgnored() {
        #expect(corrections("Fais un push sur la branche Main.", "Fais un push.").isEmpty)
        #expect(corrections("Fais un push.", "Fais un push sur la branche Main.").isEmpty)
    }

    @Test func lowercaseWordsAreIgnored() {
        #expect(corrections("Fais un pouche.", "Fais un push.").isEmpty)
    }

    @Test func aChangeOfMindIsIgnored() {
        #expect(corrections("On se voit chez Marc demain.", "On se voit chez Sophie demain.").isEmpty)
    }

    @Test func aSentenceInitialCapitalIsNotATerm() {
        #expect(corrections("Le chat dort.", "Les chats dorment.").isEmpty)
    }

    @Test func aRewriteIsIgnored() {
        #expect(corrections(
            "Je pense qu'on devrait livrer la version demain matin avec Paul.",
            "Livraison reportée : on attend le retour de Pauline sur la version."
        ).isEmpty)
    }

    @Test func aLongReplacementIsIgnored() {
        #expect(corrections(
            "Demande à Marc de relire avant ce soir s'il te plaît.",
            "Demande à l'équipe Marketing Europe Ouest de relire avant ce soir s'il te plaît."
        ).isEmpty)
    }

    @Test func emptyTextsGiveNothing() {
        #expect(corrections("", "Claude").isEmpty)
        #expect(corrections("cloud", "").isEmpty)
    }
}

struct RecurringTermsTests {
    @Test func namesAndTechnicalWordsAreFoundOnce() {
        let text = "Salut Guillaume, j'ai poussé sur GitHub. Guillaume, tu peux relire la PR ?"
        #expect(RecurringTerms.terms(in: text) == ["Guillaume", "GitHub", "PR"])
    }

    @Test func theFirstWordMayBeCutAndIsSkipped() {
        #expect(RecurringTerms.terms(in: "itHub est en panne") == [])
    }

    @Test func sentenceInitialCapitalsAreSkipped() {
        #expect(RecurringTerms.terms(in: "ok. Merci. Demain on verra.").isEmpty)
    }
}
