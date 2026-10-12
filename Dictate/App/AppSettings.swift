import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let defaultVocabulary = [
        "CI/CD", "push", "pull", "merge", "rebase", "commit", "PR", "pull request", "branch", "main",
        "deploy", "prod", "staging", "build", "release", "review", "refactor", "fix", "lint", "worktree",
        "API", "backend", "frontend", "TypeScript", "Swift", "Xcode", "GitHub", "Claude Code",
    ]

    @ObservationIgnored private let defaults: UserDefaults

    /// ISO 639-1 code of the dictated language, for Whisper and the Claude
    /// prompt. Starts as the OS language.
    var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// The user has seen the detected language in the onboarding and agreed.
    var languageConfirmed: Bool {
        didSet { defaults.set(languageConfirmed, forKey: Keys.languageConfirmed) }
    }

    /// The model that turns speech into text. Parakeet by default for its
    /// speed; Whisper when the language is one of those Parakeet lacks.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    var enhancementEnabled: Bool {
        didSet { defaults.set(enhancementEnabled, forKey: Keys.enhancementEnabled) }
    }

    /// Also give the vocabulary to Whisper as a decoding prompt. More accurate
    /// on jargon, but each prompt token costs a decoder pass: about 2 s per
    /// dictation with the default list on an M1 Pro.
    var guideWhisperWithVocabulary: Bool {
        didSet { defaults.set(guideWhisperWithVocabulary, forKey: Keys.guideWhisperWithVocabulary) }
    }

    /// Send the text before the cursor to Claude, so names and tone match
    /// what is already written. Password fields are never read.
    var shareFieldContext: Bool {
        didSet { defaults.set(shareFieldContext, forKey: Keys.shareFieldContext) }
    }

    /// Install new releases as soon as they are found, without asking.
    var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) }
    }

    var cliPathOverride: String {
        didSet { defaults.set(cliPathOverride, forKey: Keys.cliPathOverride) }
    }

    /// One term per line.
    var vocabularyText: String {
        didSet { defaults.set(vocabularyText, forKey: Keys.vocabulary) }
    }

    var vocabulary: [String] {
        vocabularyText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Without Claude, Whisper is the only chance to spell the jargon right.
    var whisperVocabulary: [String] {
        guideWhisperWithVocabulary || !enhancementEnabled ? vocabulary : []
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let language = defaults.string(forKey: Keys.language) ?? DictationLanguage.preferred()
        self.language = language
        languageConfirmed = defaults.bool(forKey: Keys.languageConfirmed)
        transcriptionEngine = defaults.string(forKey: Keys.transcriptionEngine)
            .flatMap(TranscriptionEngine.init(rawValue:))
            ?? (TranscriptionEngine.parakeet.supports(language: language) ? .parakeet : .whisper)
        enhancementEnabled = defaults.object(forKey: Keys.enhancementEnabled) as? Bool ?? true
        guideWhisperWithVocabulary = defaults.object(forKey: Keys.guideWhisperWithVocabulary) as? Bool ?? true
        shareFieldContext = defaults.object(forKey: Keys.shareFieldContext) as? Bool ?? true
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        cliPathOverride = defaults.string(forKey: Keys.cliPathOverride) ?? ""
        vocabularyText = defaults.string(forKey: Keys.vocabulary) ?? Self.defaultVocabulary.joined(separator: "\n")
    }

    private enum Keys {
        static let language = "language"
        static let languageConfirmed = "languageConfirmed"
        static let transcriptionEngine = "transcriptionEngine"
        static let enhancementEnabled = "enhancementEnabled"
        static let guideWhisperWithVocabulary = "guideWhisperWithVocabulary"
        static let shareFieldContext = "shareFieldContext"
        static let autoUpdate = "autoUpdate"
        static let cliPathOverride = "cliPathOverride"
        static let vocabulary = "vocabulary"
    }
}
