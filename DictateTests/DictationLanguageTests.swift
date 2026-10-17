import Foundation
import Testing
@testable import Dictate

struct DictationLanguageTests {
    @Test func followsTheOSLanguageWhenSupported() {
        #expect(DictationLanguage.preferred(for: Locale(identifier: "fr_FR")) == "fr")
        #expect(DictationLanguage.preferred(for: Locale(identifier: "en_US")) == "en")
        #expect(DictationLanguage.preferred(for: Locale(identifier: "pt_BR")) == "pt")
    }

    @Test func fallsBackToEnglishForUnsupportedLanguages() {
        #expect(DictationLanguage.preferred(for: Locale(identifier: "gsw_CH")) == "en")
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
