import Foundation
import Observation
import DictateKit

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
    /// Nothing worth inserting after a press too short to be meant: no flash.
    case discarded
    /// The key was held on purpose but nothing was heard (silence, empty transcript).
    case unheard
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
    /// The engine whose model is not in memory yet, nil once dictation can start.
    @ObservationIgnored private let loadingEngine: () -> TranscriptionEngine?
    @ObservationIgnored private let enhancementTimeout: Duration
    /// Whether a reply left the dictation: `ReviewGuard.diverges`, injected so
    /// tests can use replies of any shape.
    @ObservationIgnored private let diverges: (_ reply: String, _ transcript: String) -> Bool
    /// How long a transcription may take, on top of half the audio's length:
    /// a stuck engine call must not hold every later dictation.
    @ObservationIgnored private let transcriptionTimeout: Duration
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
    /// The previous dictations' fields being read again, which must be over
    /// before the next paste changes them.
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// Releases the recording once it reaches `maximumRecording`.
    @ObservationIgnored private var recordingLimit: Task<Void, Never>?
    /// Longest recording before it is released on its own: a key-up nobody
    /// received must not leave the microphone open and the audio growing.
    @ObservationIgnored private let maximumRecording: Duration
    /// A release or cancel that came while the microphone was still starting.
    @ObservationIgnored private var pendingGesture: FnKeyGestureOutput?

    /// Called once per finished dictation, after it left `pending`.
    @ObservationIgnored var onOutcome: ((DictationOutcome) -> Void)?
    /// Called once per dictation that inserted text, with its timings.
    @ObservationIgnored var onRecord: ((DictationRecord) -> Void)?
    /// The bundle IDs of the apps where Return is pressed after the paste.
    @ObservationIgnored var autoSendApps: () -> Set<String> = { [] }
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
    /// Below a second of holding, an empty dictation is taken for a slip of
    /// the finger and passes silently rather than flashing "nothing heard".
    static let intentionalPress: Duration = .seconds(1)
    /// Enough for the names and tone of the current message, small enough to stay fast.
    private static let precedingTextLength = 500
    /// People let go of the key while still finishing the last syllable, and the
    /// tap hands audio over in buffers of ~85 ms at 48 kHz: a quarter of a second
    /// keeps that syllable without the user waiting noticeably longer for the text.
    static let defaultReleaseTail: Duration = .milliseconds(250)
    /// Far longer than anyone dictates in one go: about 38 MB of audio.
    static let defaultMaximumRecording: Duration = .seconds(10 * 60)

    init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        enhancer: Enhancer,
        focus: FocusInspecting,
        inserter: TextInserting,
        language: @escaping () -> String,
        enhancementEnabled: @escaping () -> Bool,
        shareFieldContext: @escaping () -> Bool,
        loadingEngine: @escaping () -> TranscriptionEngine? = { nil },
        enhancementTimeout: Duration = .seconds(8),
        diverges: @escaping (_ reply: String, _ transcript: String) -> Bool = ReviewGuard.diverges,
        transcriptionTimeout: Duration = .seconds(30),
        releaseTail: Duration = defaultReleaseTail,
        maximumRecording: Duration = defaultMaximumRecording,
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
        self.loadingEngine = loadingEngine
        self.enhancementTimeout = enhancementTimeout
        self.diverges = diverges
        self.transcriptionTimeout = transcriptionTimeout
        self.releaseTail = releaseTail
        self.maximumRecording = maximumRecording
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
            if let observer = insertionObserver {
                settling = Task { await observer.settle() }
            }
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
                limitRecording()
                if let gesture = pendingGesture {
                    pendingGesture = nil
                    handle(gesture)
                }
            }

        case .cancelled:
            if capture == .starting { pendingGesture = .cancelled; starting?.cancel(); return }
            guard capture == .recording else { return }
            recordingLimit?.cancel()
            _ = recorder.stop()
            capture = .idle

        case .released:
            // Cuts short the wait for a headset still switching to its call
            // profile: what was said meanwhile could not be heard anyway.
            if capture == .starting { pendingGesture = .released; starting?.cancel(); return }
            guard capture == .recording else { return }
            recordingLimit?.cancel()
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

    /// Releases the recording just started once it reaches `maximumRecording`,
    /// as if the key had come up: what was said is kept and inserted.
    private func limitRecording() {
        recordingLimit?.cancel()
        recordingLimit = Task { [maximumRecording] in
            try? await Task.sleep(for: maximumRecording)
            guard !Task.isCancelled, capture == .recording else { return }
            Log.dictation.notice("recording reached \(maximumRecording) without a release: released")
            ErrorReporter.breadcrumb("recording reached its maximum duration", category: "dictation")
            handle(.released)
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
    /// Gives up past its deadline, counted from its own start: the engine call
    /// is abandoned, and the next dictations no longer wait for it.
    private func transcribeInTurn(_ samples: [Float]) async throws -> (Transcription, Duration) {
        let previous = transcribing
        let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        let limit = transcriptionTimeout + .seconds(audio / 2)
        let work = Task { [transcriber, language] in
            await previous?.value
            let clock = ContinuousClock()
            let start = clock.now
            let engine = Task { try await transcriber.transcription(samples: samples, language: language()) }
            let transcript = try await value(of: engine, within: limit) { _ in
                Log.dictation.notice("an abandoned transcription finished after all")
            }
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
            return complete(id, emptyOutcome(samples))
        }

        let clock = ContinuousClock()
        let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        var transcript: Transcription
        let transcription: Duration
        // The only engine, recorded with each dictation for the statistics.
        let engine = TranscriptionEngine.parakeet
        do {
            (transcript, transcription) = try await transcribeInTurn(samples)
            transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let doubtful = transcript.words.count { $0.confidence < DoubtfulWords.threshold }
            Log.dictation.info("transcribed \(audio, format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(transcription)) ms, \(doubtful) doubtful words")
        } catch is DeadlineExceeded {
            Log.dictation.error("transcription of \(audio, format: .fixed(precision: 1)) s of audio timed out")
            ErrorReporter.capture(message: "transcription with \(engine.rawValue) timed out", category: "transcriber")
            return complete(id, .failed(String(localized: "Transcription impossible")))
        } catch {
            Log.dictation.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "transcription with \(engine.rawValue) failed", category: "transcriber")
            return complete(id, .failed(String(localized: "Transcription impossible")))
        }
        guard !transcript.text.isEmpty else { return complete(id, emptyOutcome(samples)) }

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
            // Who was asked, for the statistics when no review comes back.
            let planned = enhancer.plannedReviewer
            let review = await enhanceWithTimeout(transcript, context: context)
            if let review, !review.text.isEmpty {
                text = UnknownTokens.resolved(review.text)
            } else {
                raw = true
            }
            let elapsed = clock.now - start
            enhancement = elapsed
            reviewer = review?.reviewer ?? planned
            Log.dictation.info("enhanced in \(Self.milliseconds(elapsed)) ms by \(reviewer?.rawValue ?? "nobody", privacy: .public), raw: \(raw)")
        }

        // Texts land in release order, even when Claude was faster on a later one.
        await previous?.value
        await settling?.value
        let start = clock.now
        let outcome: DictationOutcome
        if await focus.hasEditableFocus() {
            let keep = keepSamples() && onSample != nil
            let follow = followInsertions() && onFollowUp != nil
            let observer = keep || follow ? insertionObserver : nil
            // Read before the paste: Cmd+V lands some time after it is posted.
            let watch = await observer?.watchFocusedField()
            // The app in front now, not at the press: the text lands here. A
            // raw text is never sent: its review failed or was rejected, and
            // the user should read it first.
            let submit = !raw && AutoSend.applies(to: focus.frontmostBundleID(), in: autoSendApps())
            await inserter.paste(text, submit: submit)
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

    private func enhanceWithTimeout(_ transcript: Transcription, context: DictationContext) async -> Review? {
        let work = Task { [enhancer, context] in
            try await enhancer.review(transcript, context: context)
        }
        let timer = Task { [enhancementTimeout] in
            try await Task.sleep(for: enhancementTimeout)
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            var review = try await work.value
            review.text = review.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !diverges(review.text, transcript.text) else {
                noteRawInsertion(.diverged, error: nil)
                return nil
            }
            return review
        } catch {
            noteRawInsertion(ReviewFailure(error), error: error)
            return nil
        }
    }

    /// Why the raw transcript went in. Only an unexpected failure is reported:
    /// the others are a cutoff, a guard or a service doing their job.
    private func noteRawInsertion(_ failure: ReviewFailure, error: Error?) {
        let details = error?.localizedDescription ?? ""
        switch failure {
        case .timedOut:
            // The record keeps the time, which is where a slow reviewer shows.
            Log.dictation.notice("enhancement timed out after \(self.enhancementTimeout), raw transcript inserted")
            ErrorReporter.breadcrumb("enhancement timed out after \(enhancementTimeout)", category: "enhancer")
        case .rateLimited:
            Log.dictation.notice("reviewer limit reached, raw transcript inserted: \(details, privacy: .public)")
            ErrorReporter.breadcrumb("reviewer limit reached", category: "enhancer")
        case .disconnected:
            // Only the user can sign in again or fix the key, and the indicator tells them.
            Log.dictation.notice("reviewer signed out or key refused, raw transcript inserted: \(details, privacy: .public)")
            ErrorReporter.breadcrumb("reviewer signed out or key refused", category: "enhancer")
        case .diverged:
            // A reply that answered the field or followed something written in it.
            Log.dictation.notice("reply left the dictation, raw transcript inserted")
            ErrorReporter.breadcrumb("reply diverged", category: "enhancer")
        case .other:
            Log.dictation.error("enhancement failed: \(details, privacy: .public)")
            if let error { ErrorReporter.capture(error, "enhancement failed, raw transcript inserted", category: "enhancer") }
        }
    }

    private func setPhase(_ phase: DictationPhase, of id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].phase = phase
    }

    /// Ends a released dictation.
    /// `.unheard` only when the key was held long enough to be meant. The
    /// audio stands in for the hold: it runs from the microphone opening to
    /// the end of the release tail, which is taken off.
    private func emptyOutcome(_ samples: [Float]) -> DictationOutcome {
        let held = Double(samples.count) / Double(AudioAnalysis.sampleRate) - releaseTail / .seconds(1)
        return held >= Self.intentionalPress / .seconds(1) ? .unheard : .discarded
    }

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
