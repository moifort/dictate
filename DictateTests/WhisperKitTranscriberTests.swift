import Foundation
import Testing
@testable import Dictate

/// Needs the Whisper model already downloaded by the app; skipped otherwise.
@MainActor
struct WhisperKitTranscriberTests {
    nonisolated static var modelAvailable: Bool { WhisperKitTranscriber.isModelDownloaded() }

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
    func transcribesFrenchWithDevJargon() async throws {
        let samples = try synthesize("Je vais faire un push sur la branche main, puis vérifier la CI.")
        #expect(samples.count > 16_000)

        let transcriber = WhisperKitTranscriber()
        let text = try await transcriber.transcribe(samples: samples, vocabulary: ["push", "main", "CI"])
        let lowered = text.lowercased()
        #expect(lowered.contains("push"), "got: \(text)")
        // The synthetic voice is too rough to assert exact French spelling; the jargon is what matters.
        #expect(lowered.contains("main"), "got: \(text)")
    }

    @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(5)))
    func liveTranscriptionJoinsChunksDecodedAroundPauses() async throws {
        let first = try synthesize("Je vais faire un push sur la branche main, puis vérifier que la CI passe correctement sur GitHub.")
        let second = try synthesize("Ensuite je lance la CI.")
        let all = first + [Float](repeating: 0, count: 16_000)

        let transcriber = WhisperKitTranscriber()
        await transcriber.load()
        let live = transcriber.startLive(vocabulary: ["push", "main", "CI"])
        // Feed the audio the way the recorder does, in small chunks.
        for start in stride(from: 0, to: all.count, by: 4_096) {
            live.append(Array(all[start..<min(start + 4_096, all.count)]))
        }
        // Long enough for the first sentence to be decoded while "recording" goes on.
        try await Task.sleep(for: .seconds(3))
        live.append(second)
        let text = try await live.finish().lowercased()
        #expect(text.contains("push"), "got: \(text)")
        #expect(text.contains("ensuite"), "got: \(text)")
    }

    @Test func resamplesSynthesizedSpeechTo16kHz() throws {
        let samples = try synthesize("Bonjour")
        #expect(samples.count > 4_000)
        #expect(!AudioAnalysis.isSilent(samples))
    }
}
