import Foundation
import Testing
@testable import Dictate

@MainActor
struct AppSettingsTests {
    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)
    }

    @Test func whisperGetsNoVocabularyByDefaultWhenClaudeCleansUp() {
        let settings = makeSettings()
        #expect(settings.enhancementEnabled)
        #expect(settings.whisperVocabulary.isEmpty)
    }

    @Test func whisperGetsTheVocabularyOnRequest() {
        let settings = makeSettings()
        settings.guideWhisperWithVocabulary = true
        #expect(settings.whisperVocabulary == settings.vocabulary)
    }

    @Test func whisperGetsTheVocabularyWithoutClaude() {
        let settings = makeSettings()
        settings.enhancementEnabled = false
        #expect(settings.whisperVocabulary == settings.vocabulary)
    }
}
