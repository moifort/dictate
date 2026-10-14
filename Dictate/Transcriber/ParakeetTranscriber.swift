import FluidAudio
import Foundation
import Observation
import Synchronization

/// Local transcription with Parakeet TDT Ultra through FluidAudio, on the
/// Neural Engine. It takes no vocabulary prompt: the jargon is left to
/// Claude.
@Observable
final class ParakeetTranscriber: ModelTranscriber {
    nonisolated static let modelVersion = AsrModelVersion.ultra

    private(set) var state: TranscriberState = .notLoaded
    @ObservationIgnored let modelFolder: URL
    @ObservationIgnored private let engine: ParakeetEngine

    init(modelDirectory: URL = ModelStorage.defaultDirectory) {
        modelFolder = Self.modelFolder(in: modelDirectory)
        engine = ParakeetEngine(folder: modelFolder)
    }

    /// FluidAudio's cache folder for this model: it resolves the files from
    /// the parent directory and this name, whatever folder it is given.
    nonisolated static func modelFolder(in base: URL) -> URL {
        base.appending(path: "parakeet-ultra", directoryHint: .isDirectory)
    }

    nonisolated static func isModelDownloaded(in base: URL = ModelStorage.defaultDirectory) -> Bool {
        AsrModels.modelsExist(at: modelFolder(in: base), version: modelVersion)
    }

    var isModelDownloaded: Bool {
        AsrModels.modelsExist(at: modelFolder, version: Self.modelVersion)
    }

    func load() async {
        guard !state.isBusy, state != .ready else { return }
        state = .loading
        do {
            try await engine.load { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.state.isBusy else { return }
                    // The download is over: what remains is compiling the model for this Mac.
                    self.state = fraction < 1 ? .downloading(fraction) : .loading
                }
            }
            state = .ready
            ErrorReporter.breadcrumb("parakeet model ready", category: "transcriber")
        } catch {
            ErrorReporter.capture(error, "parakeet model failed to load", category: "transcriber")
            state = .failed(error.localizedDescription)
        }
    }

    /// Skipped while the model is downloading or loading: that load will
    /// finish anyway, and the model is then freed at the next launch.
    func unload() async {
        guard state == .ready else { return }
        await engine.unload()
        state = .notLoaded
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcription(samples: samples, language: language).text
    }

    func transcription(samples: [Float], language: String) async throws -> Transcription {
        if state != .ready { await load() }
        return try await engine.transcribe(samples: samples, language: language)
    }
}

/// Owns the FluidAudio manager away from the main actor.
actor ParakeetEngine {
    private let folder: URL
    private var manager: AsrManager?
    private var loading: Task<Void, Error>?

    init(folder: URL) {
        self.folder = folder
    }

    /// Concurrent callers share one load: a dictation during startup must not
    /// trigger a second download or a second copy of the model in memory.
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard manager == nil else { return }
        if let loading { return try await loading.value }
        let task = Task { try await performLoad(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        let version = ParakeetTranscriber.modelVersion
        // Downloading separately keeps the compile progress of an already
        // downloaded model from showing up as a download.
        if !AsrModels.modelsExist(at: folder, version: version) {
            let tracker = DownloadTracker(report: progress)
            try await AsrModels.download(to: folder, version: version) { tracker.update($0) }
            progress(1)
        }
        let models = try await AsrModels.load(from: folder, version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    func transcribe(samples: [Float], language: String) async throws -> Transcription {
        try await load()
        guard let manager else { return Transcription(text: "") }
        // A fresh decoder state per dictation: they are independent utterances.
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // The language only filters out tokens from another alphabet.
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: Language(rawValue: language))
        let tokens = (result.tokenTimings ?? []).map { (piece: $0.token, confidence: $0.confidence) }
        return Transcription(text: result.text, words: Transcription.words(fromTokens: tokens))
    }
}

/// FluidAudio fetches the whole repository in a first pass reported from 0 to
/// 0.5, then compiles each model in turn, each time from 0.5 to 1: only that
/// first pass is the download, the rest is the model being prepared.
nonisolated final class DownloadTracker: Sendable {
    private let report: @Sendable (Double) -> Void
    private let downloaded = Mutex(false)

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func update(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing:
            return
        case .downloading:
            guard !downloaded.withLock({ $0 }) else { return }
            // Stays below 1: 1 means the download is over.
            report(min(progress.fractionCompleted * 2, 0.99))
        case .compiling:
            let first = downloaded.withLock { done in
                defer { done = true }
                return !done
            }
            if first { report(1) }
        }
    }
}
