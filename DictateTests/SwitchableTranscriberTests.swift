import Foundation
import Testing
@testable import Dictate

@MainActor
struct SwitchableTranscriberTests {
    private let whisper = FakeModelTranscriber(result: "whisper")
    private let parakeet = FakeModelTranscriber(result: "parakeet")

    private func makeTranscriber(_ engine: TranscriptionEngine) -> SwitchableTranscriber {
        SwitchableTranscriber(engine: engine, whisper: whisper, parakeet: parakeet)
    }

    @Test func routesToTheSelectedEngine() async throws {
        let transcriber = makeTranscriber(.parakeet)
        let text = try await transcriber.transcribe(samples: [0], vocabulary: [], language: "fr")
        #expect(text == "parakeet")
        #expect(whisper.callCount == 0)
    }

    @Test func onlyWhisperReceivesTheVocabulary() async throws {
        _ = try await makeTranscriber(.whisper).transcribe(samples: [0], vocabulary: ["push"], language: "fr")
        #expect(whisper.receivedVocabulary == ["push"])

        _ = try await makeTranscriber(.parakeet).transcribe(samples: [0], vocabulary: ["push"], language: "fr")
        #expect(parakeet.receivedVocabulary == [])
    }

    @Test func stateFollowsTheActiveEngine() {
        whisper.state = .ready
        parakeet.state = .downloading(0.4)
        let transcriber = makeTranscriber(.whisper)
        #expect(transcriber.state == .ready)
        transcriber.select(.parakeet)
        #expect(transcriber.engine == .parakeet)
        #expect(transcriber.state == .downloading(0.4))
    }

    @Test func switchingUnloadsThePreviousEngineAndLoadsTheNewOne() async {
        let transcriber = makeTranscriber(.whisper)
        transcriber.select(.parakeet)
        await waitUntil { whisper.unloadCount == 1 && parakeet.loadCount == 1 }
        #expect(whisper.unloadCount == 1)
        #expect(parakeet.loadCount == 1)
        #expect(parakeet.unloadCount == 0)
    }

    @Test func selectingTheActiveEngineDoesNothing() async {
        let transcriber = makeTranscriber(.whisper)
        transcriber.select(.whisper)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(whisper.unloadCount == 0)
        #expect(whisper.loadCount == 0)
    }

    @Test func parakeetOnlyCoversEuropeanLanguages() {
        #expect(TranscriptionEngine.parakeet.supports(language: "fr"))
        #expect(!TranscriptionEngine.parakeet.supports(language: "ja"))
        #expect(TranscriptionEngine.whisper.supports(language: "ja"))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeModelTranscriber: ModelTranscriber {
    var state: TranscriberState = .notLoaded
    var isModelDownloaded = true
    private let result: String
    private(set) var callCount = 0
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var receivedVocabulary: [String]?

    init(result: String) { self.result = result }

    func load() async { loadCount += 1 }
    func unload() async { unloadCount += 1 }

    func transcribe(samples: [Float], vocabulary: [String], language: String) async throws -> String {
        callCount += 1
        receivedVocabulary = vocabulary
        return result
    }
}
