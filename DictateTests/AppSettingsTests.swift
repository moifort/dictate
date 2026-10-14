import Foundation
import Testing
@testable import Dictate

@MainActor
struct AppSettingsTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    @Test func languageStartsAsTheOSLanguageAndIsNotConfirmed() {
        let settings = makeSettings()
        #expect(settings.language == DictationLanguage.preferred())
        #expect(!settings.languageConfirmed)
    }

    @Test func languageAndConfirmationPersist() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = "en"
        settings.languageConfirmed = true
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.language == "en")
        #expect(reloaded.languageConfirmed)
    }

    @Test func evaluationCorpusIsOffByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(!settings.keepEvaluationCorpus)
        settings.keepEvaluationCorpus = true
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).keepEvaluationCorpus)
    }

    @Test func vocabularySuggestionsAreOffByDefaultAndPersist() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(!settings.suggestVocabulary)
        settings.suggestVocabulary = true
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).suggestVocabulary)
    }

    @Test func aTermIsAddedOnItsOwnLine() {
        let settings = makeSettings()
        settings.vocabularyText = "GitHub\nSwift\n"
        settings.addToVocabulary("Claude")
        #expect(settings.vocabulary == ["GitHub", "Swift", "Claude"])
        settings.vocabularyText = ""
        settings.addToVocabulary("Claude")
        #expect(settings.vocabularyText == "Claude")
    }

    @Test func vocabularyBoostingIsOffByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(!settings.boostVocabulary)
        #expect(settings.boostedVocabulary.isEmpty)
        settings.boostVocabulary = true
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).boostVocabulary)
    }

    @Test func boostedVocabularyIsTheVocabularyOnlyWhenBoostingIsOn() {
        let settings = makeSettings()
        settings.vocabularyText = "Kubernetes\n  \nClaude Code "
        #expect(settings.boostedVocabulary.isEmpty)
        settings.boostVocabulary = true
        #expect(settings.boostedVocabulary == ["Kubernetes", "Claude Code"])
        settings.vocabularyText = ""
        #expect(settings.boostedVocabulary.isEmpty)
    }

    @Test func fieldContextIsSharedByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(settings.shareFieldContext)
        settings.shareFieldContext = false
        #expect(!AppSettings(defaults: UserDefaults(suiteName: suite)!).shareFieldContext)
    }

    @Test func pushToTalkKeyIsControlByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(settings.pushToTalkKey == .control)
        settings.pushToTalkKey = .fn
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).pushToTalkKey == .fn)
    }

    @Test func transcriptionEngineIsParakeetByDefault() {
        #expect(makeSettings().transcriptionEngine == .parakeet)
    }

    @Test func aSavedWhisperEngineFallsBackToParakeet() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        defaults.set("whisper", forKey: "transcriptionEngine")
        #expect(AppSettings(defaults: defaults).transcriptionEngine == .parakeet)
    }

    @Test func aLanguageOnlyWhisperUnderstoodIsAskedAgain() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        defaults.set("ja", forKey: "language")
        defaults.set(true, forKey: "languageConfirmed")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.language == DictationLanguage.preferred())
        #expect(!settings.languageConfirmed)
    }
}
