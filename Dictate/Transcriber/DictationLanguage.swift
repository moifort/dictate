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

    /// The first of the user's OS languages that is supported.
    ///
    /// Not `Locale.current`: its language is the app's localization, so a Mac
    /// in German would read "en", the interface's language, instead of "de".
    static func preferred(from languages: [String] = Locale.preferredLanguages) -> String {
        languages.lazy
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier.lowercased() }
            .first(where: supportedCodes.contains) ?? fallback
    }

    /// The language's name in French, for the Claude prompt, which is written in French.
    static func name(of code: String) -> String {
        name(of: code, in: Locale(identifier: "fr"))
    }

    /// The language's name in the interface language, for the picker.
    static func displayName(of code: String) -> String {
        name(of: code, in: interfaceLocale)
    }

    static func name(of code: String, in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }

    /// The localization the app runs in, which may differ from the region's.
    static var interfaceLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "fr")
    }

    /// All supported codes, sorted by their name in the interface language for a picker.
    static var pickerCodes: [String] { pickerCodes(in: interfaceLocale) }

    static func pickerCodes(in locale: Locale) -> [String] {
        supportedCodes.sorted {
            name(of: $0, in: locale).localizedStandardCompare(name(of: $1, in: locale)) == .orderedAscending
        }
    }
}
