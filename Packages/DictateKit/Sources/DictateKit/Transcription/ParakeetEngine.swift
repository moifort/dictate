import FluidAudio
import Foundation
import Synchronization

/// Owns the FluidAudio manager away from the main actor.
public actor ParakeetEngine {
    /// Parakeet TDT Ultra.
    public nonisolated static let modelVersion = AsrModelVersion.ultra

    private let folder: URL
    private var manager: AsrManager?
    private let loads = SharedLoad()

    public init(folder: URL) {
        self.folder = folder
    }

    /// Concurrent callers share one load: a dictation during startup must not
    /// trigger a second download or a second copy of the model in memory.
    public func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await loads.run(isLoaded: manager != nil) { try await self.performLoad(progress: progress) }
    }

    private func performLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        let version = Self.modelVersion
        // Downloading separately keeps the compile progress of an already
        // downloaded model from showing up as a download.
        if !AsrModels.modelsExist(at: folder, version: version) {
            let tracker = DownloadTracker(report: progress)
            try await AsrModels.download(to: folder, version: version) { tracker.update($0) }
            progress(1)
        }
        let models = try await AsrModels.load(from: folder, version: version)
        let manager = AsrManager()
        try await manager.loadModels(Self.keepingUnknownTokens(models))
        self.manager = manager
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// The token timings come along for the vocabulary rescoring.
    public func transcribe(samples: [Float], language: String) async throws -> (Transcription, [TokenTiming]) {
        try await load()
        guard let manager else { return (Transcription(text: ""), []) }
        // A fresh decoder state per dictation: they are independent utterances.
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // The language only filters out tokens from another alphabet.
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: Language(rawValue: language))
        let (text, timings) = Self.quotingUnknownTokens(
            text: UnknownTokens.restored(result.text),
            timings: (result.tokenTimings ?? []).map(Self.restoringUnknownToken)
        )
        let tokens = timings.map { (piece: $0.token, confidence: $0.confidence) }
        return (Transcription(text: text, words: Transcription.words(fromTokens: tokens)), timings)
    }

    private static func keepingUnknownTokens(_ models: AsrModels) -> AsrModels {
        AsrModels(
            encoder: models.encoder, preprocessor: models.preprocessor, decoder: models.decoder, joint: models.joint,
            ctcHead: models.ctcHead, encoderLadder: models.encoderLadder, configuration: models.configuration,
            vocabulary: UnknownTokens.keepingToken(in: models.vocabulary), version: models.version
        )
    }

    private static func restoringUnknownToken(_ timing: TokenTiming) -> TokenTiming {
        TokenTiming(
            token: UnknownTokens.restored(timing.token), tokenId: timing.tokenId, startTime: timing.startTime,
            endTime: timing.endTime, confidence: timing.confidence
        )
    }

    /// Parakeet writes `<unk>` for the quotation marks its vocabulary lacks:
    /// pairs become guillemets here, the rest is left for Claude. The timings
    /// carry the guillemets too, so the vocabulary rescoring rebuilds the same
    /// words.
    private static func quotingUnknownTokens(text: String, timings: [TokenTiming]) -> (String, [TokenTiming]) {
        let pieces = timings.map(\.token)
        guard UnknownTokens.containsUnknown(pieces) else { return (text, timings) }
        let quoted = UnknownTokens.quoted(pieces)
        let quotedTimings = zip(timings, quoted).map { timing, piece in
            TokenTiming(
                token: piece, tokenId: timing.tokenId, startTime: timing.startTime, endTime: timing.endTime,
                confidence: timing.confidence
            )
        }
        return (UnknownTokens.text(fromPieces: quoted), quotedTimings)
    }
}

/// FluidAudio fetches the whole repository in a first pass reported from 0 to
/// 0.5, then compiles each model in turn, each time from 0.5 to 1: only that
/// first pass is the download, the rest is the model being prepared.
public nonisolated final class DownloadTracker: Sendable {
    private let report: @Sendable (Double) -> Void
    private let downloaded = Mutex(false)

    public init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    public func update(_ progress: DownloadProgress) {
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
