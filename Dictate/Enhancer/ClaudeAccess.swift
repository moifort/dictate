import Foundation

/// How Dictate reaches Claude. The subscription is the default: most users
/// already pay for Claude, and the CLI they signed in to costs nothing more.
nonisolated enum ClaudeAccess: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The `claude` CLI and the account signed in to it.
    case subscription
    /// The Messages API, billed per token on the user's Anthropic key.
    case apiKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subscription: String(localized: "Abonnement")
        case .apiKey: String(localized: "Clé API")
        }
    }
}
