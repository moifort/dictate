import AppKit
import Observation

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
    @ObservationIgnored private let fnMonitor = FnKeyMonitor()
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
        let focus = FocusInspector()
        let systemPrompt = { PromptBuilder.systemPrompt(vocabulary: settings.vocabulary, language: settings.language) }
        let network = network
        let enhancer = SelectedEnhancer(
            reviewer: { settings.reviewer },
            isOnline: { network.isOnline },
            apple: AppleIntelligenceEnhancer(systemPrompt: systemPrompt),
            claude: ClaudeCLIEnhancer(
                locate: { locator.locate(override: settings.cliPathOverride) },
                systemPrompt: systemPrompt
            )
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
            reviewer: { [enhancer] in enhancer.lastUsed },
            loadingEngine: { [transcriber] in
                // A failed load is retried by the dictation itself.
                transcriber.state.isBusy || transcriber.state == .notLoaded ? transcriber.engine : nil
            }
        )
        indicator = RecordingIndicator(controller: controller, recorder: recorder)
        controller.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        controller.onRecord = { [history] record in history.append(record) }
        controller.insertionObserver = PostInsertionObserver(reader: focus)
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

    /// Until the user picks: Claude when its CLI is here, else the on-device
    /// model when this Mac has it, else the raw transcript.
    private var automaticReviewer: Reviewer {
        if claudeCLIPath != nil { return .claude }
        return appleIntelligence.isAvailable ? .apple : .none
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
            "claude_cli": claudeCLIPath == nil ? "missing" : "found",
            "apple_intelligence": appleIntelligence.isAvailable ? "available" : "unavailable",
        ])
    }

    func refreshSetup() {
        // Claude is the default when its CLI is here: while it is not, keep
        // looking, so that installing it is picked up.
        if settings.reviewer != .claude || claudeCLIPath == nil { refreshClaudeCLI() }
        let status = AppleIntelligenceEnhancer.status
        if status != appleIntelligence { appleIntelligence = status }
        let checklist = SetupChecklist(
            language: settings.languageConfirmed,
            microphone: Permissions.microphone,
            inputMonitoring: Permissions.inputMonitoring || hotkeyActive,
            accessibility: Permissions.accessibility,
            fnKeyFree: !settings.pushToTalkKey.needsSystemKeyFreed || Permissions.fnKeyFree,
            transcriptionModel: transcriptionModelReady,
            review: reviewerReady
        )
        if checklist != setup { setup = checklist }
    }

    /// Whether the chosen reviewer can answer the next dictation.
    private var reviewerReady: Bool {
        switch settings.reviewer {
        case .none: true
        case .apple: appleIntelligence.isAvailable
        case .claude: claudeCLIPath != nil
        }
    }

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
        guard !setup.isComplete, setupPoll == nil else { return }
        setupPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshSetup()
                if self.setup.isComplete {
                    Log.app.info("setup complete")
                    self.setupPoll?.invalidate()
                    self.setupPoll = nil
                }
            }
        }
    }

    /// The event tap only works once Input Monitoring is granted: keep retrying.
    func startHotkey() {
        hotkeyActive = fnMonitor.start()
        Log.hotkey.info("event tap active: \(self.hotkeyActive)")
        guard !hotkeyActive, hotkeyRetry == nil else { return }
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotkeyActive = self.fnMonitor.start()
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

    func claudeCLIDisplayPath(_ url: URL) -> String {
        locator.displayPath(of: url)
    }

    private func probeClaudeCLI() {
        probeTask?.cancel()
        claudeCLIVersion = nil
        guard let path = claudeCLIPath else {
            isProbingClaudeCLI = false
            return
        }
        isProbingClaudeCLI = true
        probeTask = Task {
            let version = await ClaudeCLILocator.version(of: path)
            guard !Task.isCancelled else { return }
            claudeCLIVersion = version
            isProbingClaudeCLI = false
        }
    }

    /// Called when the vocabulary or CLI path changes: the waiting process has a stale prompt.
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
        if settings.boostedVocabulary.isEmpty {
            Task { await booster.unload() }
        } else {
            Task { await booster.load() }
        }
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
            case .claude:
                refreshClaudeCLI()
                lastError = claudeCLIPath == nil
                    ? ClaudeCLIError.notFound.localizedDescription
                    : String(localized: "Claude n'a pas répondu : texte brut inséré.")
            }
        default:
            lastError = nil
        }
        indicator.show(outcome)
    }
}
