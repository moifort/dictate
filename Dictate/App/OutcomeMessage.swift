import Foundation

/// What the menu and the indicator say about a finished dictation.
nonisolated enum OutcomeMessage {
    /// What a reviewer that did not answer leaves to say.
    struct Reviewing: Equatable {
        var reviewer: Reviewer
        var access: ClaudeAccess = .subscription
        var cliFound = true
        /// Why Apple Intelligence cannot answer, when it cannot.
        var appleExplanation: String?
        /// The reviewer's lasting problem, if any.
        var problem: ReviewFailure?
    }

    /// The menu's line for `outcome`, nil when there is nothing to say.
    static func error(for outcome: DictationOutcome, _ reviewing: Reviewing) -> String? {
        if let problem = reviewing.problem {
            return explanation(of: problem, reviewer: reviewing.reviewer, access: reviewing.access)
        }
        switch outcome {
        case .failed(let message):
            return message
        case .pasted(raw: true), .copied(raw: true):
            switch reviewing.reviewer {
            case .none:
                return nil
            case .apple:
                return reviewing.appleExplanation ?? String(localized: "Apple Intelligence n'a pas répondu : texte brut inséré.")
            case .claude where reviewing.access == .apiKey, .openAI, .gemini:
                return String(localized: "L'API \(reviewing.reviewer.displayName) n'a pas répondu : texte brut inséré.")
            case .claude:
                return reviewing.cliFound
                    ? String(localized: "Claude n'a pas répondu : texte brut inséré.")
                    : ClaudeCLIError.notFound.localizedDescription
            }
        default:
            return nil
        }
    }

    /// The reviewer's lasting problem in a few words, for the indicator.
    static func title(of problem: ReviewFailure, reviewer: Reviewer, access: ClaudeAccess) -> String {
        let name = reviewer.displayName
        let throughKey = reviewer != .claude || access == .apiKey
        return switch problem {
        case .rateLimited: String(localized: "Limite \(name) atteinte")
        case .disconnected where throughKey: String(localized: "Clé \(name) refusée")
        default: String(localized: "\(name) déconnecté")
        }
    }

    /// The reviewer's lasting problem and what to do about it, for the menu.
    static func explanation(of problem: ReviewFailure, reviewer: Reviewer, access: ClaudeAccess) -> String {
        let provider = reviewer == .claude && access == .subscription ? nil : reviewer.apiProvider
        return switch (problem, provider) {
        case (.rateLimited, let provider?): APIReviewError.rateLimited(provider).localizedDescription
        case (.rateLimited, nil): String(localized: "Limite d'utilisation de Claude atteinte : réessayez après sa réinitialisation.")
        case (_, let provider?): APIReviewError.invalidKey(provider).localizedDescription
        case (_, nil): String(localized: "Claude est déconnecté : lancez « claude auth login » dans un terminal.")
        }
    }
}
