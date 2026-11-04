import Foundation

/// The model that cleans up each transcript, picked in the settings.
nonisolated enum Reviewer: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The raw transcript is inserted as is.
    case none
    /// Apple's on-device model, through Apple Intelligence.
    case apple
    /// Claude Haiku 4.5, through the `claude` CLI and the user's subscription,
    /// or through the API and the user's key (`ClaudeAccess`).
    case claude
    /// OpenAI's fastest model, through the user's API key.
    case openAI = "openai"
    /// Google's fastest Gemini, through the user's API key.
    case gemini

    var id: String { rawValue }

    /// The cloud reviewers stay out of the App Store build: Claude's CLI is
    /// beyond the sandbox, and that build keeps everything on the Mac.
    var isAvailable: Bool { !needsNetwork || !Distribution.isAppStore }

    /// Offline, these give way to the on-device model.
    var needsNetwork: Bool {
        switch self {
        case .claude, .openAI, .gemini: true
        case .none, .apple: false
        }
    }

    /// The service reached with an API key; Claude has one too, besides its subscription.
    var apiProvider: APIProvider? {
        switch self {
        case .claude: .anthropic
        case .openAI: .openAI
        case .gemini: .gemini
        case .none, .apple: nil
        }
    }

    var displayName: String {
        switch self {
        case .none: "Aucun"
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .apple: "apple.intelligence"
        case .claude: "sparkles"
        case .openAI: "bubble.left.and.text.bubble.right"
        case .gemini: "star.circle"
        }
    }
}
