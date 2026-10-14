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
        let names = DictationLanguage.pickerCodes.map { DictationLanguage.name(of: $0) }
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
