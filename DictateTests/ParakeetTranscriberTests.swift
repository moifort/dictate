import Foundation
import Testing
@testable import Dictate

/// Needs the Parakeet model already downloaded by the app; skipped otherwise.
@MainActor
struct ParakeetTranscriberTests {
    nonisolated static var modelAvailable: Bool { ParakeetTranscriber.isModelDownloaded() }

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
        let text = try await transcriber.transcribe(samples: samples, vocabulary: [], language: "fr")
        print("Parakeet: \(ContinuousClock.now - start) for \(samples.count / AudioAnalysis.sampleRate) s of audio: \(text)")
        let lowered = text.lowercased()
        #expect(lowered.contains("branche"), "got: \(text)")
        #expect(lowered.contains("vérifier"), "got: \(text)")
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func unloadFreesTheModelAndTheNextDictationReloadsIt() async throws {
        let transcriber = ParakeetTranscriber()
        await transcriber.load()
        await transcriber.unload()
        #expect(transcriber.state == .notLoaded)
        let text = try await transcriber.transcribe(samples: try synthesize("Bonjour à tous"), vocabulary: [], language: "fr")
        #expect(transcriber.state == .ready)
        #expect(text.lowercased().contains("bonjour"), "got: \(text)")
    }
}
