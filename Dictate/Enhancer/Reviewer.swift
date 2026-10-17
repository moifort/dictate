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

    /// Claude goes through the `claude` CLI, which the App Store sandbox cannot reach.
    var isAvailable: Bool { self != .claude || !Distribution.isAppStore }

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
