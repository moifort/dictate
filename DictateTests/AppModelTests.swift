import Foundation
import Testing
@testable import Dictate

/// What the menu and the indicator say about a reviewer that cannot answer.
struct ReviewerProblemTests {
    @Test func everyReviewerHasItsOwnTitle() {
        #expect(AppModel.title(of: .disconnected, reviewer: .claude, access: .subscription) == "Claude déconnecté")
        #expect(AppModel.title(of: .disconnected, reviewer: .claude, access: .apiKey) == "Clé Claude refusée")
        #expect(AppModel.title(of: .disconnected, reviewer: .openAI, access: .subscription) == "Clé OpenAI refusée")
        #expect(AppModel.title(of: .rateLimited, reviewer: .gemini, access: .subscription) == "Limite Gemini atteinte")
    }

    @Test func theExplanationSaysWhatToDo() {
        #expect(AppModel.explanation(of: .disconnected, reviewer: .claude, access: .subscription)
            == "Claude est déconnecté : lancez « claude auth login » dans un terminal.")
        #expect(AppModel.explanation(of: .disconnected, reviewer: .gemini, access: .subscription)
            == APIReviewError.invalidKey(.gemini).localizedDescription)
        #expect(AppModel.explanation(of: .rateLimited, reviewer: .openAI, access: .subscription)
            == APIReviewError.rateLimited(.openAI).localizedDescription)
        #expect(AppModel.explanation(of: .rateLimited, reviewer: .claude, access: .apiKey)
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
