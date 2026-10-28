import Foundation
import Observation

enum DictationPhase: Equatable {
    case idle
    /// `fn` is held but the microphone is not open yet.
    case starting
    case recording
    /// The engine is turning the audio into text.
    case transcribing
    /// Claude is cleaning up the transcript.
    case enhancing

    var isBusy: Bool { self == .transcribing || self == .enhancing }
}

enum DictationOutcome: Equatable {
    /// Text pasted into the focused field. `raw` when enhancement failed.
    case pasted(raw: Bool)
    /// No editable field: text left in the pasteboard.
    case copied(raw: Bool)
    /// Nothing worth inserting (silence, empty transcript).
    case discarded
    /// `fn` pressed while the engine's model is still downloading or loading.
    case modelLoading(TranscriptionEngine)
    case failed(String)
}

/// A released dictation on its way to the field.
struct PendingDictation: Identifiable, Equatable {
    let id: Int
    /// `.transcribing` or `.enhancing`.
    var phase: DictationPhase
}

/// Orchestrates dictations: record → transcribe → enhance → insert.
///
/// The microphone serves one dictation at a time, but a released one is
/// processed while the next is recorded: the user keeps talking instead of
/// waiting for Claude. Texts land in the order the key was released.
@Observable
final class DictationController {
    /// The microphone's side: `.idle`, `.starting` or `.recording`.
    private(set) var capture: DictationPhase = .idle
    /// Released dictations not inserted yet, oldest first.
    private(set) var pending: [PendingDictation] = []
    private(set) var lastOutcome: DictationOutcome?

    /// Recording wins over processing, which shows the latest dictation's step.
    var phase: DictationPhase {
        capture != .idle ? capture : pending.last?.phase ?? .idle
    }

    @ObservationIgnored let recorder: AudioRecording
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let enhancer: Enhancer
    @ObservationIgnored private let focus: FocusInspecting
    @ObservationIgnored private let inserter: TextInserting
    /// ISO 639-1 code of the language being dictated.
    @ObservationIgnored private let language: () -> String
    @ObservationIgnored private let enhancementEnabled: () -> Bool
    /// Whether the text before the cursor may be sent to Claude.
    @ObservationIgnored private let shareFieldContext: () -> Bool
    /// The engine behind `transcriber`, for the statistics.
    @ObservationIgnored private let transcriptionEngine: () -> TranscriptionEngine
    /// The model behind `enhancer` for the cleanup just done, for the
    /// statistics: read once the cleanup is over, since the enhancer may
    /// fall back to another model along the way.
    @ObservationIgnored private let reviewer: () -> Reviewer?
    /// The engine whose model is not in memory yet, nil once dictation can start.
    @ObservationIgnored private let loadingEngine: () -> TranscriptionEngine?
    @ObservationIgnored private let enhancementTimeout: Duration
    /// How long the microphone keeps capturing once the key is released.
    @ObservationIgnored private let releaseTail: Duration
    /// Waits out `releaseTail`; injected so tests control when the tail ends.
    @ObservationIgnored private let sleep: (Duration) async -> Void
    /// The app being dictated into, read on press for the recording in progress.
    @ObservationIgnored private var context = DictationContext()
    @ObservationIgnored private var bundleID: String?
    @ObservationIgnored private var nextID = 0
    /// Every released dictation still running, by id.
    @ObservationIgnored private var processing: [Int: Task<Void, Never>] = [:]
    /// The last released dictation: the next one inserts after it.
    @ObservationIgnored private var lastReleased: Task<Void, Never>?
    /// The dictation whose release tail still has the microphone.
    @ObservationIgnored private var tailOwner: Int?
    /// Audio of tails a new press cut short, until their dictation picks it up.
    @ObservationIgnored private var cutTails: [Int: [Float]] = [:]
    /// The engine is shared: transcriptions run one after the other.
    @ObservationIgnored private var transcribing: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// A release or cancel that came while the microphone was still starting.
    @ObservationIgnored private var pendingGesture: FnKeyGestureOutput?

    /// Called once per finished dictation, after it left `pending`.
    @ObservationIgnored var onOutcome: ((DictationOutcome) -> Void)?
    /// Called once per dictation that inserted text, with its timings.
    @ObservationIgnored var onRecord: ((DictationRecord) -> Void)?
    /// Whether to hand each pasted dictation, audio included, to `onSample`.
    @ObservationIgnored var keepSamples: () -> Bool = { false }
    /// Called once per pasted dictation while `keepSamples` is true, for the evaluation corpus.
    @ObservationIgnored var onSample: ((DictationSample) -> Void)?
    /// Whether to hand each pasted dictation's field, read again a few seconds later, to `onFollowUp`.
    @ObservationIgnored var followInsertions: () -> Bool = { false }
    /// Called once per pasted dictation while `followInsertions` is true, once the field was read again.
    @ObservationIgnored var onFollowUp: ((InsertionFollowUp) -> Void)?
    /// Catches the field before each followed or kept paste, to read it again later.
    /// One read serves both `onSample` and `onFollowUp`.
    @ObservationIgnored var insertionObserver: PostInsertionObserver?
    /// Called once per dictation whose field context was read, before Claude sees it.
    @ObservationIgnored var onFieldContext: ((DictationContext) -> Void)?

    private static let minimumSampleCount = AudioAnalysis.sampleRate * 3 / 10
    /// Enough for the names and tone of the current message, small enough to stay fast.
    private static let precedingTextLength = 500
    /// People let go of the key while still finishing the last syllable, and the
    /// tap hands audio over in buffers of ~85 ms at 48 kHz: a quarter of a second
    /// keeps that syllable without the user waiting noticeably longer for the text.
    static let defaultReleaseTail: Duration = .milliseconds(250)

    init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        enhancer: Enhancer,
        focus: FocusInspecting,
        inserter: TextInserting,
        language: @escaping () -> String,
        enhancementEnabled: @escaping () -> Bool,
        shareFieldContext: @escaping () -> Bool,
        transcriptionEngine: @escaping () -> TranscriptionEngine = { .parakeet },
        reviewer: @escaping () -> Reviewer? = { nil },
        loadingEngine: @escaping () -> TranscriptionEngine? = { nil },
        enhancementTimeout: Duration = .seconds(8),
        releaseTail: Duration = defaultReleaseTail,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.enhancer = enhancer
        self.focus = focus
        self.inserter = inserter
        self.language = language
        self.enhancementEnabled = enhancementEnabled
        self.shareFieldContext = shareFieldContext
        self.transcriptionEngine = transcriptionEngine
        self.reviewer = reviewer
        self.loadingEngine = loadingEngine
        self.enhancementTimeout = enhancementTimeout
        self.releaseTail = releaseTail
        self.sleep = sleep
    }

    func handle(_ gesture: FnKeyGestureOutput) {
        switch gesture {
        case .pressed:
            // Earlier dictations still being processed do not hold the microphone.
            guard capture == .idle else { return }
            // Recording now would only stall on transcription: say why instead.
            if let engine = loadingEngine() { return finish(.modelLoading(engine)) }
            cutTail()
            // The previous dictation's field is read now, before this one lands in it.
            insertionObserver?.settle()
            bundleID = focus.frontmostBundleID()
            context = DictationContext(
                category: AppCategory(bundleID: bundleID),
                appName: focus.frontmostAppName()
            )
            // Shown at once: opening the microphone can take seconds.
            capture = .starting
            pendingGesture = nil
            starting = Task {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    try await recorder.start()
                    Log.dictation.info("microphone opened in \(Self.milliseconds(clock.now - start)) ms")
                } catch {
                    Log.dictation.error("microphone could not start: \(error.localizedDescription, privacy: .public)")
                    ErrorReporter.capture(error, "microphone could not start", category: "recorder")
                    capture = .idle
                    return finish(.failed(Self.microphoneFailure(error)))
                }
                capture = .recording
                if let gesture = pendingGesture {
                    pendingGesture = nil
                    handle(gesture)
                }
            }

        case .cancelled:
            if capture == .starting { pendingGesture = .cancelled; return }
            guard capture == .recording else { return }
            _ = recorder.stop()
            capture = .idle

        case .released:
            if capture == .starting { pendingGesture = .released; return }
            guard capture == .recording else { return }
            // Read on release rather than press: Electron apps only build their
            // accessibility tree once asked, which happens on press. The read
            // can take the whole AX messaging timeout, so it runs during the
            // release tail and while the audio is transcribed rather than before.
            var fieldContext: Task<FieldContext, Never>?
            if enhancementEnabled(), shareFieldContext() {
                fieldContext = Task { [focus] in await focus.fieldContext(maxLength: Self.precedingTextLength) }
            }
            // The pill switches now: the tail is not felt as more recording.
            // A press during the tail cuts it short, so the audio of one
            // dictation never bleeds into the next. The gesture already
            // ended, so no cancel can reach this dictation; quitting mid-tail
            // just drops it, as quitting mid-recording does.
            let id = nextID
            nextID += 1
            capture = .idle
            pending.append(PendingDictation(id: id, phase: .transcribing))
            tailOwner = id
            let previous = lastReleased
            let dictation = Dictation(context: context, bundleID: bundleID)
            let task = Task {
                await sleep(releaseTail)
                let samples = takeTail(of: id)
                await process(id, samples, dictation, fieldContext: fieldContext, after: previous)
            }
            processing[id] = task
            lastReleased = task
        }
    }

    /// What `process` needs of the press that started a dictation.
    private struct Dictation {
        var context: DictationContext
        let bundleID: String?
    }

    /// Ends the release tail of the previous dictation, if still running,
    /// so the microphone is free for the next one.
    private func cutTail() {
        guard let owner = tailOwner else { return }
        tailOwner = nil
        cutTails[owner] = recorder.stop()
        Log.dictation.info("release tail cut short by a new press")
    }

    /// The audio of dictation `id`, once its tail is over.
    private func takeTail(of id: Int) -> [Float] {
        guard tailOwner == id else { return cutTails.removeValue(forKey: id) ?? [] }
        tailOwner = nil
        Log.dictation.info("kept recording \(Self.milliseconds(self.releaseTail)) ms after release")
        return recorder.stop()
    }

    /// Waits for the microphone to open, or to fail, after a press.
    func waitUntilStarted() async {
        await starting?.value
    }

    /// Short enough for the pill; the details go to the log and Sentry.
    private static func microphoneFailure(_ error: Error) -> String {
        if let error = error as? AudioRecorder.RecorderError { return error.localizedDescription }
        return String(localized: "Micro indisponible")
    }

    /// Waits for every released dictation to complete.
    func waitUntilIdle() async {
        while let task = processing.values.first {
            await task.value
        }
    }

    /// Runs after the transcriptions already queued, and times only its own.
    private func transcribeInTurn(_ samples: [Float]) async throws -> (Transcription, Duration) {
        let previous = transcribing
        let work = Task { [transcriber, language] in
            await previous?.value
            let clock = ContinuousClock()
            let start = clock.now
            let transcript = try await transcriber.transcription(samples: samples, language: language())
            return (transcript, clock.now - start)
        }
        transcribing = Task { _ = await work.result }
        return try await work.value
    }

    private func process(
        _ id: Int,
        _ samples: [Float],
        _ dictation: Dictation,
        fieldContext: Task<FieldContext, Never>?,
        after previous: Task<Void, Never>?
    ) async {
        var context = dictation.context
        let bundleID = dictation.bundleID
        guard samples.count >= Self.minimumSampleCount, !AudioAnalysis.isSilent(samples) else {
            let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
            let peak = AudioAnalysis.peakRMS(samples)
            Log.dictation.info("discarded \(audio, format: .fixed(precision: 1)) s of audio, peak RMS \(peak, format: .fixed(precision: 4)) (threshold \(AudioAnalysis.silenceThreshold, format: .fixed(precision: 4)))")
            return complete(id, .discarded)
        }

        let clock = ContinuousClock()
        let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        var transcript: Transcription
        let transcription: Duration
        let engine = transcriptionEngine()
        do {
            (transcript, transcription) = try await transcribeInTurn(samples)
            transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let doubtful = transcript.words.count { $0.confidence < DoubtfulWords.threshold }
            Log.dictation.info("transcribed \(audio, format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(transcription)) ms, \(doubtful) doubtful words")
        } catch {
            Log.dictation.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "transcription with \(engine.rawValue) failed", category: "transcriber")
            return complete(id, .failed(String(localized: "Transcription impossible")))
        }
        guard !transcript.text.isEmpty else { return complete(id, .discarded) }

        if let fieldContext {
            context.include(await fieldContext.value)
            // Sizes only: the text, title and host are the user's.
            Log.dictation.info("""
                field context: \(context.precedingText?.count ?? 0) characters before, \
                \(context.followingText?.count ?? 0) after, label \(context.fieldLabel != nil), \
                title \(context.windowTitle != nil), web \(context.webHost != nil), \
                category \(context.category.rawValue, privacy: .public)
                """)
            onFieldContext?(context)
        }

        // Claude gets Parakeet's unknown tokens as is and picks the character
        // they stand for; the fallback turns any it leaves into guillemets.
        var text = UnknownTokens.resolved(transcript.text)
        var raw = false
        var enhancement: Duration?
        var reviewer: Reviewer?
        if enhancementEnabled() {
            setPhase(.enhancing, of: id)
            let start = clock.now
            if let enhanced = await enhanceWithTimeout(transcript, context: context), !enhanced.isEmpty {
                text = UnknownTokens.resolved(enhanced)
            } else {
                raw = true
            }
            let elapsed = clock.now - start
            enhancement = elapsed
            reviewer = self.reviewer()
            Log.dictation.info("enhanced in \(Self.milliseconds(elapsed)) ms by \(reviewer?.rawValue ?? "nobody", privacy: .public), raw: \(raw)")
        }

        // Texts land in release order, even when Claude was faster on a later one.
        await previous?.value
        let start = clock.now
        let outcome: DictationOutcome
        if focus.hasEditableFocus() {
            let keep = keepSamples() && onSample != nil
            let follow = followInsertions() && onFollowUp != nil
            let observer = keep || follow ? insertionObserver : nil
            // Read before the paste: Cmd+V lands some time after it is posted.
            let watch = observer?.watchFocusedField()
            await inserter.paste(text)
            outcome = .pasted(raw: raw)
            // A single read later on, shared by every consumer.
            let followUp: Task<InsertionFollowUp?, Never>? = if let observer, let watch {
                Task { await observer.followUp(watch, inserted: text) }
            } else {
                nil
            }
            if follow, let followUp, let onFollowUp {
                Task {
                    if let result = await followUp.value { onFollowUp(result) }
                }
            }
            if keep {
                onSample?(DictationSample(
                    date: .now, samples: samples, engine: engine, language: language(),
                    bundleID: bundleID, category: context.category,
                    transcript: transcript.text, inserted: text, enhanced: enhancement != nil && !raw,
                    vocabularyBoosted: transcript.vocabularyBoosted, followUp: followUp
                ))
            }
        } else {
            inserter.copyToPasteboard(text)
            outcome = .copied(raw: raw)
        }
        let insertion = clock.now - start
        Log.dictation.info("inserted in \(Self.milliseconds(insertion)) ms")
        onRecord?(DictationRecord(
            date: .now,
            words: DictationRecord.wordCount(of: text),
            audio: audio,
            engine: engine,
            transcription: Self.seconds(transcription),
            enhancement: enhancement.map(Self.seconds),
            reviewer: reviewer,
            insertion: Self.seconds(insertion)
        ))
        complete(id, outcome)
    }

    private static func milliseconds(_ elapsed: Duration) -> Int {
        Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func seconds(_ elapsed: Duration) -> TimeInterval {
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func enhanceWithTimeout(_ transcript: Transcription, context: DictationContext) async -> String? {
        let work = Task { [enhancer, context] in
            try await enhancer.enhance(transcript, context: context)
        }
        let timer = Task { [enhancementTimeout] in
            try await Task.sleep(for: enhancementTimeout)
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            // The cutoff doing its job: the raw transcript goes in and the
            // record keeps no enhancement time, which is where a slow Claude
            // shows. Not a failure to look into.
            Log.dictation.notice("enhancement timed out after \(self.enhancementTimeout), raw transcript inserted")
            ErrorReporter.breadcrumb("enhancement timed out after \(enhancementTimeout)", category: "enhancer")
            return nil
        } catch let error as ClaudeCLIError where error.isUsageLimit {
            // The subscription's limit is spent until it resets: Claude's
            // answer, not a failure of ours. The raw transcript goes in.
            Log.dictation.notice("claude usage limit reached, raw transcript inserted: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.breadcrumb("claude usage limit reached", category: "enhancer")
            return nil
        } catch {
            Log.dictation.error("enhancement failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "enhancement failed, raw transcript inserted", category: "enhancer")
            return nil
        }
    }

    private func setPhase(_ phase: DictationPhase, of id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].phase = phase
    }

    /// Ends a released dictation.
    private func complete(_ id: Int, _ outcome: DictationOutcome) {
        pending.removeAll { $0.id == id }
        processing[id] = nil
        finish(outcome)
    }

    private func finish(_ outcome: DictationOutcome) {
        lastOutcome = outcome
        onOutcome?(outcome)
    }
}
