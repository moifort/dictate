import Foundation
import Testing
@testable import Dictate

/// Needs the Parakeet model already downloaded by the app; skipped otherwise.
@MainActor
struct ParakeetTranscriberTests {
    nonisolated static var modelAvailable: Bool { ParakeetTranscriber.isModelDownloaded() }

    static let unknownTokenEntries: [(audio: URL, language: String)] = {
        let corpora = URL.applicationSupportDirectory.appending(path: "Dictate/Corpus", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: corpora, includingPropertiesForKeys: nil)) ?? []
        let entries = folders.flatMap { folder in
            EvaluationCorpus(folder: folder).entries
                .filter { $0.transcript.contains(UnknownTokens.token) }
                .map { (audio: folder.appending(path: $0.audioFile), language: $0.language) }
        }
        return Array(entries.prefix(20))
    }()

    private func synthesize(_ sentence: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Thomas", "-o", url.path, sentence]
        try say.run()
        say.waitUntilExit()
        return try AudioResampler.samples(fromFile: url)
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func transcribesFrench() async throws {
        let samples = try synthesize("Je vais faire un push sur la branche main, puis vérifier la CI.")
        let transcriber = ParakeetTranscriber()
        await transcriber.load()
        #expect(transcriber.state == .ready)

        let start = ContinuousClock.now
        let text = try await transcriber.transcribe(samples: samples, language: "fr")
        print("Parakeet: \(ContinuousClock.now - start) for \(samples.count / AudioAnalysis.sampleRate) s of audio: \(text)")
        let lowered = text.lowercased()
        #expect(lowered.contains("branche"), "got: \(text)")
        #expect(lowered.contains("vérifier"), "got: \(text)")
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func reportsAConfidenceForEveryWordOfTheText() async throws {
        let samples = try synthesize("Je vais déployer sur Kubernetes, puis faire un rebase.")
        let transcription = try await ParakeetTranscriber().transcription(samples: samples, language: "fr")
        print("Parakeet confidences: " + transcription.words.map { "\($0.text) \($0.confidence)" }.joined(separator: ", "))
        #expect(transcription.words.map(\.text) == transcription.text.split(separator: " ").map(String.init))
        #expect(transcription.words.allSatisfy { (0...1).contains($0.confidence) })
    }

    /// Real dictations of this Mac's corpus: no synthesized sentence makes
    /// the decoder emit `<unk>`. Says nothing of what was dictated.
    @Test(.enabled(if: modelAvailable), .enabled { await !unknownTokenEntries.isEmpty }, .timeLimit(.minutes(5)))
    func keepsTheUnknownTokensOfTheDecoder() async throws {
        let transcriber = ParakeetTranscriber()
        var kept = 0
        for (audio, language) in Self.unknownTokenEntries {
            let text = try await transcriber.transcribe(samples: try AudioResampler.samples(fromFile: audio), language: language)
            if text.contains(UnknownTokens.token) || text.contains("«") { kept += 1 }
        }
        print("Parakeet unknown tokens: kept in \(kept) of \(Self.unknownTokenEntries.count) dictations")
        #expect(kept > 0)
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func unloadFreesTheModelAndTheNextDictationReloadsIt() async throws {
        let transcriber = ParakeetTranscriber()
        await transcriber.load()
        await transcriber.unload()
        #expect(transcriber.state == .notLoaded)
        let text = try await transcriber.transcribe(samples: try synthesize("Bonjour à tous"), language: "fr")
        #expect(transcriber.state == .ready)
        #expect(text.lowercased().contains("bonjour"), "got: \(text)")
    }
}
