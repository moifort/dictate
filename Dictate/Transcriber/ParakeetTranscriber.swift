import DictateKit
import FluidAudio
import Foundation
import Observation
import Synchronization

/// Local transcription with Parakeet TDT Ultra through FluidAudio, on the
/// Neural Engine. It takes no vocabulary prompt: the jargon is left to
/// the reviewer, unless the experimental vocabulary boosting rescores its output.
@Observable
final class ParakeetTranscriber: Transcriber {
    nonisolated static let modelVersion = ParakeetEngine.modelVersion

    @ObservationIgnored private let loader = ModelLoader(name: "parakeet")
    var state: TranscriberState { loader.state }
    @ObservationIgnored let modelFolder: URL
    /// What the statistics and the screens call this model.
    @ObservationIgnored let engine = TranscriptionEngine.parakeet
    @ObservationIgnored private let parakeet: ParakeetEngine
    @ObservationIgnored private let booster: VocabularyBooster?
    /// The terms to search the audio for; empty when boosting is off.
    @ObservationIgnored private let boostedVocabulary: () -> [String]

    init(
        modelDirectory: URL = ModelStorage.defaultDirectory,
        booster: VocabularyBooster? = nil,
        boostedVocabulary: @escaping () -> [String] = { [] }
    ) {
        modelFolder = Self.modelFolder(in: modelDirectory)
        parakeet = ParakeetEngine(folder: modelFolder)
        self.booster = booster
        self.boostedVocabulary = boostedVocabulary
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
        await loader.load { [parakeet] progress in try await parakeet.load(progress: progress) }
    }

    /// Skipped while the model is downloading or loading: that load will
    /// finish anyway, and the model is then freed at the next launch.
    func unload() async {
        guard state == .ready else { return }
        await parakeet.unload()
        loader.unloaded()
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcription(samples: samples, language: language).text
    }

    func transcription(samples: [Float], language: String) async throws -> Transcription {
        if state != .ready { await load() }
        let (transcription, tokenTimings) = try await parakeet.transcribe(samples: samples, language: language)
        let vocabulary = boostedVocabulary()
        guard let booster, !vocabulary.isEmpty else { return transcription }
        return await booster.boost(transcription, tokenTimings: tokenTimings, samples: samples, vocabulary: vocabulary)
    }
}
