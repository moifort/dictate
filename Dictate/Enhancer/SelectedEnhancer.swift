import Foundation
import DictateKit

nonisolated enum SelectedEnhancerError: LocalizedError {
    case noReviewer

    var errorDescription: String? { String(localized: "Aucun relecteur choisi.") }
}

/// An enhancer that keeps something ready between dictations.
@MainActor protocol WarmableEnhancer: Enhancer {
    func prewarm()
    func reset()
    func shutdown()
}

extension ClaudeCLIEnhancer: WarmableEnhancer {}
extension AppleIntelligenceEnhancer: WarmableEnhancer {}

/// Routes each dictation to the reviewer picked in the settings. Every
/// enhancer stays around: switching is instant and nothing is reloaded.
///
/// The cloud reviewers need the network: without it, or when one fails, the
/// on-device model steps in when this Mac has it, so dictation keeps
/// working offline without the user touching anything.
final class SelectedEnhancer: Enhancer {
    private let reviewer: () -> Reviewer
    private let isOnline: () -> Bool
    private let appleAvailable: () -> Bool
    let apple: any WarmableEnhancer
    let claude: any WarmableEnhancer
    /// OpenAI and Gemini, through the user's keys: nothing to keep warm.
    let others: [Reviewer: any Enhancer]
    /// The reviewers whose last cleanup failed in a way that lasts: signed
    /// out, key refused, limit reached. Every dictation then goes to the
    /// fallback or in raw until the reviewer answers again: the indicator
    /// and the menu say so.
    private(set) var problems: [Reviewer: ReviewFailure] = [:]

    init(
        reviewer: @escaping () -> Reviewer,
        isOnline: @escaping () -> Bool = { true },
        appleAvailable: @escaping () -> Bool = { AppleIntelligenceEnhancer.status.isAvailable },
        apple: any WarmableEnhancer,
        claude: any WarmableEnhancer,
        others: [Reviewer: any Enhancer] = [:]
    ) {
        self.reviewer = reviewer
        self.isOnline = isOnline
        self.appleAvailable = appleAvailable
        self.apple = apple
        self.claude = claude
        self.others = others
    }

    var plannedReviewer: Reviewer? { effectiveReviewer }

    /// The reviewer the next dictation will actually go to.
    var effectiveReviewer: Reviewer {
        let chosen = reviewer()
        return chosen.needsNetwork && !isOnline() && appleAvailable() ? .apple : chosen
    }

    /// Only the reviewer about to be used is warmed up: a `claude` process
    /// costs seconds to start and the on-device model takes memory.
    func prewarm() {
        switch effectiveReviewer {
        case .apple: apple.prewarm()
        case .claude: claude.prewarm()
        case .none, .openAI, .gemini: break
        }
    }

    /// The prompt or the choice changed: drop what is waiting and warm up the right one.
    func reset() {
        switch effectiveReviewer {
        case .apple:
            claude.shutdown()
            apple.reset()
        case .claude:
            apple.shutdown()
            claude.reset()
        case .none, .openAI, .gemini:
            apple.shutdown()
            claude.shutdown()
        }
    }

    func shutdown() {
        apple.shutdown()
        claude.shutdown()
    }

    /// The lasting problem of `reviewer`'s last cleanup, nil once it answered.
    func problem(of reviewer: Reviewer) -> ReviewFailure? { problems[reviewer] }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        try await review(transcription, context: context).text
    }

    func review(_ transcription: Transcription, context: DictationContext) async throws -> Review {
        let chosen = reviewer()
        switch chosen {
        case .none:
            throw SelectedEnhancerError.noReviewer
        case .apple:
            return try await ask(.apple, apple, transcription, context)
        case .claude, .openAI, .gemini:
            if !isOnline(), appleAvailable() {
                Log.dictation.info("offline: Apple Intelligence reviews instead of \(chosen.rawValue, privacy: .public)")
                return Review(text: try await apple.enhance(transcription, context: context), reviewer: .apple)
            }
            guard let remote = chosen == .claude ? claude : others[chosen] else {
                throw SelectedEnhancerError.noReviewer
            }
            do {
                return try await ask(chosen, remote, transcription, context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard appleAvailable() else { throw error }
                let name = chosen.rawValue
                switch ReviewFailure(error) {
                case .rateLimited:
                    // The limit is spent until it resets: not a failure to look into.
                    Log.dictation.notice("\(name, privacy: .public) usage limit reached, Apple Intelligence reviews instead")
                    ErrorReporter.breadcrumb("\(name) usage limit reached, falling back to Apple Intelligence", category: "enhancer")
                case .disconnected:
                    // Only the user can sign in again or fix the key: the indicator or the menu tells them.
                    Log.dictation.notice("\(name, privacy: .public) signed out or key refused, Apple Intelligence reviews instead")
                    ErrorReporter.breadcrumb("\(name) signed out or key refused, falling back to Apple Intelligence", category: "enhancer")
                case .timedOut, .diverged, .other:
                    Log.dictation.error("\(name, privacy: .public) failed, Apple Intelligence reviews instead: \(error.localizedDescription, privacy: .public)")
                    ErrorReporter.capture(error, "\(name) failed, falling back to Apple Intelligence", category: "enhancer", level: .warning)
                }
                return Review(text: try await apple.enhance(transcription, context: context), reviewer: .apple)
            }
        }
    }

    /// One reviewer's cleanup, remembering a lasting problem until it answers again.
    private func ask(
        _ reviewer: Reviewer, _ enhancer: any Enhancer, _ transcription: Transcription, _ context: DictationContext
    ) async throws -> Review {
        do {
            let text = try await enhancer.enhance(transcription, context: context)
            problems[reviewer] = nil
            return Review(text: text, reviewer: reviewer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = ReviewFailure(error)
            problems[reviewer] = failure.lasts ? failure : nil
            throw error
        }
    }
}
