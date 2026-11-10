import Foundation

/// Why a cleanup failed, whatever the reviewer: one reading of the errors for
/// the controller, the fallback to Apple Intelligence and the user's messages.
nonisolated enum ReviewFailure: Equatable, Sendable {
    /// Signed out of Claude, or the API key was refused: only the user can fix it.
    case disconnected
    /// The subscription's or the key's limit is spent until it resets.
    case rateLimited
    /// Cut off by the controller's deadline.
    case timedOut
    /// The reply had little left of the dictation: the guard did its job.
    case diverged
    /// Anything else: a failure to look into.
    case other

    init(_ error: Error) {
        switch error {
        case is CancellationError: self = .timedOut
        case let error as ClaudeCLIError where error.isDisconnected: self = .disconnected
        case let error as ClaudeCLIError where error.isUsageLimit: self = .rateLimited
        case let error as APIReviewError where error.isKeyProblem: self = .disconnected
        case let error as APIReviewError where error.isRateLimited: self = .rateLimited
        case AppleIntelligenceError.diverged: self = .diverged
        default: self = .other
        }
    }

    /// The failures that last until the user acts or the limit resets: they
    /// are shown, and remembered until the reviewer answers again.
    var lasts: Bool { self == .disconnected || self == .rateLimited }
}

/// A cleaned-up text and the reviewer that wrote it, fallbacks included.
nonisolated struct Review: Equatable, Sendable {
    var text: String
    /// Nil when the enhancer cannot tell.
    var reviewer: Reviewer?
}
