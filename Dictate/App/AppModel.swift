import AppKit
import Observation
import DictateKit

/// Wires the dictation pipeline together and exposes its state to the UI.
@Observable
final class AppModel {
    let settings: AppSettings
    let recorder = AudioRecorder()
    let transcriber: SwitchableTranscriber
    /// The experimental vocabulary rescoring of Parakeet's transcript.
    let booster: VocabularyBooster
    let controller: DictationController
    let indicator: RecordingIndicator
    let updater = Updater()
    let history = DictationHistory()
    let corpus = EvaluationCorpus()
    let vocabularySuggestions = VocabularySuggestions()

    private(set) var claudeCLIPath: URL?
    /// Version reported by `claude --version`: nil while probing or when the binary does not answer.
    private(set) var claudeCLIVersion: String?
    private(set) var isProbingClaudeCLI = false
    /// Whether `claude auth status` reports a signed-in account; false until
    /// the first answer. Claude cannot review without one.
    private(set) var claudeSignedIn = false
    private(set) var hotkeyActive = false
    private(set) var lastError: String?
    private(set) var reviewTestResult: String?
    /// Whether the on-device model can be used, refreshed with the setup.
    private(set) var appleIntelligence = AppleIntelligenceEnhancer.status
    /// What the onboarding still needs. Polled, because macOS does not notify permission changes.
    private(set) var setup = SetupChecklist()

    @ObservationIgnored private let enhancer: SelectedEnhancer
    /// Claude needs the network; without it the on-device model steps in.
    @ObservationIgnored private let network = NetworkMonitor()
    @ObservationIgnored private let fnMonitor = PushToTalkMonitor()
    @ObservationIgnored private let locator = ClaudeCLILocator()
    @ObservationIgnored private var hotkeyRetry: Timer?
    @ObservationIgnored private var setupPoll: Timer?
    @ObservationIgnored private var resetEnhancerTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        self.settings = settings
        let booster = VocabularyBooster()
        self.booster = booster
        let parakeet = ParakeetTranscriber(booster: booster, boostedVocabulary: { settings.boostedVocabulary })
        let transcriber = SwitchableTranscriber(engine: settings.transcriptionEngine, parakeet: parakeet)
        self.transcriber = transcriber
        let locator = locator
        let focus = FieldInspector()
        let systemPrompt = {
            PromptBuilder.systemPrompt(
                vocabulary: settings.vocabulary, language: settings.language, emojis: settings.dictatedEmojis
            )
        }
        let network = network
        let enhancer = SelectedEnhancer(
            reviewer: { settings.reviewer },
            isOnline: { network.isOnline },
            apple: AppleIntelligenceEnhancer(systemPrompt: systemPrompt),
            claude: ClaudeEnhancer(
                access: { settings.claudeAccess },
                cli: ClaudeCLIEnhancer(
                    locate: { locator.locate(override: settings.cliPathOverride) },
                    systemPrompt: systemPrompt
                ),
                api: APIEnhancer(provider: .anthropic, apiKey: { settings.apiKey(.anthropic) }, systemPrompt: systemPrompt)
            ),
            others: [
                .openAI: APIEnhancer(provider: .openAI, apiKey: { settings.apiKey(.openAI) }, systemPrompt: systemPrompt),
                .gemini: APIEnhancer(provider: .gemini, apiKey: { settings.apiKey(.gemini) }, systemPrompt: systemPrompt),
            ]
        )
        self.enhancer = enhancer
        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            enhancer: enhancer,
            focus: focus,
            inserter: TextInserter(),
            language: { settings.language },
            enhancementEnabled: { settings.enhancementEnabled },
            shareFieldContext: { settings.shareFieldContext },
            transcriptionEngine: { [transcriber] in transcriber.engine },
            loadingEngine: { [transcriber] in
                // A failed load is retried by the dictation itself.
                transcriber.state.isBusy || transcriber.state == .notLoaded ? transcriber.engine : nil
            }
        )
        indicator = RecordingIndicator(controller: controller, recorder: recorder)
        if let flash = ScreenshotMode.flash, flash.hasPrefix("claudeDisconnected") {
            indicator.show(.pasted(raw: flash.hasSuffix("Raw")), reviewerProblem: String(localized: "Claude déconnecté"))
        } else if ScreenshotMode.flash == "unheard" {
            indicator.show(.unheard)
        }
        controller.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        controller.onRecord = { [history] record in history.append(record) }
        controller.insertionObserver = PostInsertionObserver(reader: focus)
        controller.autoSendApps = { settings.autoSendApps }
        controller.keepSamples = { settings.keepEvaluationCorpus }
        controller.onSample = { [corpus] sample in
            Task { await corpus.record(sample) }
        }
        let suggestions = vocabularySuggestions
        controller.followInsertions = { settings.suggestVocabulary }
        controller.onFollowUp = { followUp in
            // The setting may have been turned off during the wait.
            guard settings.suggestVocabulary else { return }
            suggestions.consider(followUp, vocabulary: settings.vocabulary)
        }
        controller.onFieldContext = { context in
            guard settings.suggestVocabulary, let text = context.precedingText else { return }
            suggestions.consider(precedingText: text, vocabulary: settings.vocabulary)
        }
        fnMonitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            Log.hotkey.info("gesture \(String(describing: gesture), privacy: .public) in phase \(String(describing: self.controller.phase), privacy: .public)")
            self.controller.handle(gesture)
        }
        fnMonitor.key = settings.pushToTalkKey
        claudeCLIPath = locator.locate(override: settings.cliPathOverride)
        settings.defaultReviewer = { [weak self] in self?.automaticReviewer ?? (Distribution.isAppStore ? .apple : .claude) }
        refreshSetup()
    }

    /// Until the user picks, the first that can answer: Claude (its CLI here
    /// and signed in, or a key saved), then OpenAI, then Gemini with their
    /// keys, then the on-device model, else the raw transcript.
    private var automaticReviewer: Reviewer { detectedReviewers.first ?? .none }

    /// Every reviewer that can answer now, in the order of preference.
    var detectedReviewers: [Reviewer] {
        [Reviewer.claude, .openAI, .gemini, .apple].filter { $0.isAvailable && isReady($0) }
    }

    /// Whether this reviewer can answer the next dictation.
    func isReady(_ reviewer: Reviewer) -> Bool {
        switch reviewer {
        case .none: true
        case .apple: appleIntelligence.isAvailable
        case .claude: claudeReady
        case .openAI: settings.hasAPIKey(.openAI)
        case .gemini: settings.hasAPIKey(.gemini)
        }
    }

    /// Claude can review, through the access the user picked.
    var claudeReady: Bool {
        switch settings.claudeAccess {
        case .subscription: claudeSubscriptionReady
        case .apiKey: settings.hasAPIKey(.anthropic)
        }
    }

    /// The `claude` CLI is here and an account is signed in.
    var claudeSubscriptionReady: Bool { claudeCLIPath != nil && claudeSignedIn }

    /// Switches between the subscription and the API key: the waiting process
    /// belongs to the previous one, and the automatic choice may move.
    func selectClaudeAccess(_ access: ClaudeAccess) {
        guard access != settings.claudeAccess else { return }
        settings.claudeAccess = access
        reviewTestResult = nil
        enhancer.reset()
        settingsChanged()
    }

    /// Saves the key and uses it: whoever types a key wants that reviewer.
    /// An empty key removes it, and its reviewer goes back to the automatic choice.
    func saveAPIKey(_ key: String, for provider: APIProvider) {
        guard settings.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider) else {
            reviewTestResult = String(localized: "La clé n'a pas pu être enregistrée dans le trousseau.")
            return
        }
        reviewTestResult = nil
        let saved = settings.hasAPIKey(provider)
        if provider == .anthropic { settings.claudeAccess = saved ? .apiKey : .subscription }
        if saved {
            settings.reviewer = provider.reviewer
        } else if settings.reviewerIsChosen, settings.reviewer == provider.reviewer, provider != .anthropic {
            settings.clearReviewerChoice()
        }
        enhancer.reset()
        settingsChanged()
    }

    func start() {
        Log.app.info("""
            start — microphone: \(Permissions.microphone), inputMonitoring: \(Permissions.inputMonitoring), \
            accessibility: \(Permissions.accessibility), fnKeyFree: \(Permissions.fnKeyFree)
            """)
        refreshClaudeCLI()
        probeClaudeCLI()
        enhancer.prewarm()
        Task { await transcriber.load() }
        vocabularyBoostingChanged()
        Task.detached(priority: .background) { ModelStorage.removeWhisperModel() }
        startHotkey()
        pollSetupUntilComplete()
        if !Distribution.isAppStore {
            updater.isIdle = { [controller] in controller.capture == .idle && controller.pending.isEmpty }
            updater.startPeriodicChecks { [settings] in settings.autoUpdate }
        }
        reportSettings()
    }

    /// The settings an error report needs to be understood.
    private func reportSettings() {
        ErrorReporter.setTags([
            "engine": settings.transcriptionEngine.rawValue,
            "push_to_talk": settings.pushToTalkKey.rawValue,
            "language": settings.language,
            "reviewer": settings.reviewer.rawValue,
            "vocabulary_boosting": settings.boostedVocabulary.isEmpty ? "off" : "on",
            "dictated_emojis": settings.dictatedEmojis ? "on" : "off",
            "claude_cli": claudeCLIPath == nil ? "missing" : claudeSignedIn ? "signed_in" : "signed_out",
            "claude_access": settings.claudeAccess.rawValue,
            "apple_intelligence": appleIntelligence.isAvailable ? "available" : "unavailable",
        ])
    }

    func refreshSetup() {
        // Claude is the default when its CLI is here: while it is not, keep
        // looking, so that installing it is picked up.
        if settings.reviewer != .claude || claudeCLIPath == nil { refreshClaudeCLI() }
        settings.reloadUnreadableAPIKeys()
        let status = AppleIntelligenceEnhancer.status
        if status != appleIntelligence { appleIntelligence = status }
        let checklist = SetupChecklist(
            language: settings.languageConfirmed,
            microphone: Permissions.microphone,
            // Not `hotkeyActive`: a tap can exist without the grant, and then
            // the step would be skipped and the permission never requested.
            inputMonitoring: Permissions.inputMonitoring,
            accessibility: Permissions.accessibility,
            fnKeyFree: Permissions.fnKeyFree,
            fnKeyNeeded: settings.pushToTalkKey.needsSystemKeyFreed,
            permissionsNeeded: !Distribution.isAppStore,
            transcriptionModel: transcriptionModelReady,
            review: reviewerReady
        )
        if checklist != setup { setup = checklist }
    }

    /// Whether the chosen reviewer can answer the next dictation.
    private var reviewerReady: Bool { isReady(settings.reviewer) }

    /// Ready, or on disk and still being compiled: launch must not wait for that.
    private var transcriptionModelReady: Bool {
        switch transcriber.state {
        case .ready: true
        case .failed, .downloading: false
        case .notLoaded, .loading: transcriber.isModelDownloaded
        }
    }

    /// Takes effect on the next press: no need to restart the event tap.
    func pushToTalkKeyChanged() {
        fnMonitor.key = settings.pushToTalkKey
        Log.hotkey.info("push-to-talk key: \(self.settings.pushToTalkKey.rawValue, privacy: .public)")
        refreshSetup()
        pollSetupUntilComplete()
        reportSettings()
    }

    /// The onboarding showed the detected language and the user agreed.
    func confirmLanguage() {
        settings.languageConfirmed = true
        refreshSetup()
    }

    /// Picks the reviewer, from the onboarding or the settings: the waiting
    /// process or session belongs to the previous one.
    func selectReviewer(_ reviewer: Reviewer) {
        guard reviewer != settings.reviewer else { return }
        settings.reviewer = reviewer
        reviewTestResult = nil
        enhancer.reset()
        settingsChanged()
    }

    /// Polls at the pace `SetupChecklist.pollInterval` asks for, and stops once complete.
    private func pollSetupUntilComplete() {
        let interval = setup.pollInterval
        guard setupPoll?.timeInterval != interval else { return }
        setupPoll?.invalidate()
        setupPoll = nil
        guard let interval else {
            Log.app.info("setup complete")
            return
        }
        setupPoll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshSetup()
                self.pollSetupUntilComplete()
            }
        }
    }

    /// The event tap only works once Input Monitoring is granted: keep retrying.
    ///
    /// Without the grant macOS still creates the tap, but only delivers the
    /// keys typed in Dictate's own windows: wait for the grant before creating it.
    func startHotkey() {
        hotkeyActive = Permissions.inputMonitoring && fnMonitor.start()
        Log.hotkey.info("event tap active: \(self.hotkeyActive)")
        guard !hotkeyActive, hotkeyRetry == nil else { return }
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotkeyActive = Permissions.inputMonitoring && self.fnMonitor.start()
                if self.hotkeyActive {
                    Log.hotkey.info("event tap active after retry")
                    self.hotkeyRetry?.invalidate()
                    self.hotkeyRetry = nil
                }
            }
        }
    }

    func refreshClaudeCLI() {
        let path = locator.locate(override: settings.cliPathOverride)
        guard path != claudeCLIPath else { return }
        let before = settings.reviewer
        claudeCLIPath = path
        probeClaudeCLI()
        // The automatic choice may have moved with the CLI: warm up the right one.
        if settings.reviewer != before { enhancer.reset() }
    }

    /// Asks the CLI again, e.g. after the user signed in to Claude.
    func recheckClaude() {
        let path = claudeCLIPath
        refreshClaudeCLI()
        // A new path was already probed.
        if claudeCLIPath == path { probeClaudeCLI() }
    }

    func claudeCLIDisplayPath(_ url: URL) -> String {
        locator.displayPath(of: url)
    }

    private func probeClaudeCLI() {
        probeTask?.cancel()
        claudeCLIVersion = nil
        guard let path = claudeCLIPath else {
            isProbingClaudeCLI = false
            claudeSignedIn = false
            return
        }
        isProbingClaudeCLI = true
        probeTask = Task {
            async let version = ClaudeCLILocator.version(of: path)
            // A CLI too old to answer keeps working as before: assume signed in.
            async let signedIn = ClaudeCLILocator.isSignedIn(path)
            let (probedVersion, probedSignedIn) = await (version, signedIn ?? true)
            guard !Task.isCancelled else { return }
            let before = settings.reviewer
            claudeCLIVersion = probedVersion
            claudeSignedIn = probedSignedIn
            isProbingClaudeCLI = false
            Log.app.info("claude signed in: \(probedSignedIn)")
            // The automatic choice may have moved with the account: warm up the right one.
            if settings.reviewer != before { enhancer.reset() }
            refreshSetup()
            reportSettings()
        }
    }

    /// Called when the vocabulary, the emojis or the CLI path change: the waiting process has a stale prompt.
    func settingsChanged() {
        refreshClaudeCLI()
        refreshSetup()
        pollSetupUntilComplete()
        reportSettings()
        resetEnhancerTask?.cancel()
        resetEnhancerTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            enhancer.reset()
        }
    }

    /// Loads the boosting model, downloading it the first time, as soon as
    /// it is wanted, and frees it once it is not: about 130 MB in memory.
    func vocabularyBoostingChanged() {
        reportSettings()
        booster.setEnabled(!settings.boostedVocabulary.isEmpty)
    }

    func retryBooster() {
        Task { await booster.load() }
    }

    /// Runs the chosen reviewer on a sample dictation, for the settings.
    func testReviewer() async {
        reviewTestResult = String(localized: "Test en cours…")
        let start = ContinuousClock.now
        do {
            let result = try await enhancer.enhance(
                // A sample in the interface language, hesitations and a misheard term included.
                transcript: String(localized: "euh bon ben je vais faire un pouche sur la branche main"),
                context: DictationContext(category: .code)
            )
            let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            reviewTestResult = String(localized: "« \(result) » en \(elapsed)")
        } catch {
            ErrorReporter.capture(error, "review test from the settings failed", category: "enhancer")
            reviewTestResult = error.localizedDescription
        }
    }

    /// Developer tool: word error rates over the corpus, logged and shown.
    func evaluateCorpus() {
        let evaluation = CorpusEvaluation(entries: corpus.entries)
        Log.app.info("corpus evaluation:\n\(evaluation.summary, privacy: .public)")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Taux d'erreur sur le corpus")
        let seconds = PostInsertionObserver.defaultDelay.components.seconds
        alert.informativeText = evaluation.summary + "\n\n" + String(localized: """
            Référence : le texte laissé dans le champ \(seconds) s \
            après l'insertion. Une erreur non corrigée compte comme juste : ces taux sont des minimums.
            """)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: String(localized: "Afficher dans le Finder"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([corpus.folder])
        }
    }

    /// Asks first: the recordings cannot be brought back.
    func confirmAndDeleteCorpus() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Supprimer le corpus d'évaluation ?")
        alert.informativeText = String(localized: "Les \(corpus.entries.count) enregistrements et leurs textes seront effacés de ce Mac.")
        alert.addButton(withTitle: String(localized: "Supprimer")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        corpus.deleteAll()
    }

    /// The suggestions not answered yet, minus the terms typed into the vocabulary meanwhile.
    var pendingVocabularySuggestions: [VocabularySuggestion] {
        vocabularySuggestions.pending(excluding: settings.vocabulary)
    }

    func acceptVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        settings.addToVocabulary(suggestion.term)
        vocabularySuggestions.remove(suggestion)
        settingsChanged()
    }

    func ignoreVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        vocabularySuggestions.ignore(suggestion)
    }

    func retryTranscriber() {
        Task { await transcriber.load() }
    }

    func shutdown() {
        enhancer.shutdown()
        network.stop()
        fnMonitor.stop()
    }

    private func handle(_ outcome: DictationOutcome) {
        Log.dictation.info("outcome \(String(describing: outcome), privacy: .public)")
        ErrorReporter.breadcrumb("outcome \(outcome)", category: "dictation")
        switch outcome {
        case .failed(let message):
            lastError = message
        case .pasted(raw: true), .copied(raw: true):
            switch settings.reviewer {
            case .none:
                break
            case .apple:
                refreshSetup()
                lastError = appleIntelligence.explanation ?? String(localized: "Apple Intelligence n'a pas répondu : texte brut inséré.")
            case .claude where settings.claudeAccess == .apiKey, .openAI, .gemini:
                let name = settings.reviewer.displayName
                lastError = String(localized: "L'API \(name) n'a pas répondu : texte brut inséré.")
            case .claude:
                refreshClaudeCLI()
                lastError = claudeCLIPath == nil
                    ? ClaudeCLIError.notFound.localizedDescription
                    : String(localized: "Claude n'a pas répondu : texte brut inséré.")
            }
        default:
            lastError = nil
        }
        let reviewer = settings.reviewer
        let problem = enhancer.problem(of: reviewer)
        if let problem { lastError = Self.explanation(of: problem, reviewer: reviewer, access: settings.claudeAccess) }
        indicator.show(outcome, reviewerProblem: problem.map { Self.title(of: $0, reviewer: reviewer, access: settings.claudeAccess) })
    }

    /// The reviewer's lasting problem in a few words, for the indicator.
    static func title(of problem: ReviewFailure, reviewer: Reviewer, access: ClaudeAccess) -> String {
        let name = reviewer.displayName
        let throughKey = reviewer != .claude || access == .apiKey
        return switch problem {
        case .rateLimited: String(localized: "Limite \(name) atteinte")
        case .disconnected where throughKey: String(localized: "Clé \(name) refusée")
        default: String(localized: "\(name) déconnecté")
        }
    }

    /// The reviewer's lasting problem and what to do about it, for the menu.
    static func explanation(of problem: ReviewFailure, reviewer: Reviewer, access: ClaudeAccess) -> String {
        let provider = reviewer == .claude && access == .subscription ? nil : reviewer.apiProvider
        return switch (problem, provider) {
        case (.rateLimited, let provider?): APIReviewError.rateLimited(provider).localizedDescription
        case (.rateLimited, nil): String(localized: "Limite d'utilisation de Claude atteinte : réessayez après sa réinitialisation.")
        case (_, let provider?): APIReviewError.invalidKey(provider).localizedDescription
        case (_, nil): String(localized: "Claude est déconnecté : lancez « claude auth login » dans un terminal.")
        }
    }
}
