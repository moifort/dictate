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

    @Test func autoSendInClaudeIsOnByDefaultAndPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(settings.autoSendInClaude)
        settings.autoSendInClaude = false
        #expect(!AppSettings(defaults: UserDefaults(suiteName: suite)!).autoSendInClaude)
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

    @Test func reviewerFollowsTheDefaultUntilPickedThenPersists() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(!settings.reviewerIsChosen)
        #expect(settings.reviewer == .claude)
        settings.defaultReviewer = { .apple }
        #expect(settings.reviewer == .apple)
        #expect(settings.enhancementEnabled)
        settings.reviewer = .claude
        #expect(settings.reviewerIsChosen)
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        reloaded.defaultReviewer = { .apple }
        #expect(reloaded.reviewer == .claude)
    }

    @Test func noReviewerMeansNoEnhancement() {
        let settings = makeSettings()
        settings.reviewer = .none
        #expect(!settings.enhancementEnabled)
    }

    @Test func anEnhancementSwitchedOffByAnOlderVersionStaysOff() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: "enhancementEnabled")
        #expect(AppSettings(defaults: defaults).reviewer == Reviewer.none)
        defaults.set(true, forKey: "enhancementEnabled")
        #expect(!AppSettings(defaults: defaults).reviewerIsChosen)
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

    @Test func claudeGoesThroughTheSubscriptionByDefault() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!, apiKeyStores: { _ in InMemorySecret() })
        #expect(settings.claudeAccess == .subscription)
        #expect(APIProvider.allCases.allSatisfy { !settings.hasAPIKey($0) })
    }

    @Test func eachKeyPersistsApartAndStaysOutOfUserDefaults() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let stores = Dictionary(uniqueKeysWithValues: APIProvider.allCases.map { ($0, InMemorySecret()) })
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, apiKeyStores: { stores[$0]! })
        settings.claudeAccess = .apiKey
        settings.setAPIKey("sk-ant-test", for: .anthropic)
        settings.setAPIKey("AIza-test", for: .gemini)
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, apiKeyStores: { stores[$0]! })
        #expect(reloaded.claudeAccess == .apiKey)
        #expect(reloaded.apiKey(.anthropic) == "sk-ant-test")
        #expect(reloaded.apiKey(.gemini) == "AIza-test")
        #expect(!reloaded.hasAPIKey(.openAI))
        let stored = UserDefaults(suiteName: suite)!.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!stored.contains("sk-ant-test"))
        settings.setAPIKey("", for: .anthropic)
        #expect(stores[.anthropic]!.read() == nil)
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
