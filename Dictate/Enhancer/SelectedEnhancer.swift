import Foundation

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

/// Routes each dictation to the reviewer picked in the settings. Both
/// enhancers stay around: switching is instant and nothing is reloaded.
///
/// Claude needs the network: without it, or when Claude fails, the
/// on-device model steps in when this Mac has it, so dictation keeps
/// working offline without the user touching anything.
final class SelectedEnhancer: Enhancer {
    private let reviewer: () -> Reviewer
    private let isOnline: () -> Bool
    private let appleAvailable: () -> Bool
    let apple: any WarmableEnhancer
    let claude: any WarmableEnhancer
    /// The reviewer the last dictation actually went to, fallbacks included;
    /// nil before the first one. Read by the statistics after each cleanup.
    private(set) var lastUsed: Reviewer?
    /// The last Claude cleanup failed because the CLI is signed out or the
    /// API key was refused. Every
    /// dictation then silently goes to the fallback: the indicator says so.
    private(set) var isClaudeDisconnected = false

    init(
        reviewer: @escaping () -> Reviewer,
        isOnline: @escaping () -> Bool = { true },
        appleAvailable: @escaping () -> Bool = { AppleIntelligenceEnhancer.status.isAvailable },
        apple: any WarmableEnhancer,
        claude: any WarmableEnhancer
    ) {
        self.reviewer = reviewer
        self.isOnline = isOnline
        self.appleAvailable = appleAvailable
        self.apple = apple
        self.claude = claude
    }

    /// The reviewer the next dictation will actually go to.
    var effectiveReviewer: Reviewer {
        switch reviewer() {
        case .claude where !isOnline() && appleAvailable(): .apple
        case let chosen: chosen
        }
    }

    /// Only the reviewer about to be used is warmed up: a `claude` process
    /// costs seconds to start and the on-device model takes memory.
    func prewarm() {
        switch effectiveReviewer {
        case .apple: apple.prewarm()
        case .claude: claude.prewarm()
        case .none: break
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
        case .none:
            throw SelectedEnhancerError.noReviewer
        case .apple:
            lastUsed = .apple
            return try await apple.enhance(transcription, context: context)
        case .claude:
            if !isOnline(), appleAvailable() {
                Log.dictation.info("offline: Apple Intelligence reviews instead of Claude")
                lastUsed = .apple
                return try await apple.enhance(transcription, context: context)
            }
            lastUsed = .claude
            do {
                let text = try await claude.enhance(transcription, context: context)
                isClaudeDisconnected = false
                return text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                isClaudeDisconnected = (error as? ClaudeCLIError)?.isDisconnected == true
                    || [.invalidKey, .missingKey].contains(error as? ClaudeAPIError)
                guard appleAvailable() else { throw error }
                if (error as? ClaudeCLIError)?.isUsageLimit == true || error as? ClaudeAPIError == .rateLimited {
                    // The subscription's limit is spent until it resets: not a failure to look into.
                    Log.dictation.notice("claude usage limit reached, Apple Intelligence reviews instead")
                    ErrorReporter.breadcrumb("claude usage limit reached, falling back to Apple Intelligence", category: "enhancer")
                } else if isClaudeDisconnected {
                    // Only the user can sign in again: the indicator tells them.
                    Log.dictation.notice("claude signed out, Apple Intelligence reviews instead")
                    ErrorReporter.breadcrumb("claude signed out, falling back to Apple Intelligence", category: "enhancer")
                } else {
                    Log.dictation.error("claude failed, Apple Intelligence reviews instead: \(error.localizedDescription, privacy: .public)")
                    ErrorReporter.capture(error, "claude failed, falling back to Apple Intelligence", category: "enhancer", level: .warning)
                }
                lastUsed = .apple
                return try await apple.enhance(transcription, context: context)
            }
        }
    }
}
