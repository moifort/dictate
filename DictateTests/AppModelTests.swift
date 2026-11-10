import Foundation
import Testing
@testable import Dictate

/// What the menu and the indicator say about a reviewer that cannot answer.
struct ReviewerProblemTests {
    @Test func everyReviewerHasItsOwnTitle() {
        #expect(OutcomeMessage.title(of: .disconnected, reviewer: .claude, access: .subscription) == "Claude déconnecté")
        #expect(OutcomeMessage.title(of: .disconnected, reviewer: .claude, access: .apiKey) == "Clé Claude refusée")
        #expect(OutcomeMessage.title(of: .disconnected, reviewer: .openAI, access: .subscription) == "Clé OpenAI refusée")
        #expect(OutcomeMessage.title(of: .rateLimited, reviewer: .gemini, access: .subscription) == "Limite Gemini atteinte")
    }

    @Test func theExplanationSaysWhatToDo() {
        #expect(OutcomeMessage.explanation(of: .disconnected, reviewer: .claude, access: .subscription)
            == "Claude est déconnecté : lancez « claude auth login » dans un terminal.")
        #expect(OutcomeMessage.explanation(of: .disconnected, reviewer: .gemini, access: .subscription)
            == APIReviewError.invalidKey(.gemini).localizedDescription)
        #expect(OutcomeMessage.explanation(of: .rateLimited, reviewer: .openAI, access: .subscription)
            == APIReviewError.rateLimited(.openAI).localizedDescription)
        #expect(OutcomeMessage.explanation(of: .rateLimited, reviewer: .claude, access: .apiKey)
            == APIReviewError.rateLimited(.anthropic).localizedDescription)
    }
}

/// Every error, whatever the reviewer, read the same way.
struct ReviewFailureTests {
    @Test func errorsAreClassified() {
        #expect(ReviewFailure(CancellationError()) == .timedOut)
        #expect(ReviewFailure(ClaudeCLIError.failed("Please run /login")) == .disconnected)
        #expect(ReviewFailure(ClaudeCLIError.failed("You've hit your session limit · resets 3:20pm")) == .rateLimited)
        #expect(ReviewFailure(APIReviewError.invalidKey(.openAI)) == .disconnected)
        #expect(ReviewFailure(APIReviewError.missingKey(.gemini)) == .disconnected)
        #expect(ReviewFailure(APIReviewError.rateLimited(.anthropic)) == .rateLimited)
        #expect(ReviewFailure(URLError(.timedOut)) == .other)
    }
}

/// Which reviewer the app picks until the user does.
struct ReviewerAvailabilityTests {
    @Test func claudeComesFirstThenTheKeysThenApple() {
        var mac = ReviewerAvailability(appleIntelligence: true, appStore: false)
        #expect(mac.automatic == .apple)
        mac.savedKeys = [.gemini]
        #expect(mac.automatic == .gemini)
        mac.savedKeys = [.gemini, .openAI]
        #expect(mac.automatic == .openAI)
        mac.claudeSubscriptionReady = true
        #expect(mac.automatic == .claude)
        #expect(mac.detected == [.claude, .openAI, .gemini, .apple])
    }

    @Test func nothingReadyMeansTheRawTranscript() {
        #expect(ReviewerAvailability(appStore: false).automatic == Reviewer.none)
    }

    /// Claude through a key needs the key, not the CLI.
    @Test func claudesAccessDecidesWhatItNeeds() {
        var mac = ReviewerAvailability(claudeSubscriptionReady: true, claudeAccess: .apiKey, appStore: false)
        #expect(!mac.claudeReady)
        mac.savedKeys = [.anthropic]
        #expect(mac.claudeReady)
    }

    @Test func theAppStoreBuildOnlyOffersAppleIntelligence() {
        let mac = ReviewerAvailability(claudeSubscriptionReady: true, savedKeys: [.openAI], appleIntelligence: true, appStore: true)
        #expect(mac.detected == [.apple])
    }
}

/// Typing a key picks its reviewer; removing it gives the choice back.
@MainActor
struct SaveAPIKeyTests {
    private func makeSettings() -> AppSettings {
        let stores = Dictionary(uniqueKeysWithValues: APIProvider.allCases.map { ($0, InMemorySecret()) })
        return AppSettings(defaults: UserDefaults(suiteName: "SaveAPIKeyTests-\(UUID().uuidString)")!, apiKeyStores: { stores[$0]! })
    }

    @Test func aSavedKeyPicksItsReviewer() {
        let settings = makeSettings()
        #expect(settings.saveAPIKey("  sk-openai \n", for: .openAI))
        #expect(settings.apiKey(.openAI) == "sk-openai")
        #expect(settings.reviewer == .openAI)
        #expect(settings.reviewerIsChosen)
    }

    @Test func removingTheKeyGivesTheChoiceBack() {
        let settings = makeSettings()
        _ = settings.saveAPIKey("sk-openai", for: .openAI)
        _ = settings.saveAPIKey("", for: .openAI)
        #expect(!settings.reviewerIsChosen)
    }

    @Test func anAnthropicKeySwitchesClaudeToTheAPIAndBack() {
        let settings = makeSettings()
        _ = settings.saveAPIKey("sk-ant", for: .anthropic)
        #expect(settings.claudeAccess == .apiKey)
        #expect(settings.reviewer == .claude)
        _ = settings.saveAPIKey("", for: .anthropic)
        #expect(settings.claudeAccess == .subscription)
        // Claude keeps the subscription: the choice stays.
        #expect(settings.reviewer == .claude)
    }
}

/// The menu's line after each dictation.
struct OutcomeMessageTests {
    @Test func aRawTextSaysWhoDidNotAnswer() {
        #expect(OutcomeMessage.error(for: .pasted(raw: true), .init(reviewer: .claude))
            == "Claude n'a pas répondu : texte brut inséré.")
        #expect(OutcomeMessage.error(for: .pasted(raw: true), .init(reviewer: .claude, cliFound: false))
            == ClaudeCLIError.notFound.localizedDescription)
        #expect(OutcomeMessage.error(for: .copied(raw: true), .init(reviewer: .gemini))
            == "L'API Gemini n'a pas répondu : texte brut inséré.")
        #expect(OutcomeMessage.error(for: .pasted(raw: true), .init(reviewer: .apple, appleExplanation: "Désactivé"))
            == "Désactivé")
        #expect(OutcomeMessage.error(for: .pasted(raw: true), .init(reviewer: .none)) == nil)
    }

    @Test func aGoodDictationClearsTheLine() {
        #expect(OutcomeMessage.error(for: .pasted(raw: false), .init(reviewer: .claude)) == nil)
        #expect(OutcomeMessage.error(for: .failed("Micro indisponible"), .init(reviewer: .claude)) == "Micro indisponible")
    }

    /// A lasting problem wins: it degrades every dictation until the user acts.
    @Test func aLastingProblemWins() {
        #expect(OutcomeMessage.error(for: .pasted(raw: false), .init(reviewer: .openAI, problem: .disconnected))
            == APIReviewError.invalidKey(.openAI).localizedDescription)
    }
}
