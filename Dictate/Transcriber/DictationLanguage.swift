import Foundation

/// The language being dictated, as an ISO 639-1 code ("fr").
///
/// Parakeet uses it to drop tokens from another alphabet, and Claude to know
/// which language it is cleaning up.
nonisolated enum DictationLanguage {
    /// The 25 European languages Parakeet TDT v3 and its Ultra post-training cover.
    static let supportedCodes: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// What the app falls back to when the OS language is not supported.
    static let fallback = "en"

    /// The OS language, when it is supported.
    static func preferred(for locale: Locale = .current) -> String {
        guard let code = locale.language.languageCode?.identifier.lowercased(), supportedCodes.contains(code) else {
            return fallback
        }
        return code
    }

    /// The language's name in French, for the UI and the Claude prompt.
    static func name(of code: String) -> String {
        Locale(identifier: "fr").localizedString(forLanguageCode: code) ?? code
    }

    /// All supported codes, sorted by their French name for a picker.
    static let pickerCodes: [String] = supportedCodes.sorted {
        name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending
    }
}
