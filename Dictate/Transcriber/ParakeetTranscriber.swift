import FluidAudio
import Foundation
import Observation
import Synchronization
import DictateKit

/// Local transcription with Parakeet TDT Ultra through FluidAudio, on the
/// Neural Engine. It takes no vocabulary prompt: the jargon is left to
/// Claude, unless the experimental vocabulary boosting rescores its output.
@Observable
final class ParakeetTranscriber: ModelTranscriber {
    nonisolated static let modelVersion = ParakeetEngine.modelVersion

    private(set) var state: TranscriberState = .notLoaded
    @ObservationIgnored let modelFolder: URL
    @ObservationIgnored private let engine: ParakeetEngine
    @ObservationIgnored private let booster: VocabularyBooster?
    /// The terms to search the audio for; empty when boosting is off.
    @ObservationIgnored private let boostedVocabulary: () -> [String]

    init(
        modelDirectory: URL = ModelStorage.defaultDirectory,
        booster: VocabularyBooster? = nil,
        boostedVocabulary: @escaping () -> [String] = { [] }
    ) {
        modelFolder = Self.modelFolder(in: modelDirectory)
        engine = ParakeetEngine(folder: modelFolder)
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
        let (transcription, tokenTimings) = try await engine.transcribe(samples: samples, language: language)
        let vocabulary = boostedVocabulary()
        guard let booster, !vocabulary.isEmpty else { return transcription }
        return await booster.boost(transcription, tokenTimings: tokenTimings, samples: samples, vocabulary: vocabulary)
    }
}
