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

    /// ISO 639-1 code of the dictated language, for Parakeet and the Claude
    /// prompt. Starts as the OS language.
    var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// The user has seen the detected language in the onboarding and agreed.
    var languageConfirmed: Bool {
        didSet { defaults.set(languageConfirmed, forKey: Keys.languageConfirmed) }
    }

    /// The model that turns speech into text.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// The modifier held to dictate.
    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    var enhancementEnabled: Bool {
        didSet { defaults.set(enhancementEnabled, forKey: Keys.enhancementEnabled) }
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

    /// Keep each dictation's audio, texts and the field's content a few
    /// seconds later on this Mac, to measure the word error rate. Off by default.
    var keepEvaluationCorpus: Bool {
        didSet { defaults.set(keepEvaluationCorpus, forKey: Keys.keepEvaluationCorpus) }
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

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                ErrorReporter.capture(error, "launch at login could not be \(newValue ? "enabled" : "disabled")", category: "settings")
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A language only Whisper understood falls back to the OS language,
        // and must be confirmed again in the onboarding.
        let saved = defaults.string(forKey: Keys.language)
        let supported = saved.map(DictationLanguage.supportedCodes.contains) ?? true
        language = supported ? saved ?? DictationLanguage.preferred() : DictationLanguage.preferred()
        languageConfirmed = supported && defaults.bool(forKey: Keys.languageConfirmed)
        // "whisper", saved before it was removed, no longer decodes.
        transcriptionEngine = defaults.string(forKey: Keys.transcriptionEngine)
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .parakeet
        pushToTalkKey = defaults.string(forKey: Keys.pushToTalkKey).flatMap(PushToTalkKey.init(rawValue:)) ?? .control
        enhancementEnabled = defaults.object(forKey: Keys.enhancementEnabled) as? Bool ?? true
        shareFieldContext = defaults.object(forKey: Keys.shareFieldContext) as? Bool ?? true
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        keepEvaluationCorpus = defaults.bool(forKey: Keys.keepEvaluationCorpus)
        cliPathOverride = defaults.string(forKey: Keys.cliPathOverride) ?? ""
        vocabularyText = defaults.string(forKey: Keys.vocabulary) ?? Self.defaultVocabulary.joined(separator: "\n")
    }

    private enum Keys {
        static let language = "language"
        static let languageConfirmed = "languageConfirmed"
        static let transcriptionEngine = "transcriptionEngine"
        static let pushToTalkKey = "pushToTalkKey"
        static let enhancementEnabled = "enhancementEnabled"
        static let shareFieldContext = "shareFieldContext"
        static let autoUpdate = "autoUpdate"
        static let keepEvaluationCorpus = "keepEvaluationCorpus"
        static let cliPathOverride = "cliPathOverride"
        static let vocabulary = "vocabulary"
    }
}
