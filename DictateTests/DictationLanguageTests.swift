import Foundation
import Testing
@testable import Dictate

struct DictationLanguageTests {
    @Test func followsTheOSLanguageWhenSupported() {
        #expect(DictationLanguage.preferred(from: ["fr-FR"]) == "fr")
        #expect(DictationLanguage.preferred(from: ["en-US"]) == "en")
        #expect(DictationLanguage.preferred(from: ["pt-BR"]) == "pt")
        // The interface has no German, but the dictation language must be German.
        #expect(DictationLanguage.preferred(from: ["de-DE", "en-US"]) == "de")
    }

    @Test func skipsUnsupportedLanguagesForTheNextOne() {
        #expect(DictationLanguage.preferred(from: ["ja-JP", "it-IT"]) == "it")
    }

    @Test func fallsBackToEnglishForUnsupportedLanguages() {
        #expect(DictationLanguage.preferred(from: ["gsw-CH"]) == "en")
        #expect(DictationLanguage.preferred(from: []) == "en")
    }

    @Test func namesLanguagesInFrench() {
        #expect(DictationLanguage.name(of: "fr") == "français")
        #expect(DictationLanguage.name(of: "en") == "anglais")
    }

    @Test func pickerListsEverySupportedLanguageSortedByName() {
        #expect(Set(DictationLanguage.pickerCodes) == DictationLanguage.supportedCodes)
        for locale in [Locale(identifier: "fr"), Locale(identifier: "en")] {
            let names = DictationLanguage.pickerCodes(in: locale).map { DictationLanguage.name(of: $0, in: locale) }
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test func namesLanguagesInTheGivenLocale() {
        #expect(DictationLanguage.name(of: "de", in: Locale(identifier: "en")) == "German")
        #expect(DictationLanguage.name(of: "de", in: Locale(identifier: "fr")) == "allemand")
    }
}
