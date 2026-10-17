import Foundation

nonisolated enum SelectedEnhancerError: LocalizedError {
    case noReviewer

    var errorDescription: String? { "Aucun relecteur choisi." }
}

/// Routes each dictation to the reviewer picked in the settings. Both
/// enhancers stay around: switching is instant and nothing is reloaded.
final class SelectedEnhancer: Enhancer {
    private let reviewer: () -> Reviewer
    let apple: AppleIntelligenceEnhancer
    let claude: ClaudeCLIEnhancer

    init(reviewer: @escaping () -> Reviewer, apple: AppleIntelligenceEnhancer, claude: ClaudeCLIEnhancer) {
        self.reviewer = reviewer
        self.apple = apple
        self.claude = claude
    }

    /// Only the chosen reviewer is warmed up: a `claude` process costs seconds
    /// to start and the on-device model takes memory.
    func prewarm() {
        switch reviewer() {
        case .apple: apple.prewarm()
        case .claude: claude.prewarm()
        case .none: break
        }
    }

    /// The prompt or the choice changed: drop what is waiting and warm up the right one.
    func reset() {
        switch reviewer() {
        case .apple:
            claude.shutdown()
            apple.reset()
        case .claude:
            apple.shutdown()
            claude.reset()
        case .none:
            apple.shutdown()
            claude.shutdown()
        }
    }

    func shutdown() {
        apple.shutdown()
        claude.shutdown()
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        switch reviewer() {
        case .apple: try await apple.enhance(transcription, context: context)
        case .claude: try await claude.enhance(transcription, context: context)
        case .none: throw SelectedEnhancerError.noReviewer
        }
    }
}
