import AppKit
import Observation

/// Wires the dictation pipeline together and exposes its state to the UI.
@Observable
final class AppModel {
    let settings: AppSettings
    let recorder = AudioRecorder()
    let transcriber: SwitchableTranscriber
    let controller: DictationController
    let indicator: RecordingIndicator
    let updater = Updater()
    let history = DictationHistory()
    let corpus = EvaluationCorpus()

    private(set) var claudeCLIPath: URL?
    /// Version reported by `claude --version`: nil while probing or when the binary does not answer.
    private(set) var claudeCLIVersion: String?
    private(set) var isProbingClaudeCLI = false
    private(set) var hotkeyActive = false
    private(set) var lastError: String?
    private(set) var claudeTestResult: String?
    /// What the onboarding still needs. Polled, because macOS does not notify permission changes.
    private(set) var setup = SetupChecklist()

    @ObservationIgnored private let enhancer: ClaudeCLIEnhancer
    @ObservationIgnored private let fnMonitor = FnKeyMonitor()
    @ObservationIgnored private let locator = ClaudeCLILocator()
    @ObservationIgnored private var hotkeyRetry: Timer?
    @ObservationIgnored private var setupPoll: Timer?
    @ObservationIgnored private var resetEnhancerTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        self.settings = settings
        let transcriber = SwitchableTranscriber(engine: settings.transcriptionEngine)
        self.transcriber = transcriber
        let locator = locator
        let focus = FocusInspector()
        enhancer = ClaudeCLIEnhancer(
            locate: { locator.locate(override: settings.cliPathOverride) },
            systemPrompt: { PromptBuilder.systemPrompt(vocabulary: settings.vocabulary, language: settings.language) }
        )
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
        controller.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        controller.onRecord = { [history] record in history.append(record) }
        controller.insertionObserver = PostInsertionObserver(reader: focus)
        controller.keepSamples = { settings.keepEvaluationCorpus }
        controller.onSample = { [corpus] sample in
            Task { await corpus.record(sample) }
        }
        fnMonitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            Log.hotkey.info("gesture \(String(describing: gesture), privacy: .public) in phase \(String(describing: self.controller.phase), privacy: .public)")
            self.controller.handle(gesture)
        }
        fnMonitor.key = settings.pushToTalkKey
        claudeCLIPath = locator.locate(override: settings.cliPathOverride)
        refreshSetup()
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
        Task.detached(priority: .background) { ModelStorage.removeWhisperModel() }
        startHotkey()
        pollSetupUntilComplete()
        updater.startPeriodicChecks { [settings] in settings.autoUpdate }
        reportSettings()
    }

    /// The settings an error report needs to be understood.
    private func reportSettings() {
        ErrorReporter.setTags([
            "engine": settings.transcriptionEngine.rawValue,
            "push_to_talk": settings.pushToTalkKey.rawValue,
            "language": settings.language,
            "enhancement": settings.enhancementEnabled ? "on" : "off",
            "claude_cli": claudeCLIPath == nil ? "missing" : "found",
        ])
    }

    func refreshSetup() {
        if settings.enhancementEnabled, claudeCLIPath == nil { refreshClaudeCLI() }
        let checklist = SetupChecklist(
            language: settings.languageConfirmed,
            microphone: Permissions.microphone,
            inputMonitoring: Permissions.inputMonitoring || hotkeyActive,
            accessibility: Permissions.accessibility,
            fnKeyFree: !settings.pushToTalkKey.needsSystemKeyFreed || Permissions.fnKeyFree,
            transcriptionModel: transcriptionModelReady,
            claude: !settings.enhancementEnabled || claudeCLIPath != nil
        )
        if checklist != setup { setup = checklist }
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

    /// Dictation without Claude inserts the raw transcript.
    func continueWithoutClaude() {
        settings.enhancementEnabled = false
        refreshSetup()
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
        claudeCLIPath = path
        probeClaudeCLI()
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

    func testClaude() async {
        claudeTestResult = "Test en cours…"
        let start = ContinuousClock.now
        do {
            let result = try await enhancer.enhance(
                transcript: "euh bon ben je vais faire un pouche sur la branche main",
                context: DictationContext(category: .code)
            )
            let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            claudeTestResult = "« \(result) » en \(elapsed)"
        } catch {
            ErrorReporter.capture(error, "claude test from the settings failed", category: "enhancer")
            claudeTestResult = error.localizedDescription
        }
    }

    /// Developer tool: word error rates over the corpus, logged and shown.
    func evaluateCorpus() {
        let evaluation = CorpusEvaluation(entries: corpus.entries)
        Log.app.info("corpus evaluation:\n\(evaluation.summary, privacy: .public)")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Taux d'erreur sur le corpus"
        alert.informativeText = evaluation.summary + """


            Référence : le texte laissé dans le champ \(PostInsertionObserver.defaultDelay.components.seconds) s \
            après l'insertion. Une erreur non corrigée compte comme juste : ces taux sont des minimums.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Afficher dans le Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([corpus.folder])
        }
    }

    /// Asks first: the recordings cannot be brought back.
    func confirmAndDeleteCorpus() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Supprimer le corpus d'évaluation ?"
        alert.informativeText = "Les \(corpus.entries.count) enregistrements et leurs textes seront effacés de ce Mac."
        alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        corpus.deleteAll()
    }

    func retryTranscriber() {
        Task { await transcriber.load() }
    }

    func shutdown() {
        enhancer.shutdown()
        fnMonitor.stop()
    }

    private func handle(_ outcome: DictationOutcome) {
        Log.dictation.info("outcome \(String(describing: outcome), privacy: .public)")
        ErrorReporter.breadcrumb("outcome \(outcome)", category: "dictation")
        switch outcome {
        case .failed(let message):
            lastError = message
        case .pasted(raw: true), .copied(raw: true):
            if settings.enhancementEnabled {
                refreshClaudeCLI()
                lastError = claudeCLIPath == nil
                    ? ClaudeCLIError.notFound.localizedDescription
                    : "Claude n'a pas répondu : texte brut inséré."
            }
        default:
            lastError = nil
        }
        indicator.show(outcome)
    }
}
