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

    @Test func transcriptionEngineIsParakeetByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("fr", forKey: "language")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.transcriptionEngine == .parakeet)
        settings.transcriptionEngine = .whisper
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).transcriptionEngine == .whisper)
    }

    @Test func transcriptionEngineFallsBackToWhisperForLanguagesParakeetLacks() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        defaults.set("ja", forKey: "language")
        #expect(AppSettings(defaults: defaults).transcriptionEngine == .whisper)
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
