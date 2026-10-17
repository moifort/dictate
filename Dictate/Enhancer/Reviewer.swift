import Foundation

/// The model that cleans up each transcript, picked in the settings.
nonisolated enum Reviewer: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The raw transcript is inserted as is.
    case none
    /// Apple's on-device model, through Apple Intelligence.
    case apple
    /// Claude Haiku, through the `claude` CLI and the user's subscription.
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Aucun"
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .apple: "apple.intelligence"
        case .claude: "sparkles"
        }
    }
}
