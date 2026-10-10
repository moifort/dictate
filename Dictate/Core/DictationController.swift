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
    @ObservationIgnored private let enhancementEnabled: () -> Bool
    @ObservationIgnored private let enhancementTimeout: Duration
    @ObservationIgnored private var category: AppCategory = .other
    @ObservationIgnored private var processing: Task<Void, Never>?

    /// Called once per finished dictation, after `phase` returns to idle.
    @ObservationIgnored var onOutcome: ((DictationOutcome) -> Void)?

    private static let minimumSampleCount = AudioAnalysis.sampleRate * 3 / 10

    init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        enhancer: Enhancer,
        focus: FocusInspecting,
        inserter: TextInserting,
        whisperVocabulary: @escaping () -> [String],
        enhancementEnabled: @escaping () -> Bool,
        enhancementTimeout: Duration = .seconds(8)
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.enhancer = enhancer
        self.focus = focus
        self.inserter = inserter
        self.whisperVocabulary = whisperVocabulary
        self.enhancementEnabled = enhancementEnabled
        self.enhancementTimeout = enhancementTimeout
    }

    func handle(_ gesture: FnKeyGestureOutput) {
        switch gesture {
        case .pressed:
            guard phase == .idle else { return }
            category = AppCategory(bundleID: focus.frontmostBundleID())
            do {
                try recorder.start()
                phase = .recording
            } catch {
                finish(.failed("Micro indisponible : \(error.localizedDescription)"))
            }

        case .cancelled:
            guard phase == .recording else { return }
            _ = recorder.stop()
            phase = .idle

        case .released:
            guard phase == .recording else { return }
            let samples = recorder.stop()
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
        let transcript: String
        do {
            let start = clock.now
            transcript = try await transcriber.transcribe(samples: samples, vocabulary: whisperVocabulary())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.dictation.info("transcribed \(Double(samples.count) / Double(AudioAnalysis.sampleRate), format: .fixed(precision: 1)) s of audio in \(Self.milliseconds(since: start, clock)) ms")
        } catch {
            return finish(.failed("Transcription impossible : \(error.localizedDescription)"))
        }
        guard !transcript.isEmpty else { return finish(.discarded) }

        var text = transcript
        var raw = false
        if enhancementEnabled() {
            phase = .enhancing
            let start = clock.now
            if let enhanced = await enhanceWithTimeout(transcript), !enhanced.isEmpty {
                text = enhanced
            } else {
                raw = true
            }
            Log.dictation.info("enhanced in \(Self.milliseconds(since: start, clock)) ms, raw: \(raw)")
        }

        let start = clock.now
        if focus.hasEditableFocus() {
            await inserter.paste(text)
            Log.dictation.info("pasted in \(Self.milliseconds(since: start, clock)) ms")
            finish(.pasted(raw: raw))
        } else {
            inserter.copyToPasteboard(text)
            finish(.copied(raw: raw))
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock) -> Int {
        let elapsed = clock.now - start
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func enhanceWithTimeout(_ transcript: String) async -> String? {
        let work = Task { [enhancer, category] in
            try await enhancer.enhance(transcript: transcript, category: category)
        }
        let timer = Task { [enhancementTimeout] in
            try await Task.sleep(for: enhancementTimeout)
            work.cancel()
        }
        defer { timer.cancel() }
        return try? await work.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(_ outcome: DictationOutcome) {
        phase = .idle
        lastOutcome = outcome
        onOutcome?(outcome)
    }
}
