import Foundation
import Observation
import DictateKit

/// The speech-to-text model run on this Mac. Parakeet is the only one left;
/// the type stays because every statistic and corpus entry records it, and
/// names it on screen.
nonisolated enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Parakeet TDT Ultra: 25 European languages, no vocabulary.
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        }
    }

    /// Approximate size of the one-time model download, in MB: the one
    /// figure every screen shows. Parakeet TDT Ultra measured 632 MB on disk.
    var downloadSize: Int {
        switch self {
        case .parakeet: 630
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

/// Where the models are downloaded, and what they take on disk.
nonisolated enum ModelStorage {
    static var defaultDirectory: URL {
        AppPaths().models
    }

    /// Whisper was offered until it was removed (2026-10-14): its model,
    /// about 630 MB, stays behind on the Macs that downloaded it. Kept at every
    /// launch, a single existence check, for those who update from an older
    /// version later. `models` is WhisperKit's
    /// download cache, model and tokenizer; Parakeet lives next to it.
    static func removeWhisperModel(in base: URL = defaultDirectory) {
        let folder = base.appending(path: "models", directoryHint: .isDirectory)
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
