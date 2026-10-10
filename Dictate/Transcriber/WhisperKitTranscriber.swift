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

    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String {
        if state != .ready { await load() }
        return try await engine.transcribe(samples: samples, vocabulary: vocabulary)
    }
}

/// Owns the non-Sendable WhisperKit pipeline away from the main actor.
actor WhisperEngine {
    private let modelName: String
    private let downloadBase: URL
    private var pipeline: WhisperKit?

    init(modelName: String, downloadBase: URL) {
        self.modelName = modelName
        self.downloadBase = downloadBase
    }

    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard pipeline == nil else { return }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let folder: URL
        if WhisperKitTranscriber.isModelDownloaded(in: downloadBase) {
            folder = WhisperKitTranscriber.modelFolder(in: downloadBase)
        } else {
            folder = try await WhisperKit.download(variant: modelName, downloadBase: downloadBase) {
                progress($0.fractionCompleted)
            }
        }
        let config = WhisperKitConfig(
            model: modelName, downloadBase: downloadBase, modelFolder: folder.path,
            verbose: false, prewarm: true, load: true, download: false
        )
        pipeline = try await WhisperKit(config)
    }

    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String {
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
            // biases decoding towards its expected spelling.
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
