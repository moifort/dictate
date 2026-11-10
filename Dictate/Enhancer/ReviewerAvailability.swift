import Foundation

/// Which reviewers can answer the next dictation, from what this Mac has.
/// A value, so the automatic choice can be tested without the app.
nonisolated struct ReviewerAvailability: Equatable, Sendable {
    /// The `claude` CLI is here and signed in.
    var claudeSubscriptionReady = false
    var claudeAccess: ClaudeAccess = .subscription
    var savedKeys: Set<APIProvider> = []
    var appleIntelligence = false
    /// The cloud reviewers stay out of the App Store build.
    var appStore = Distribution.isAppStore

    /// Claude can review, through the access the user picked.
    var claudeReady: Bool {
        switch claudeAccess {
        case .subscription: claudeSubscriptionReady
        case .apiKey: savedKeys.contains(.anthropic)
        }
    }

    func isReady(_ reviewer: Reviewer) -> Bool {
        switch reviewer {
        case .none: true
        case .apple: appleIntelligence
        case .claude: claudeReady
        case .openAI: savedKeys.contains(.openAI)
        case .gemini: savedKeys.contains(.gemini)
        }
    }

    /// Every reviewer that can answer now, in the order of preference.
    var detected: [Reviewer] {
        [Reviewer.claude, .openAI, .gemini, .apple].filter { (!$0.needsNetwork || !appStore) && isReady($0) }
    }

    /// Until the user picks, the first that can answer: Claude (its CLI here
    /// and signed in, or a key saved), then OpenAI, then Gemini with their
    /// keys, then the on-device model, else the raw transcript.
    var automatic: Reviewer { detected.first ?? .none }
}
