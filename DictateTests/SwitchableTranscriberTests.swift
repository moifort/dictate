import Foundation
import Testing
@testable import Dictate

@MainActor
struct SwitchableTranscriberTests {
    private let parakeet = FakeModelTranscriber(result: "parakeet")

    private func makeTranscriber() -> SwitchableTranscriber {
        SwitchableTranscriber(engine: .parakeet, parakeet: parakeet)
    }

    @Test func routesToTheSelectedEngine() async throws {
        let text = try await makeTranscriber().transcribe(samples: [0], language: "fr")
        #expect(text == "parakeet")
        #expect(parakeet.callCount == 1)
        #expect(parakeet.receivedLanguage == "fr")
    }

    @Test func stateFollowsTheActiveEngine() {
        parakeet.state = .downloading(0.4)
        #expect(makeTranscriber().state == .downloading(0.4))
    }

    @Test func selectingTheActiveEngineDoesNothing() async {
        let transcriber = makeTranscriber()
        transcriber.select(.parakeet)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(parakeet.unloadCount == 0)
        #expect(parakeet.loadCount == 0)
    }
}

private final class FakeModelTranscriber: ModelTranscriber {
    var state: TranscriberState = .notLoaded
    var isModelDownloaded = true
    var modelFolder = URL.temporaryDirectory
    private let result: String
    private(set) var callCount = 0
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var receivedLanguage: String?

    init(result: String) { self.result = result }

    func load() async { loadCount += 1 }
    func unload() async { unloadCount += 1 }

    func transcribe(samples: [Float], language: String) async throws -> String {
        callCount += 1
        receivedLanguage = language
        return result
    }
}
