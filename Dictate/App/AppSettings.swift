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

    /// ISO 639-1 code of the dictated language, for Parakeet and the review
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

    /// The reviewer the user picked, nil until they do.
    private(set) var reviewerChoice: Reviewer? {
        didSet { defaults.set(reviewerChoice?.rawValue, forKey: Keys.reviewer) }
    }

    /// What to use until the user picks: the app sets it from what this Mac
    /// has (Claude's CLI first, then Apple Intelligence, else nothing).
    @ObservationIgnored var defaultReviewer: () -> Reviewer = { .claude }

    /// The model that cleans up each transcript.
    var reviewer: Reviewer {
        get { reviewerChoice ?? defaultReviewer() }
        set { reviewerChoice = newValue }
    }

    /// Whether the reviewer was picked by the user rather than by the app.
    var reviewerIsChosen: Bool { reviewerChoice != nil }

    /// Whether a reviewer cleans up the transcript before insertion.
    var enhancementEnabled: Bool { reviewer != .none }

    /// Send the text before the cursor to the reviewer, so names and tone match
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

    /// Re-read the field after each dictation and count the names already
    /// written, to propose vocabulary terms. Everything stays on this Mac. Off by default.
    var suggestVocabulary: Bool {
        didSet { defaults.set(suggestVocabulary, forKey: Keys.suggestVocabulary) }
    }

    var cliPathOverride: String {
        didSet { defaults.set(cliPathOverride, forKey: Keys.cliPathOverride) }
    }

    /// One term per line.
    var vocabularyText: String {
        didSet { defaults.set(vocabularyText, forKey: Keys.vocabulary) }
    }

    /// Appends a term on its own line.
    func addToVocabulary(_ term: String) {
        let text = vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines)
        vocabularyText = text.isEmpty ? term : text + "\n" + term
    }

    var vocabulary: [String] {
        vocabularyText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Search the audio for the vocabulary and fix the transcript before
    /// the review, with a second model. Experimental, off by default: its effect
    /// on French is still to be measured.
    var boostVocabulary: Bool {
        didSet { defaults.set(boostVocabulary, forKey: Keys.boostVocabulary) }
    }

    /// The terms Parakeet's transcript is rescored against: none unless
    /// boosting is on and the vocabulary has terms.
    var boostedVocabulary: [String] {
        boostVocabulary ? vocabulary : []
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
        if let saved = defaults.string(forKey: Keys.reviewer).flatMap(Reviewer.init(rawValue:)) {
            reviewerChoice = saved
        } else if defaults.object(forKey: Keys.enhancementEnabled) as? Bool == false {
            // Saved by versions that only had Claude: "off" stays off.
            reviewerChoice = Reviewer.none
        } else {
            reviewerChoice = nil
        }
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
        shareFieldContext = defaults.object(forKey: Keys.shareFieldContext) as? Bool ?? true
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        keepEvaluationCorpus = defaults.bool(forKey: Keys.keepEvaluationCorpus)
        suggestVocabulary = defaults.bool(forKey: Keys.suggestVocabulary)
        cliPathOverride = defaults.string(forKey: Keys.cliPathOverride) ?? ""
        vocabularyText = defaults.string(forKey: Keys.vocabulary) ?? Self.defaultVocabulary.joined(separator: "\n")
        boostVocabulary = defaults.bool(forKey: Keys.boostVocabulary)
    }

    private enum Keys {
        static let language = "language"
        static let languageConfirmed = "languageConfirmed"
        static let transcriptionEngine = "transcriptionEngine"
        static let pushToTalkKey = "pushToTalkKey"
        static let reviewer = "reviewer"
        /// Older versions' on/off switch, read once for the migration.
        static let enhancementEnabled = "enhancementEnabled"
        static let shareFieldContext = "shareFieldContext"
        static let autoUpdate = "autoUpdate"
        static let keepEvaluationCorpus = "keepEvaluationCorpus"
        static let suggestVocabulary = "suggestVocabulary"
        static let cliPathOverride = "cliPathOverride"
        static let vocabulary = "vocabulary"
        static let boostVocabulary = "boostVocabulary"
    }
}
