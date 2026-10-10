import Foundation
import Observation
import WhisperKit

/// Local transcription with Whisper large-v3 turbo through WhisperKit.
@Observable
final class WhisperKitTranscriber: Transcriber {
    enum State: Equatable {
        case notLoaded
        /// First launch only: fraction of the ~630 MB model downloaded.
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    nonisolated static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private(set) var state: State = .notLoaded
    @ObservationIgnored private let engine: WhisperEngine

    init(modelDirectory: URL = WhisperKitTranscriber.defaultModelDirectory) {
        engine = WhisperEngine(modelName: Self.modelName, downloadBase: modelDirectory)
    }

    nonisolated static var defaultModelDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Dictate/Models", directoryHint: .isDirectory)
    }

    /// Where WhisperKit's hub snapshot puts the model inside the download base.
    nonisolated static func modelFolder(in base: URL) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml/\(modelName)", directoryHint: .isDirectory)
    }

    /// True once every compiled model is on disk, so launch needs no network.
    nonisolated static func isModelDownloaded(in base: URL = defaultModelDirectory) -> Bool {
        let folder = modelFolder(in: base)
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: "\($0).mlmodelc").path)
        }
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .loading: true
        default: false
        }
    }

    /// Downloads the model on first launch (~630 MB), then loads it in memory.
    func load() async {
        guard !isBusy, state != .ready else { return }
        state = .loading
        do {
            try await engine.load { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.isBusy else { return }
                    // The download is over: what remains is compiling the model for this Mac.
                    self.state = fraction < 1 ? .downloading(fraction) : .loading
                }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func startLive(vocabulary: [String]) -> any LiveTranscription {
        if state != .ready { Task { await load() } }
        let live = LiveChunkTranscription(engine: engine, vocabulary: vocabulary)
        Task { await live.start() }
        return live
    }

    /// Whole recording in one pass.
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String {
        if state != .ready { await load() }
        return try await engine.transcribe(chunk: samples, vocabulary: vocabulary)
    }
}

/// Owns the non-Sendable WhisperKit pipeline away from the main actor.
actor WhisperEngine: ChunkTranscribing {
    private let modelName: String
    private let downloadBase: URL
    private var pipeline: WhisperKit?

    init(modelName: String, downloadBase: URL) {
        self.modelName = modelName
        self.downloadBase = downloadBase
    }

    private var loading: Task<Void, Error>?

    /// Concurrent callers share one load: a dictation during startup must not
    /// trigger a second download or a second copy of the model in memory.
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard pipeline == nil else { return }
        if let loading { return try await loading.value }
        let task = Task { try await performLoad(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        if WhisperKitTranscriber.isModelDownloaded(in: downloadBase) {
            do {
                pipeline = try await makePipeline(folder: WhisperKitTranscriber.modelFolder(in: downloadBase))
                return
            } catch {
                // An interrupted download leaves partial folders behind: let the hub complete them.
                Logging.debug("Local model failed to load, downloading again: \(error)")
            }
        }
        let folder = try await WhisperKit.download(variant: modelName, downloadBase: downloadBase) {
            progress($0.fractionCompleted)
        }
        pipeline = try await makePipeline(folder: folder)
    }

    private func makePipeline(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: modelName, downloadBase: downloadBase, modelFolder: folder.path,
            verbose: false, prewarm: true, load: true, download: false
        )
        return try await WhisperKit(config)
    }

    func transcribe(chunk samples: [Float], vocabulary: [String]) async throws -> String {
        try await load()
        guard let pipeline else { return "" }

        var options = DecodingOptions(
            task: .transcribe,
            language: "fr",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        if let tokenizer = pipeline.tokenizer, !vocabulary.isEmpty {
            // Whisper uses the prompt as preceding context: listing the jargon
            // biases decoding towards its expected spelling. Each prompt token
            // costs one decoder pass (~30 ms on an M1 Pro): the default
            // vocabulary is 68 tokens, about 2 s per dictation.
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        // WhisperKit checks the task's cancellation at every decoder step, but
        // runs the progress callback on a detached task: give it its own flag.
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options) { _ in !stop.isSet }
            // An early stop returns a partial result: never hand that out.
            try Task.checkCancellation()
            return results.map(\.text).joined(separator: " ")
        } onCancel: {
            stop.set()
        }
    }
}

nonisolated final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
