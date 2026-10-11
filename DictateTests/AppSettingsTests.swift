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

    @Test func fieldContextIsSharedByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(settings.shareFieldContext)
        settings.shareFieldContext = false
        #expect(!AppSettings(defaults: UserDefaults(suiteName: suite)!).shareFieldContext)
    }

    @Test func whisperGetsTheVocabularyByDefault() {
        let settings = makeSettings()
        #expect(settings.guideWhisperWithVocabulary)
        #expect(settings.whisperVocabulary == settings.vocabulary)
    }

    @Test func whisperGetsNoVocabularyWhenClaudeAloneHandlesTheJargon() {
        let settings = makeSettings()
        settings.guideWhisperWithVocabulary = false
        #expect(settings.whisperVocabulary.isEmpty)
    }

    @Test func whisperGetsTheVocabularyWithoutClaude() {
        let settings = makeSettings()
        settings.enhancementEnabled = false
        #expect(settings.whisperVocabulary == settings.vocabulary)
    }
}
