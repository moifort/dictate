import Foundation
import Observation

/// The speech-to-text model run on this Mac, in the order the settings offer them.
nonisolated enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Parakeet TDT Ultra: the default, several times faster, 25 European languages, no vocabulary.
    case parakeet
    /// Whisper large-v3 turbo: every language, takes the vocabulary as a prompt.
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        }
    }

    /// Approximate size of the one-time model download, in MB.
    var downloadSize: Int {
        switch self {
        case .whisper: 630
        case .parakeet: 610
        }
    }

    /// The checkpoint behind each engine, as its authors name it.
    var weightsName: String {
        switch self {
        case .whisper: "Whisper large-v3 turbo"
        case .parakeet: "Parakeet TDT 0.6B v3 Ultra"
        }
    }

    /// Number of parameters in the checkpoint, in millions.
    var parameterCount: Int {
        switch self {
        case .whisper: 809
        case .parakeet: 600
        }
    }

    /// Only Whisper biases its decoding with the vocabulary.
    var acceptsVocabulary: Bool { self == .whisper }

    func supports(language code: String) -> Bool {
        switch self {
        case .whisper: DictationLanguage.supportedCodes.contains(code)
        case .parakeet: Self.parakeetLanguages.contains(code)
        }
    }

    /// The 25 European languages Parakeet TDT v3 and its Ultra post-training cover.
    static let parakeetLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]
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
/// engine's model in memory: both together would hold well over 1 GB.
@Observable
final class SwitchableTranscriber: Transcriber {
    private(set) var engine: TranscriptionEngine
    @ObservationIgnored private let whisper: any ModelTranscriber
    @ObservationIgnored private let parakeet: any ModelTranscriber

    init(
        engine: TranscriptionEngine,
        whisper: any ModelTranscriber = WhisperKitTranscriber(),
        parakeet: any ModelTranscriber = ParakeetTranscriber()
    ) {
        self.engine = engine
        self.whisper = whisper
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
    /// first-time Parakeet download must not wait for Whisper to be freed.
    func select(_ engine: TranscriptionEngine) {
        guard engine != self.engine else { return }
        let previous = active
        self.engine = engine
        let next = active
        Task { await previous.unload() }
        Task { await next.load() }
    }

    func transcribe(samples: [Float], vocabulary: [String], language: String) async throws -> String {
        try await active.transcribe(
            samples: samples, vocabulary: engine.acceptsVocabulary ? vocabulary : [], language: language
        )
    }

    private func transcriber(for engine: TranscriptionEngine) -> any ModelTranscriber {
        switch engine {
        case .whisper: whisper
        case .parakeet: parakeet
        }
    }
}

/// What a downloaded model takes on disk.
nonisolated enum ModelStorage {
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
