import Foundation
import Observation

/// The speech-to-text model run on this Mac.
nonisolated enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Parakeet TDT Ultra: 25 European languages, no vocabulary.
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        }
    }

    /// Approximate size of the one-time model download, in MB.
    var downloadSize: Int {
        switch self {
        case .parakeet: 610
        }
    }

    /// The checkpoint behind each engine, as its authors name it.
    var weightsName: String {
        switch self {
        case .parakeet: "Parakeet TDT 0.6B v3 Ultra"
        }
    }

    /// Number of parameters in the checkpoint, in millions.
    var parameterCount: Int {
        switch self {
        case .parakeet: 600
        }
    }
}

/// Where a transcription model stands, for every engine.
enum TranscriberState: Equatable {
    case notLoaded
    /// First use only: fraction of the model downloaded.
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }
}

/// A transcriber backed by a model that is downloaded once, then kept in memory.
@MainActor protocol ModelTranscriber: Transcriber {
    var state: TranscriberState { get }
    /// True once every file is on disk, so loading needs no network.
    var isModelDownloaded: Bool { get }
    /// Where the model's files live once downloaded.
    var modelFolder: URL { get }
    /// Downloads the model on first use, then loads it in memory.
    func load() async
    /// Frees the model's memory; the next transcription loads it again.
    func unload() async
}

/// Routes dictations to the engine picked in the settings and keeps only that
/// engine's model in memory: two models together would hold well over 1 GB.
@Observable
final class SwitchableTranscriber: Transcriber {
    private(set) var engine: TranscriptionEngine
    @ObservationIgnored private let parakeet: any ModelTranscriber

    init(engine: TranscriptionEngine, parakeet: any ModelTranscriber = ParakeetTranscriber()) {
        self.engine = engine
        self.parakeet = parakeet
    }

    var active: any ModelTranscriber { transcriber(for: engine) }
    var state: TranscriberState { active.state }
    var isModelDownloaded: Bool { active.isModelDownloaded }
    var modelFolder: URL { active.modelFolder }

    func load() async {
        await active.load()
    }

    /// Unloads the previous engine and loads the new one in parallel: a
    /// first-time download must not wait for the previous model to be freed.
    func select(_ engine: TranscriptionEngine) {
        guard engine != self.engine else { return }
        let previous = active
        self.engine = engine
        let next = active
        Task { await previous.unload() }
        Task { await next.load() }
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        try await active.transcribe(samples: samples, language: language)
    }

    private func transcriber(for engine: TranscriptionEngine) -> any ModelTranscriber {
        switch engine {
        case .parakeet: parakeet
        }
    }
}

/// Where the models are downloaded, and what they take on disk.
nonisolated enum ModelStorage {
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Dictate/Models", directoryHint: .isDirectory)
    }

    /// Whisper was offered until it was removed: its model, about 630 MB,
    /// stays behind on the Macs that downloaded it.
    static func removeWhisperModel(in base: URL = defaultDirectory) {
        let folder = base.appending(path: "models/argmaxinc", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            ErrorReporter.capture(error, "whisper model could not be removed", category: "transcriber", level: .warning)
        }
    }

    /// Bytes allocated by every file under `folder`, or nil if it does not exist.
    /// Walks the whole tree: call it off the main actor.
    static func diskUsage(of folder: URL) -> Int64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard FileManager.default.fileExists(atPath: folder.path),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
