import FluidAudio
import Foundation
import Observation

/// Searches the audio for the custom vocabulary and rewrites the words
/// Parakeet mangled, before Claude sees the transcript.
///
/// FluidAudio's CTC keyword spotting: a second, smaller model (Parakeet CTC
/// 110M) scores each term against the audio, and a term replaces the words it
/// sounds like only when the audio backs it better than what Parakeet wrote.
/// Experimental and off by default: that model was trained mostly on English,
/// and its effect on French dictations is still to be measured on the
/// evaluation corpus.
@Observable
final class VocabularyBooster {
    private(set) var state: TranscriberState = .notLoaded
    /// What the last rescoring added to the dictation, for the tests.
    @ObservationIgnored private(set) var lastDuration: Duration?
    @ObservationIgnored let modelFolder: URL
    @ObservationIgnored private let engine: any VocabularyRescoring

    init(modelDirectory: URL = ModelStorage.defaultDirectory) {
        modelFolder = Self.modelFolder(in: modelDirectory)
        engine = CtcVocabularyEngine(folder: modelFolder)
    }

    init(engine: any VocabularyRescoring, modelFolder: URL) {
        self.engine = engine
        self.modelFolder = modelFolder
    }

    /// Named after the Hugging Face repository, as FluidAudio expects.
    nonisolated static func modelFolder(in base: URL) -> URL {
        base.appending(path: Repo.parakeetCtc110m.folderName, directoryHint: .isDirectory)
    }

    nonisolated static func isModelDownloaded(in base: URL = ModelStorage.defaultDirectory) -> Bool {
        CtcModels.modelsExist(at: modelFolder(in: base))
    }

    var isModelDownloaded: Bool { engine.isModelDownloaded }

    /// Downloads the model the first time, about 100 MB, then loads it.
    func load() async {
        guard !state.isBusy, state != .ready else { return }
        state = .loading
        do {
            try await engine.load { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.state.isBusy else { return }
                    self.state = fraction < 1 ? .downloading(fraction) : .loading
                }
            }
            state = .ready
            ErrorReporter.breadcrumb("vocabulary boosting model ready", category: "transcriber")
        } catch {
            ErrorReporter.capture(error, "vocabulary boosting model failed to load", category: "transcriber")
            state = .failed(error.localizedDescription)
        }
    }

    /// Frees the model once the setting is turned off.
    func unload() async {
        guard state == .ready || state.isFailed else { return }
        await engine.unload()
        state = .notLoaded
    }

    /// The transcript rescored against `vocabulary`, or unchanged when there
    /// is nothing to look for, the model is not loaded yet, or rescoring fails.
    ///
    /// Never waits for the model: a dictation made while it downloads or
    /// loads goes through as Parakeet heard it, and starts the load if needed.
    func boost(
        _ transcription: Transcription, tokenTimings: [TokenTiming], samples: [Float], vocabulary: [String]
    ) async -> Transcription {
        guard !vocabulary.isEmpty, !tokenTimings.isEmpty, !transcription.words.isEmpty else { return transcription }
        guard state == .ready else {
            Log.dictation.info("vocabulary boosting skipped: model not ready")
            if !state.isBusy { Task { await load() } }
            return transcription
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let rescored = try await engine.rescore(
                text: transcription.text, tokenTimings: tokenTimings, samples: samples, vocabulary: vocabulary
            )
            var boosted = rescored.map { VocabularyBoost.apply($0, to: transcription) } ?? transcription
            boosted.vocabularyBoosted = true
            let elapsed = clock.now - start
            lastDuration = elapsed
            let replaced = VocabularyBoost.replacedWordCount(from: transcription, to: boosted)
            // Counts only: the words are the user's.
            Log.dictation.info("vocabulary boosting took \(Self.milliseconds(elapsed)) ms, \(replaced) words replaced")
            return boosted
        } catch {
            Log.dictation.error("vocabulary boosting failed: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "vocabulary boosting failed, plain transcript kept", category: "transcriber")
            return transcription
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}

private extension TranscriberState {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

/// Merging the rescored text back into the transcript and its confidences.
nonisolated enum VocabularyBoost {
    /// The confidence of a word the vocabulary put in.
    ///
    /// The rescorer's scores are CTC log-likelihoods plus a context-biasing
    /// boost, on another scale than Parakeet's token probabilities: mapping
    /// one to the other would be arbitrary. A replacement both matches a term
    /// the user listed and beat Parakeet's word on the audio, so it counts as
    /// certain: flagged as doubtful, Claude could "fix" it back.
    static let replacedConfidence: Float = 1

    /// `rescored` laid over `transcription`: the words it kept keep their
    /// confidence, the ones it rewrote get `replacedConfidence`.
    ///
    /// The rescorer rebuilds its text from the same space-delimited words as
    /// `Transcription.words`, so the two align on the words it left alone. A
    /// replacement drops the punctuation stuck to the words it replaced:
    /// `nvidia,` becomes `NVIDIA`, so it is put back.
    ///
    /// Words are never dropped: a multi-word term can swallow its neighbour,
    /// "with Argo CD" becoming "Argo CD", and a term the user listed never
    /// stands for a word next to it.
    static func apply(_ rescored: String, to transcription: Transcription) -> Transcription {
        let old = transcription.words
        let new = rescored.split(separator: " ").map(String.init)
        guard !new.isEmpty else { return transcription }
        guard !old.isEmpty else { return Transcription(text: rescored, vocabularyBoosted: transcription.vocabularyBoosted) }

        var words: [Transcription.Word] = []
        var oldIndex = 0
        var newIndex = 0
        var replacedOld: [Transcription.Word] = []
        var replacedNew: [String] = []

        func flushReplacement() {
            defer {
                replacedOld = []
                replacedNew = []
            }
            guard !replacedNew.isEmpty else {
                words += replacedOld
                return
            }
            var texts = replacedNew
            if let first = replacedOld.first?.text {
                texts[0] = leadingPunctuation(of: first, missingFrom: texts[0]) + texts[0]
            }
            if let last = replacedOld.last?.text {
                texts[texts.count - 1] += trailingPunctuation(of: last, missingFrom: texts[texts.count - 1])
            }
            words += texts.map { Transcription.Word(text: $0, confidence: replacedConfidence) }
        }

        let common = longestCommonSubsequence(old.map(\.text), new)
        for (keptOld, keptNew) in common {
            replacedOld += old[oldIndex..<keptOld]
            replacedNew += new[newIndex..<keptNew]
            flushReplacement()
            words.append(old[keptOld])
            oldIndex = keptOld + 1
            newIndex = keptNew + 1
        }
        replacedOld += old[oldIndex...]
        replacedNew += new[newIndex...]
        flushReplacement()

        return Transcription(
            text: words.map(\.text).joined(separator: " "),
            words: words,
            vocabularyBoosted: transcription.vocabularyBoosted
        )
    }

    /// Words of `boosted` that are not in `original`, for the log.
    static func replacedWordCount(from original: Transcription, to boosted: Transcription) -> Int {
        boosted.words.count - longestCommonSubsequence(original.words.map(\.text), boosted.words.map(\.text)).count
    }

    /// Index pairs of the words both sequences share, in order.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func trailingPunctuation(of word: String, missingFrom replacement: String) -> String {
        let punctuation = String(word.reversed().prefix { isPunctuation($0) }.reversed())
        return replacement.hasSuffix(punctuation) ? "" : punctuation
    }

    private static func leadingPunctuation(of word: String, missingFrom replacement: String) -> String {
        let punctuation = String(word.prefix { isPunctuation($0) })
        return replacement.hasPrefix(punctuation) ? "" : punctuation
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}

/// Rescores a transcript against the audio, away from the main actor.
nonisolated protocol VocabularyRescoring: Sendable {
    var isModelDownloaded: Bool { get }
    func load(progress: @escaping @Sendable (Double) -> Void) async throws
    func unload() async
    /// The rewritten transcript, nil when no word changed.
    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float], vocabulary: [String]) async throws -> String?
}

/// Owns the CTC model and the rescorer built for the current vocabulary.
///
/// Mirrors `VocabularyBoostingSession`, FluidAudio's own glue, with two
/// differences: that session reads the tokenizer from FluidAudio's default
/// cache folder, while the app keeps every model under `ModelStorage`; and it
/// swallows inference errors, which the app wants to report.
actor CtcVocabularyEngine: VocabularyRescoring {
    private struct Loaded {
        let spotter: CtcKeywordSpotter
        let tokenizer: CtcTokenizer
    }

    private struct Session {
        let vocabulary: [String]
        let context: CustomVocabularyContext
        let rescorer: VocabularyRescorer
    }

    /// Recommended by FluidAudio for vocabularies of short terms that sound
    /// like ordinary words, which the default one is ("push", "build", "PR"):
    /// short terms get less of a boost, and the pass that proposes a term on
    /// acoustic evidence alone needs some spelling resemblance.
    static let rescorerConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50
    )

    nonisolated let folder: URL
    private var loaded: Loaded?
    private var loading: Task<Void, Error>?
    private var session: Session?

    init(folder: URL) {
        self.folder = folder
    }

    nonisolated var isModelDownloaded: Bool {
        CtcModels.modelsExist(at: folder)
    }

    /// Concurrent callers share one load, like `ParakeetEngine`.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard loaded == nil else { return }
        if let loading { return try await loading.value }
        let task = Task { try await performLoad(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        if !CtcModels.modelsExist(at: folder) {
            let tracker = DownloadTracker(report: progress)
            try await ModelHub.download(.parakeetCtc110m, to: folder.deletingLastPathComponent()) { tracker.update($0) }
            progress(1)
        }
        let models = try await CtcModels.load(from: folder, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: folder)
        // The blank token comes right after the vocabulary.
        loaded = Loaded(spotter: CtcKeywordSpotter(models: models, blankId: models.vocabulary.count), tokenizer: tokenizer)
    }

    func unload() async {
        loaded = nil
        session = nil
    }

    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float], vocabulary: [String]) async throws -> String? {
        try await load { _ in }
        guard let loaded else { return nil }
        let session = try await session(for: vocabulary, loaded: loaded)
        guard !session.context.terms.isEmpty else { return nil }

        let spotted = try await loaded.spotter.spotKeywordsWithLogProbs(
            audioSamples: samples, customVocabulary: session.context, minScore: nil
        )
        guard !spotted.logProbs.isEmpty else { return nil }
        // Thresholds tuned to the vocabulary size, as the session does.
        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: session.context.terms.count)
        let output = session.rescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: tokenTimings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: sizeConfig.cbw,
            marginSeconds: 0.5,
            minSimilarity: max(sizeConfig.minSimilarity, session.context.minSimilarity)
        )
        return output.wasModified ? output.text : nil
    }

    /// Tokenizing the terms and building the rescorer is redone only when the
    /// vocabulary changes.
    private func session(for vocabulary: [String], loaded: Loaded) async throws -> Session {
        if let session, session.vocabulary == vocabulary { return session }
        let terms = vocabulary.compactMap { text -> CustomVocabularyTerm? in
            let ids = loaded.tokenizer.encode(text)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: text, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: terms)
        let rescorer = try await VocabularyRescorer.create(
            spotter: loaded.spotter, vocabulary: context, config: Self.rescorerConfig, ctcModelDirectory: folder
        )
        let session = Session(vocabulary: vocabulary, context: context, rescorer: rescorer)
        self.session = session
        return session
    }
}
