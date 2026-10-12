import Foundation
import Observation

enum DictationPhase: Equatable {
    case idle
    case recording
    /// Whisper is turning the audio into text.
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

/// Orchestrates one dictation: record → transcribe → enhance → insert.
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    private(set) var lastOutcome: DictationOutcome?

    @ObservationIgnored let recorder: AudioRecording
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let enhancer: Enhancer
    @ObservationIgnored private let focus: FocusInspecting
    @ObservationIgnored private let inserter: TextInserting
    /// Vocabulary handed to Whisper; empty when Claude alone handles the jargon.
    @ObservationIgnored private let whisperVocabulary: () -> [String]
    /// ISO 639-1 code of the language being dictated.
    @ObservationIgnored private let language: () -> String
    @ObservationIgnored private let enhancementEnabled: () -> Bool
    /// Whether the text before the cursor may be sent to Claude.
    @ObservationIgnored private let shareFieldContext: () -> Bool
    /// The engine behind `transcriber`, for the statistics.
    @ObservationIgnored private let transcriptionEngine: () -> TranscriptionEngine
    /// The engine whose model is not in memory yet, nil once dictation can start.
    @ObservationIgnored private let loadingEngine: () -> TranscriptionEngine?
    @ObservationIgnored private let enhancementTimeout: Duration
    @ObservationIgnored private var context = DictationContext()
    @ObservationIgnored private var processing: Task<Void, Never>?

    /// Called once per finished dictation, after `phase` returns to idle.
    @ObservationIgnored var onOutcome: ((DictationOutcome) -> Void)?
    /// Called once per dictation that inserted text, with its timings.
    @ObservationIgnored var onRecord: ((DictationRecord) -> Void)?

    private static let minimumSampleCount = AudioAnalysis.sampleRate * 3 / 10
    /// Enough for the names and tone of the current message, small enough to stay fast.
    private static let precedingTextLength = 500

    init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        enhancer: Enhancer,
        focus: FocusInspecting,
        inserter: TextInserting,
        whisperVocabulary: @escaping () -> [String],
        language: @escaping () -> String,
        enhancementEnabled: @escaping () -> Bool,
        shareFieldContext: @escaping () -> Bool,
        transcriptionEngine: @escaping () -> TranscriptionEngine = { .whisper },
        loadingEngine: @escaping () -> TranscriptionEngine? = { nil },
        enhancementTimeout: Duration = .seconds(8)
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.enhancer = enhancer
        self.focus = focus
        self.inserter = inserter
        self.whisperVocabulary = whisperVocabulary
        self.language = language
        self.enhancementEnabled = enhancementEnabled
        self.shareFieldContext = shareFieldContext
        self.transcriptionEngine = transcriptionEngine
        self.loadingEngine = loadingEngine
        self.enhancementTimeout = enhancementTimeout
    }

    func handle(_ gesture: FnKeyGestureOutput) {
        switch gesture {
        case .pressed:
            guard phase == .idle else { return }
            // Recording now would only stall on transcription: say why instead.
            if let engine = loadingEngine() { return finish(.modelLoading(engine)) }
            context = DictationContext(
                category: AppCategory(bundleID: focus.frontmostBundleID()),
                appName: focus.frontmostAppName()
            )
            do {
                try recorder.start()
                phase = .recording
            } catch {
                ErrorReporter.capture(error, "microphone could not start", category: "recorder")
                finish(.failed("Micro indisponible : \(error.localizedDescription)"))
            }

        case .cancelled:
            guard phase == .recording else { return }
            _ = recorder.stop()
            phase = .idle

        case .released:
            guard phase == .recording else { return }
            let samples = recorder.stop()
            // Read on release rather than press: Electron apps only build their
            // accessibility tree once asked, which happens on press.
            if enhancementEnabled(), shareFieldContext() {
                context.precedingText = focus.precedingText(maxLength: Self.precedingTextLength)
                Log.dictation.info("preceding text: \(self.context.precedingText?.count ?? 0) characters")
            }
            phase = .transcribing
            processing = Task { await process(samples) }
        }
    }

    /// Waits for the in-flight dictation, if any, to complete.
    func waitUntilIdle() async {
        await processing?.value
    }

    private func process(_ samples: [Float]) async {
        guard samples.count >= Self.minimumSampleCount, !AudioAnalysis.isSilent(samples) else {
            return finish(.discarded)
        }

        let clock = ContinuousClock()
        let audio = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        let transcript: String
        let transcription: Duration
        let engine = transcriptionEngine()
        do {
            let start = clock.now
            transcript = try await transcriber.transcribe(samples: samples, vocabulary: whisperVocabulary(), language: language())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            transcription = clock.now - start
            Log.dictation.info("transcribed \(audio, format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(transcription)) ms")
        } catch {
            ErrorReporter.capture(error, "transcription with \(engine.rawValue) failed", category: "transcriber")
            return finish(.failed("Transcription impossible : \(error.localizedDescription)"))
        }
        guard !transcript.isEmpty else { return finish(.discarded) }

        var text = transcript
        var raw = false
        var enhancement: Duration?
        if enhancementEnabled() {
            phase = .enhancing
            let start = clock.now
            if let enhanced = await enhanceWithTimeout(transcript), !enhanced.isEmpty {
                text = enhanced
            } else {
                raw = true
            }
            let elapsed = clock.now - start
            enhancement = elapsed
            Log.dictation.info("enhanced in \(Self.milliseconds(elapsed)) ms, raw: \(raw)")
        }

        let start = clock.now
        let outcome: DictationOutcome
        if focus.hasEditableFocus() {
            await inserter.paste(text)
            outcome = .pasted(raw: raw)
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
            insertion: Self.seconds(insertion)
        ))
        finish(outcome)
    }

    private static func milliseconds(_ elapsed: Duration) -> Int {
        Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func seconds(_ elapsed: Duration) -> TimeInterval {
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func enhanceWithTimeout(_ transcript: String) async -> String? {
        let work = Task { [enhancer, context] in
            try await enhancer.enhance(transcript: transcript, context: context)
        }
        let timer = Task { [enhancementTimeout] in
            try await Task.sleep(for: enhancementTimeout)
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            Log.dictation.error("enhancement timed out")
            ErrorReporter.capture(message: "enhancement timed out after \(enhancementTimeout)", category: "enhancer", level: .warning)
            return nil
        } catch {
            Log.dictation.error("enhancement failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "enhancement failed, raw transcript inserted", category: "enhancer")
            return nil
        }
    }

    private func finish(_ outcome: DictationOutcome) {
        phase = .idle
        lastOutcome = outcome
        onOutcome?(outcome)
    }
}
