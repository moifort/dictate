import DictateKit
import Foundation
import Observation

enum DictationPhase: Equatable {
    case idle
    /// `fn` is held but the microphone is not open yet.
    case starting
    case recording
    /// The engine is turning the audio into text.
    case transcribing
    /// The reviewer is cleaning up the transcript.
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
/// waiting for the reviewer. Texts land in the order the key was released.
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

    /// What the controller works with.
    struct Services {
        var recorder: AudioRecording
        var transcriber: Transcriber
        var enhancer: Enhancer
        var focus: FocusInspecting
        var inserter: TextInserting
        /// Catches the field before each followed or kept paste, to read it
        /// again later. One read serves both `onSample` and `onFollowUp`.
        var insertionObserver: PostInsertionObserver?
    }

    /// What the controller reads of the user's settings, at each dictation.
    struct Settings {
        /// ISO 639-1 code of the language being dictated.
        var language: () -> String = { "fr" }
        var enhancementEnabled: () -> Bool = { true }
        /// Whether the text around the cursor may be sent to the reviewer.
        var shareFieldContext: () -> Bool = { true }
        /// The engine whose model is not in memory yet, nil once dictation can start.
        var loadingEngine: () -> TranscriptionEngine? = { nil }
        /// The bundle IDs of the apps where Return is pressed after the paste.
        var autoSendApps: () -> Set<String> = { [] }
        /// Whether to hand each pasted dictation, audio included, to `onSample`.
        var keepSamples: () -> Bool = { false }
        /// Whether to hand each pasted dictation's field, read again a few seconds later, to `onFollowUp`.
        var followInsertions: () -> Bool = { false }
        /// Whether a reply left the dictation: `ReviewGuard.diverges`,
        /// replaced by tests that use replies of any shape.
        var diverges: (_ reply: String, _ transcript: String) -> Bool = ReviewGuard.diverges
    }

    /// How long each step may take.
    struct Timing {
        var enhancement: Duration = .seconds(8)
        /// On top of half the audio's length: a stuck engine call must not
        /// hold every later dictation.
        var transcription: Duration = .seconds(30)
        /// How long the microphone keeps capturing once the key is released.
        var releaseTail: Duration = DictationController.defaultReleaseTail
        /// Longest recording before it is released on its own: a key-up nobody
        /// received must not leave the microphone open and the audio growing.
        var maximumRecording: Duration = DictationController.defaultMaximumRecording
        /// Waits out `releaseTail`; replaced by tests to control when the tail ends.
        var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    /// What the controller tells the app.
    struct Events {
        /// Once per finished dictation, after it left `pending`.
        var onOutcome: ((DictationOutcome) -> Void)?
        /// Once per dictation that inserted text, with its timings.
        var onRecord: ((DictationRecord) -> Void)?
        /// Once per pasted dictation while `keepSamples` is true, for the evaluation corpus.
        var onSample: ((DictationSample) -> Void)?
        /// Once per pasted dictation while `followInsertions` is true, once the field was read again.
        var onFollowUp: ((InsertionFollowUp) -> Void)?
        /// Once per dictation whose field context was read, before the reviewer sees it.
        var onFieldContext: ((DictationContext) -> Void)?
    }

    @ObservationIgnored let recorder: AudioRecording
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let enhancer: Enhancer
    @ObservationIgnored private let focus: FocusInspecting
    @ObservationIgnored private let inserter: TextInserting
    @ObservationIgnored var insertionObserver: PostInsertionObserver?
    @ObservationIgnored var settings: Settings
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored var events = Events()
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
    /// Releases the recording once it reaches `timing.maximumRecording`.
    @ObservationIgnored private var recordingLimit: Task<Void, Never>?
    /// A release or cancel that came while the microphone was still starting.
    @ObservationIgnored private var pendingGesture: PushToTalkGestureOutput?

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

    init(_ services: Services, settings: Settings = Settings(), timing: Timing = Timing()) {
        recorder = services.recorder
        transcriber = services.transcriber
        enhancer = services.enhancer
        focus = services.focus
        inserter = services.inserter
        insertionObserver = services.insertionObserver
        self.settings = settings
        self.timing = timing
    }

    func handle(_ gesture: PushToTalkGestureOutput) {
        switch gesture {
        case .pressed:
            // Earlier dictations still being processed do not hold the microphone.
            guard capture == .idle else { return }
            // Recording now would only stall on transcription: say why instead.
            if let engine = settings.loadingEngine() { return finish(.modelLoading(engine)) }
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
                    Log.dictation.info("microphone opened in \((clock.now - start).milliseconds) ms")
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
            if capture == .starting {
                pendingGesture = .cancelled
                starting?.cancel()
                return
            }
            guard capture == .recording else { return }
            recordingLimit?.cancel()
            _ = recorder.stop()
            capture = .idle

        case .released:
            // Cuts short the wait for a headset still switching to its call
            // profile: what was said meanwhile could not be heard anyway.
            if capture == .starting {
                pendingGesture = .released
                starting?.cancel()
                return
            }
            guard capture == .recording else { return }
            recordingLimit?.cancel()
            // Read on release rather than press: Electron apps only build their
            // accessibility tree once asked, which happens on press. The read
            // can take the whole AX messaging timeout, so it runs during the
            // release tail and while the audio is transcribed rather than before.
            var fieldContext: Task<FieldContext, Never>?
            if settings.enhancementEnabled(), settings.shareFieldContext() {
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
                await timing.sleep(timing.releaseTail)
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
        recordingLimit = Task { [maximumRecording = timing.maximumRecording] in
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
        Log.dictation.info("kept recording \(self.timing.releaseTail.milliseconds) ms after release")
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
        let limit = timing.transcription + .seconds(audio / 2)
        let work = Task { [transcriber, language = settings.language] in
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

    /// One released dictation, step by step: transcribe, read the field,
    /// review, insert, record. Each step that ends it completes it.
    private func process(
        _ id: Int,
        _ samples: [Float],
        _ dictation: Dictation,
        fieldContext: Task<FieldContext, Never>?,
        after previous: Task<Void, Never>?
    ) async {
        guard samples.count >= Self.minimumSampleCount, !AudioAnalysis.isSilent(samples) else {
            let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
            let peak = AudioAnalysis.peakRMS(samples)
            Log.dictation.info(
                "discarded \(audio, format: .fixed(precision: 1)) s of audio, peak RMS \(peak, format: .fixed(precision: 4)) (threshold \(AudioAnalysis.silenceThreshold, format: .fixed(precision: 4)))"
            )
            return complete(id, emptyOutcome(samples))
        }
        guard let (transcript, transcription) = await transcribe(samples) else {
            return complete(id, .failed(String(localized: "Transcription impossible")))
        }
        guard !transcript.text.isEmpty else { return complete(id, emptyOutcome(samples)) }

        var context = dictation.context
        if let fieldContext { context = await include(fieldContext, in: context) }

        let review = await review(id, transcript, context: context)

        // Texts land in release order, even when the reviewer was faster on a later one.
        await previous?.value
        await settling?.value
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await insert(review, of: transcript, samples: samples, dictation: dictation, context: context)
        let insertion = clock.now - start
        Log.dictation.info("inserted in \(insertion.milliseconds) ms")
        events.onRecord?(
            DictationRecord(
                date: .now,
                words: DictationRecord.wordCount(of: review.text),
                audio: Double(samples.count) / Double(AudioAnalysis.sampleRate),
                engine: Self.engine,
                transcription: transcription.timeInterval,
                enhancement: review.duration.map(\.timeInterval),
                reviewer: review.reviewer,
                insertion: insertion.timeInterval
            ))
        complete(id, outcome)
    }

    /// The only engine, recorded with each dictation for the statistics.
    private static let engine = TranscriptionEngine.parakeet

    /// The transcript, trimmed, and how long it took; nil when it failed.
    private func transcribe(_ samples: [Float]) async -> (Transcription, Duration)? {
        let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        do {
            var (transcript, elapsed) = try await transcribeInTurn(samples)
            transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let doubtful = transcript.words.count { $0.confidence < DoubtfulWords.threshold }
            Log.dictation.info("transcribed \(audio, format: .fixed(precision: 1)) s of audio in \(elapsed.milliseconds) ms, \(doubtful) doubtful words")
            return (transcript, elapsed)
        } catch is DeadlineExceeded {
            Log.dictation.error("transcription of \(audio, format: .fixed(precision: 1)) s of audio timed out")
            ErrorReporter.capture(message: "transcription with \(Self.engine.rawValue) timed out", category: "transcriber")
            return nil
        } catch {
            Log.dictation.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "transcription with \(Self.engine.rawValue) failed", category: "transcriber")
            return nil
        }
    }

    /// The press's context with what was read of the field.
    private func include(_ fieldContext: Task<FieldContext, Never>, in context: DictationContext) async -> DictationContext {
        var context = context
        context.include(await fieldContext.value)
        // Sizes only: the text, title and host are the user's.
        Log.dictation.info(
            """
            field context: \(context.precedingText?.count ?? 0) characters before, \
            \(context.followingText?.count ?? 0) after, label \(context.fieldLabel != nil), \
            title \(context.windowTitle != nil), web \(context.webHost != nil), \
            category \(context.category.rawValue, privacy: .public)
            """)
        events.onFieldContext?(context)
        return context
    }

    /// What the review step leaves to insert and to record.
    private struct ReviewedText {
        var text: String
        /// The review failed or was rejected: the transcript went in as heard.
        var raw = false
        /// How long the review took; nil when there was none.
        var duration: Duration?
        var reviewer: Reviewer?
    }

    private func review(_ id: Int, _ transcript: Transcription, context: DictationContext) async -> ReviewedText {
        // The reviewer gets Parakeet's unknown tokens as is and picks the
        // character they stand for; the fallback turns any it leaves into guillemets.
        var reviewed = ReviewedText(text: UnknownTokens.resolved(transcript.text))
        guard settings.enhancementEnabled() else { return reviewed }
        setPhase(.enhancing, of: id)
        let clock = ContinuousClock()
        let start = clock.now
        // Who was asked, for the statistics when no review comes back.
        let planned = enhancer.plannedReviewer
        let review = await enhanceWithTimeout(transcript, context: context)
        if let review, !review.text.isEmpty {
            reviewed.text = UnknownTokens.resolved(review.text)
        } else {
            reviewed.raw = true
        }
        let elapsed = clock.now - start
        reviewed.duration = elapsed
        reviewed.reviewer = review?.reviewer ?? planned
        Log.dictation.info("enhanced in \(elapsed.milliseconds) ms by \(reviewed.reviewer?.rawValue ?? "nobody", privacy: .public), raw: \(reviewed.raw)")
        return reviewed
    }

    /// Pastes into the focused field, or leaves the text in the pasteboard,
    /// and hands the pasted ones to the corpus and the vocabulary suggestions.
    private func insert(
        _ review: ReviewedText, of transcript: Transcription, samples: [Float],
        dictation: Dictation, context: DictationContext
    ) async -> DictationOutcome {
        guard await focus.hasEditableFocus() else {
            inserter.copyToPasteboard(review.text)
            return .copied(raw: review.raw)
        }
        let keep = settings.keepSamples() && events.onSample != nil
        let follow = settings.followInsertions() && events.onFollowUp != nil
        let observer = keep || follow ? insertionObserver : nil
        // Read before the paste: Cmd+V lands some time after it is posted.
        let watch = await observer?.watchFocusedField()
        // The app in front now, not at the press: the text lands here. A raw
        // text is never sent: its review failed or was rejected, and the user
        // should read it first.
        let submit = !review.raw && AutoSend.applies(to: focus.frontmostBundleID(), in: settings.autoSendApps())
        await inserter.paste(review.text, submit: submit)
        // A single read later on, shared by every consumer.
        let followUp: Task<InsertionFollowUp?, Never>? =
            if let observer, let watch {
                Task { await observer.followUp(watch, inserted: review.text) }
            } else {
                nil
            }
        if follow, let followUp, let onFollowUp = events.onFollowUp {
            Task {
                if let result = await followUp.value { onFollowUp(result) }
            }
        }
        if keep {
            events.onSample?(
                DictationSample(
                    date: .now, samples: samples, engine: Self.engine, language: settings.language(),
                    bundleID: dictation.bundleID, category: context.category,
                    transcript: transcript.text, inserted: review.text, enhanced: review.duration != nil && !review.raw,
                    vocabularyBoosted: transcript.vocabularyBoosted, followUp: followUp
                ))
        }
        return .pasted(raw: review.raw)
    }

    private func enhanceWithTimeout(_ transcript: Transcription, context: DictationContext) async -> Review? {
        let work = Task { [enhancer, context] in
            try await enhancer.review(transcript, context: context)
        }
        let timer = Task { [timeout = timing.enhancement] in
            try await Task.sleep(for: timeout)
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            var review = try await work.value
            review.text = review.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !settings.diverges(review.text, transcript.text) else {
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
            Log.dictation.notice("enhancement timed out after \(self.timing.enhancement), raw transcript inserted")
            ErrorReporter.breadcrumb("enhancement timed out after \(timing.enhancement)", category: "enhancer")
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
        let held = Double(samples.count) / Double(AudioAnalysis.sampleRate) - timing.releaseTail / .seconds(1)
        return held >= Self.intentionalPress / .seconds(1) ? .unheard : .discarded
    }

    private func complete(_ id: Int, _ outcome: DictationOutcome) {
        pending.removeAll { $0.id == id }
        processing[id] = nil
        finish(outcome)
    }

    private func finish(_ outcome: DictationOutcome) {
        lastOutcome = outcome
        events.onOutcome?(outcome)
    }
}
