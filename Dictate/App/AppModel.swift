import AppKit
import Observation
import DictateKit

/// Wires the dictation pipeline together and exposes its state to the UI.
@Observable
final class AppModel {
    let settings: AppSettings
    let recorder = AudioRecorder()
    let transcriber: ParakeetTranscriber
    /// The experimental vocabulary rescoring of Parakeet's transcript.
    let booster: VocabularyBooster
    let controller: DictationController
    let indicator: RecordingIndicator
    let updater = Updater()
    let history = DictationHistory()
    let corpus = EvaluationCorpus()
    let vocabularySuggestions = VocabularySuggestions()

    /// Where the `claude` CLI is, and whether it is signed in.
    let claudeCLI: ClaudeCLIStatus
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
    @ObservationIgnored private var hotkeyRetry: Timer?
    @ObservationIgnored private var setupMonitor: SetupMonitor?
    /// The waiting process is replaced once the settings stop changing.
    @ObservationIgnored private let enhancerReset = Debouncer(delay: .seconds(2))
    /// The lexicon is taken into account once the user pauses typing.
    @ObservationIgnored private let vocabularyEdit = Debouncer(delay: .milliseconds(600))

    init() {
        let settings = AppSettings()
        self.settings = settings
        let booster = VocabularyBooster()
        self.booster = booster
        let transcriber = ParakeetTranscriber(booster: booster, boostedVocabulary: { settings.boostedVocabulary })
        self.transcriber = transcriber
        let claudeCLI = ClaudeCLIStatus(override: { settings.cliPathOverride })
        self.claudeCLI = claudeCLI
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
                    locate: { claudeCLI.locate() },
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
            .init(
                recorder: recorder,
                transcriber: transcriber,
                enhancer: enhancer,
                focus: focus,
                inserter: TextInserter(),
                insertionObserver: PostInsertionObserver(reader: focus)
            ),
            settings: .init(
                language: { settings.language },
                enhancementEnabled: { settings.enhancementEnabled },
                shareFieldContext: { settings.shareFieldContext },
                loadingEngine: { [transcriber] in
                    // A failed load is retried by the dictation itself.
                    transcriber.state.isBusy || transcriber.state == .notLoaded ? transcriber.engine : nil
                },
                autoSendApps: { settings.autoSendApps },
                keepSamples: { settings.keepEvaluationCorpus },
                followInsertions: { settings.suggestVocabulary }
            )
        )
        indicator = RecordingIndicator(controller: controller, recorder: recorder)
        if let flash = ScreenshotMode.flash, flash.hasPrefix("claudeDisconnected") {
            indicator.show(.pasted(raw: flash.hasSuffix("Raw")), reviewerProblem: String(localized: "Claude déconnecté"))
        } else if ScreenshotMode.flash == "unheard" {
            indicator.show(.unheard)
        }
        let suggestions = vocabularySuggestions
        controller.events = .init(
            onOutcome: { [weak self] outcome in self?.handle(outcome) },
            onRecord: { [history] record in history.append(record) },
            onSample: { [corpus] sample in Task { await corpus.record(sample) } },
            onFollowUp: { followUp in
                // The setting may have been turned off during the wait.
                guard settings.suggestVocabulary else { return }
                suggestions.consider(followUp, vocabulary: settings.vocabulary)
            },
            onFieldContext: { context in
                guard settings.suggestVocabulary, let text = context.precedingText else { return }
                suggestions.consider(precedingText: text, vocabulary: settings.vocabulary)
            }
        )
        fnMonitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            Log.hotkey.info("gesture \(String(describing: gesture), privacy: .public) in phase \(String(describing: self.controller.phase), privacy: .public)")
            // A reviewer stopped after a long idle starts again while the user speaks.
            if gesture == .pressed { self.enhancer.prewarm() }
            self.controller.handle(gesture)
        }
        fnMonitor.key = settings.pushToTalkKey
        settings.defaultReviewer = { [weak self] in self?.availability.automatic ?? (Distribution.isAppStore ? .apple : .claude) }
        claudeCLI.onUpdate = { [weak self] apply in
            guard let self else { return apply() }
            let before = self.settings.reviewer
            apply()
            // The automatic choice may have moved with the CLI or the account: warm up the right one.
            if self.settings.reviewer != before { self.enhancer.reset() }
            self.refreshSetup()
            self.reportSettings()
        }
        setupMonitor = SetupMonitor { [weak self] in
            self?.refreshSetup()
            return self?.setup ?? SetupChecklist()
        }
        refreshSetup()
    }

    /// What can review on this Mac right now.
    var availability: ReviewerAvailability {
        ReviewerAvailability(
            claudeSubscriptionReady: claudeCLI.subscriptionReady,
            claudeAccess: settings.claudeAccess,
            savedKeys: Set(APIProvider.allCases.filter(settings.hasAPIKey)),
            appleIntelligence: appleIntelligence.isAvailable
        )
    }

    /// Every reviewer that can answer now, in the order of preference.
    var detectedReviewers: [Reviewer] { availability.detected }

    /// Whether this reviewer can answer the next dictation.
    func isReady(_ reviewer: Reviewer) -> Bool { availability.isReady(reviewer) }

    /// Claude can review, through the access the user picked.
    var claudeReady: Bool { availability.claudeReady }

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
        guard settings.saveAPIKey(key, for: provider) else {
            reviewTestResult = String(localized: "La clé n'a pas pu être enregistrée dans le trousseau.")
            return
        }
        reviewTestResult = nil
        enhancer.reset()
        settingsChanged()
    }

    func start() {
        Log.app.info("""
            start — microphone: \(Permissions.microphone), inputMonitoring: \(Permissions.inputMonitoring), \
            accessibility: \(Permissions.accessibility), fnKeyFree: \(Permissions.fnKeyFree)
            """)
        claudeCLI.refresh()
        claudeCLI.probe()
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
            "engine": transcriber.engine.rawValue,
            "push_to_talk": settings.pushToTalkKey.rawValue,
            "language": settings.language,
            "reviewer": settings.reviewer.rawValue,
            "vocabulary_boosting": settings.boostedVocabulary.isEmpty ? "off" : "on",
            "dictated_emojis": settings.dictatedEmojis ? "on" : "off",
            "claude_cli": claudeCLI.reportTag,
            "claude_access": settings.claudeAccess.rawValue,
            "apple_intelligence": appleIntelligence.isAvailable ? "available" : "unavailable",
        ])
    }

    func refreshSetup() {
        // Claude is the default when its CLI is here: while it is not, keep
        // looking, so that installing it is picked up.
        if settings.reviewer != .claude || claudeCLI.path == nil { claudeCLI.refresh() }
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

    private func pollSetupUntilComplete() {
        setupMonitor?.follow(setup)
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

    /// Asks the CLI again, e.g. after the user signed in to Claude.
    func recheckClaude() { claudeCLI.recheck() }

    /// Called when the vocabulary, the emojis or the CLI path change: the waiting process has a stale prompt.
    func settingsChanged() {
        claudeCLI.refresh()
        refreshSetup()
        pollSetupUntilComplete()
        reportSettings()
        enhancerReset.schedule { [enhancer] in enhancer.reset() }
    }

    /// Each keystroke in the lexicon: the CLI lookup, the checklist, the
    /// Sentry tags and the boosting model follow once the user pauses.
    func vocabularyEdited() {
        vocabularyEdit.schedule { [weak self] in
            self?.settingsChanged()
            self?.vocabularyBoostingChanged()
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
        let reviewer = settings.reviewer
        // A raw text may come from a reviewer that went away: look again.
        if case .pasted(raw: true) = outcome { refreshAfterRawInsertion(reviewer) }
        if case .copied(raw: true) = outcome { refreshAfterRawInsertion(reviewer) }
        let problem = enhancer.problem(of: reviewer)
        lastError = OutcomeMessage.error(for: outcome, .init(
            reviewer: reviewer,
            access: settings.claudeAccess,
            cliFound: claudeCLI.path != nil,
            appleExplanation: appleIntelligence.explanation,
            problem: problem
        ))
        indicator.show(outcome, reviewerProblem: problem.map {
            OutcomeMessage.title(of: $0, reviewer: reviewer, access: settings.claudeAccess)
        })
    }

    private func refreshAfterRawInsertion(_ reviewer: Reviewer) {
        switch reviewer {
        case .apple: refreshSetup()
        case .claude where settings.claudeAccess == .subscription: claudeCLI.refresh()
        default: break
        }
    }
}
