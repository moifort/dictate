import Foundation
import WhisperKit

/// The language Whisper is told to expect, as an ISO 639-1 code ("fr").
///
/// Forcing it skips Whisper's language detection and keeps a dictation from
/// drifting into another language on a hesitation or an English term.
nonisolated enum DictationLanguage {
    /// Every code Whisper large-v3 understands.
    static let supportedCodes: Set<String> = Constants.languageCodes

    /// What Whisper falls back to when the OS language is not one of its own.
    static let fallback = "en"

    /// The OS language, when Whisper supports it.
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
