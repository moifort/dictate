import AppKit
import Observation

/// Wires the dictation pipeline together and exposes its state to the UI.
@Observable
final class AppModel {
    let settings: AppSettings
    let recorder = AudioRecorder()
    let transcriber = WhisperKitTranscriber()
    let controller: DictationController
    let indicator: RecordingIndicator
    let updater = Updater()

    private(set) var claudeCLIPath: URL?
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

    init() {
        let settings = AppSettings()
        self.settings = settings
        let locator = locator
        enhancer = ClaudeCLIEnhancer(
            locate: { locator.locate(override: settings.cliPathOverride) },
            systemPrompt: { PromptBuilder.systemPrompt(vocabulary: settings.vocabulary) }
        )
        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            enhancer: enhancer,
            focus: FocusInspector(),
            inserter: TextInserter(),
            vocabulary: { settings.vocabulary },
            enhancementEnabled: { settings.enhancementEnabled }
        )
        indicator = RecordingIndicator(controller: controller, recorder: recorder)
        controller.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        fnMonitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            Log.hotkey.info("gesture \(String(describing: gesture), privacy: .public) in phase \(String(describing: self.controller.phase), privacy: .public)")
            self.controller.handle(gesture)
        }
        claudeCLIPath = locator.locate(override: settings.cliPathOverride)
        refreshSetup()
    }

    func start() {
        Log.app.info("""
            start — microphone: \(Permissions.microphone), inputMonitoring: \(Permissions.inputMonitoring), \
            accessibility: \(Permissions.accessibility), fnKeyFree: \(Permissions.fnKeyFree)
            """)
        refreshClaudeCLI()
        enhancer.prewarm()
        Task { await transcriber.load() }
        startHotkey()
        pollSetupUntilComplete()
        updater.startPeriodicChecks { [settings] in settings.autoUpdate }
    }

    func refreshSetup() {
        if settings.enhancementEnabled, claudeCLIPath == nil { refreshClaudeCLI() }
        let checklist = SetupChecklist(
            microphone: Permissions.microphone,
            inputMonitoring: Permissions.inputMonitoring || hotkeyActive,
            accessibility: Permissions.accessibility,
            fnKeyFree: Permissions.fnKeyFree,
            whisperModel: whisperReady,
            claude: !settings.enhancementEnabled || claudeCLIPath != nil
        )
        if checklist != setup { setup = checklist }
    }

    /// Ready, or on disk and still being compiled: launch must not wait for that.
    private var whisperReady: Bool {
        switch transcriber.state {
        case .ready: true
        case .failed, .downloading: false
        case .notLoaded, .loading: WhisperKitTranscriber.isModelDownloaded()
        }
    }

    /// Dictation without Claude inserts the raw Whisper transcript.
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
        claudeCLIPath = locator.locate(override: settings.cliPathOverride)
    }

    /// Called when the vocabulary or CLI path changes: the waiting process has a stale prompt.
    func settingsChanged() {
        refreshClaudeCLI()
        refreshSetup()
        pollSetupUntilComplete()
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
                category: .code
            )
            let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            claudeTestResult = "« \(result) » en \(elapsed)"
        } catch {
            claudeTestResult = error.localizedDescription
        }
    }

    func retryWhisper() {
        Task { await transcriber.load() }
    }

    func shutdown() {
        enhancer.shutdown()
        fnMonitor.stop()
    }

    private func handle(_ outcome: DictationOutcome) {
        Log.dictation.info("outcome \(String(describing: outcome), privacy: .public)")
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
