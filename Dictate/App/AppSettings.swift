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
    @ObservationIgnored private let apiKeyStores: (APIProvider) -> SecretStore

    /// ISO 639-1 code of the dictated language, for Parakeet and the review
    /// prompt. Starts as the OS language.
    var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// The user has seen the detected language in the onboarding and agreed.
    var languageConfirmed: Bool {
        didSet { defaults.set(languageConfirmed, forKey: Keys.languageConfirmed) }
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
    /// has (Claude, then OpenAI and Gemini keys, then Apple Intelligence, else nothing).
    @ObservationIgnored var defaultReviewer: () -> Reviewer = { .claude }

    /// The model that cleans up each transcript.
    var reviewer: Reviewer {
        get { reviewerChoice.flatMap { $0.isAvailable ? $0 : nil } ?? defaultReviewer() }
        set { reviewerChoice = newValue }
    }

    /// Whether the reviewer was picked by the user rather than by the app.
    var reviewerIsChosen: Bool { reviewerChoice?.isAvailable == true }

    /// Whether a reviewer cleans up the transcript before insertion.
    var enhancementEnabled: Bool { reviewer != .none }

    /// Send the text before the cursor to the reviewer, so names and tone match
    /// what is already written. Password fields are never read.
    var shareFieldContext: Bool {
        didSet { defaults.set(shareFieldContext, forKey: Keys.shareFieldContext) }
    }

    /// Turn "émoji fusée" into 🚀. On by default.
    var dictatedEmojis: Bool {
        didSet { defaults.set(dictatedEmojis, forKey: Keys.dictatedEmojis) }
    }

    /// Press Return after pasting into one of `autoSendBundleIDs`, so the
    /// dictation is sent.
    var autoSendEnabled: Bool {
        didSet { defaults.set(autoSendEnabled, forKey: Keys.autoSendEnabled) }
    }

    /// The apps where Return is pressed after the paste, Claude by default.
    var autoSendBundleIDs: [String] {
        didSet { defaults.set(autoSendBundleIDs, forKey: Keys.autoSendBundleIDs) }
    }

    /// The apps Return is pressed in right now: none while it is off.
    var autoSendApps: Set<String> {
        autoSendEnabled ? Set(autoSendBundleIDs) : []
    }

    func addAutoSendApp(_ bundleID: String) {
        guard !autoSendBundleIDs.contains(bundleID) else { return }
        autoSendBundleIDs.append(bundleID)
    }

    func removeAutoSendApp(_ bundleID: String) {
        autoSendBundleIDs.removeAll { $0 == bundleID }
    }

    /// Install new releases as soon as they are found, without asking.
    var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) }
    }

    /// Send crashes and errors to Sentry, scrubbed of anything the user said
    /// or wrote. On by default; `ErrorReporter` follows it at once.
    var sendErrorReports: Bool {
        didSet {
            defaults.set(sendErrorReports, forKey: ErrorReporter.preferenceKey)
            ErrorReporter.setAllowed(sendErrorReports)
        }
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

    /// How Claude is reached: the subscription unless the user picks a key.
    var claudeAccess: ClaudeAccess {
        didSet { defaults.set(claudeAccess.rawValue, forKey: Keys.claudeAccess) }
    }

    /// Each provider's API key, kept in the keychain.
    private(set) var apiKeys: [APIProvider: String] = [:]
    /// The keys the keychain could not read, say while it was locked: read
    /// again by `reloadUnreadableAPIKeys()`, never taken for missing.
    @ObservationIgnored private var unreadableKeys: Set<APIProvider> = []

    /// Empty when none is saved.
    func apiKey(_ provider: APIProvider) -> String { apiKeys[provider] ?? "" }

    func hasAPIKey(_ provider: APIProvider) -> Bool {
        !apiKey(provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An empty key removes it. False when the keychain refused, the previous key kept.
    @discardableResult
    func setAPIKey(_ key: String, for provider: APIProvider) -> Bool {
        do {
            try apiKeyStores(provider).write(key)
        } catch {
            Log.app.error("API key could not be saved: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "API key could not be saved to the keychain", category: "settings")
            return false
        }
        apiKeys[provider] = key.isEmpty ? nil : key
        unreadableKeys.remove(provider)
        return true
    }

    /// Saves the key and uses it: whoever types a key wants that reviewer.
    /// An empty key removes it, and its reviewer goes back to the automatic
    /// choice. False when the keychain refused it, nothing changed then.
    func saveAPIKey(_ key: String, for provider: APIProvider) -> Bool {
        guard setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider) else { return false }
        let saved = hasAPIKey(provider)
        if provider == .anthropic { claudeAccess = saved ? .apiKey : .subscription }
        if saved {
            reviewer = provider.reviewer
        } else if reviewerIsChosen, reviewer == provider.reviewer, provider != .anthropic {
            clearReviewerChoice()
        }
        return true
    }

    /// Reads the keys the keychain refused earlier again.
    func reloadUnreadableAPIKeys() {
        for provider in unreadableKeys { loadAPIKey(provider) }
    }

    private func loadAPIKey(_ provider: APIProvider) {
        do {
            let key = try apiKeyStores(provider).read()
            unreadableKeys.remove(provider)
            if let key, !key.isEmpty, apiKeys[provider] != key { apiKeys[provider] = key }
        } catch {
            guard !unreadableKeys.contains(provider) else { return }
            unreadableKeys.insert(provider)
            Log.app.error("API key could not be read: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "API key could not be read from the keychain", category: "settings", level: .warning)
        }
    }

    /// Back to the automatic choice, e.g. once the chosen reviewer's key is removed.
    func clearReviewerChoice() {
        reviewerChoice = nil
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
                // Turned off by the user in System Settings: only they can turn it
                // back on there, which the toggle tells them. Not an error.
                guard !launchAtLoginNeedsApproval else { return }
                ErrorReporter.capture(error, "launch at login could not be \(newValue ? "enabled" : "disabled")", category: "settings")
            }
        }
    }

    /// The login item is registered but macOS waits for the user to allow it
    /// in System Settings > General > Login Items.
    var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    init(
        defaults: UserDefaults = .standard,
        apiKeyStores: @escaping (APIProvider) -> SecretStore = KeychainSecret.apiKey
    ) {
        self.defaults = defaults
        self.apiKeyStores = apiKeyStores
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
        pushToTalkKey = defaults.string(forKey: Keys.pushToTalkKey).flatMap(PushToTalkKey.init(rawValue:))
            .flatMap { PushToTalkKey.available.contains($0) ? $0 : nil } ?? PushToTalkKey.available[0]
        shareFieldContext = defaults.object(forKey: Keys.shareFieldContext) as? Bool ?? true
        dictatedEmojis = defaults.object(forKey: Keys.dictatedEmojis) as? Bool ?? true
        autoSendEnabled = defaults.object(forKey: Keys.autoSendEnabled) as? Bool ?? true
        autoSendBundleIDs = defaults.stringArray(forKey: Keys.autoSendBundleIDs) ?? AutoSend.defaultBundleIDs
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        sendErrorReports = ErrorReporter.userAllows(defaults)
        keepEvaluationCorpus = defaults.bool(forKey: Keys.keepEvaluationCorpus)
        suggestVocabulary = defaults.bool(forKey: Keys.suggestVocabulary)
        claudeAccess = defaults.string(forKey: Keys.claudeAccess).flatMap(ClaudeAccess.init(rawValue:)) ?? .subscription
        cliPathOverride = defaults.string(forKey: Keys.cliPathOverride) ?? ""
        vocabularyText = defaults.string(forKey: Keys.vocabulary) ?? Self.defaultVocabulary.joined(separator: "\n")
        boostVocabulary = defaults.bool(forKey: Keys.boostVocabulary)
        for provider in APIProvider.allCases { loadAPIKey(provider) }
    }

    private enum Keys {
        static let language = "language"
        static let languageConfirmed = "languageConfirmed"
        static let pushToTalkKey = "pushToTalkKey"
        static let reviewer = "reviewer"
        /// Older versions' on/off switch, read once for the migration.
        static let enhancementEnabled = "enhancementEnabled"
        static let shareFieldContext = "shareFieldContext"
        static let dictatedEmojis = "dictatedEmojis"
        /// Named when only Claude could be picked: kept, so "off" stays off.
        static let autoSendEnabled = "autoSendInClaude"
        static let autoSendBundleIDs = "autoSendBundleIDs"
        static let autoUpdate = "autoUpdate"
        static let keepEvaluationCorpus = "keepEvaluationCorpus"
        static let suggestVocabulary = "suggestVocabulary"
        static let claudeAccess = "claudeAccess"
        static let cliPathOverride = "cliPathOverride"
        static let vocabulary = "vocabulary"
        static let boostVocabulary = "boostVocabulary"
    }
}
