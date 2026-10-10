import Foundation
import Testing
@testable import Dictate

@MainActor
struct AppSettingsTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
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
