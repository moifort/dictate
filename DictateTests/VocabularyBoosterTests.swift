import FluidAudio
import Foundation
import Testing
@testable import Dictate

@MainActor
struct VocabularyBoosterTests {
    private let transcription = Transcription(
        text: "Je déploie sur cube air net, puis je pousse.",
        words: [
            .init(text: "Je", confidence: 0.99),
            .init(text: "déploie", confidence: 0.95),
            .init(text: "sur", confidence: 0.98),
            .init(text: "cube", confidence: 0.4),
            .init(text: "air", confidence: 0.3),
            .init(text: "net,", confidence: 0.6),
            .init(text: "puis", confidence: 0.97),
            .init(text: "je", confidence: 0.99),
            .init(text: "pousse.", confidence: 0.92),
        ]
    )
    private let timings = [TokenTiming(token: "▁Je", tokenId: 1, startTime: 0, endTime: 0.1, confidence: 0.99)]

    private func booster(_ engine: FakeRescorer) async -> VocabularyBooster {
        let booster = VocabularyBooster(engine: engine, modelFolder: URL(filePath: "/tmp/none"))
        await booster.load()
        return booster
    }

    @Test func replacedWordsAreConfidentAndKeepTheirPunctuation() {
        // The rescorer keeps the punctuation of the words it leaves alone.
        let boosted = VocabularyBoost.apply("Je déploie sur Kubernetes puis je pousse.", to: transcription)
        #expect(boosted.text == "Je déploie sur Kubernetes, puis je pousse.")
        #expect(boosted.words.map(\.text) == ["Je", "déploie", "sur", "Kubernetes,", "puis", "je", "pousse."])
        #expect(boosted.words[3].confidence == VocabularyBoost.replacedConfidence)
        #expect(boosted.words[3].confidence >= DoubtfulWords.threshold)
        #expect(boosted.words[0].confidence == 0.99)
        #expect(boosted.words[6].confidence == 0.92)
    }

    @Test func aMultiWordTermReplacesASingleWord() {
        let input = Transcription(
            text: "Lance cloudcode maintenant.",
            words: [.init(text: "Lance", confidence: 0.9), .init(text: "cloudcode", confidence: 0.2), .init(text: "maintenant.", confidence: 0.9)]
        )
        let boosted = VocabularyBoost.apply("Lance Claude Code maintenant.", to: input)
        #expect(boosted.text == "Lance Claude Code maintenant.")
        #expect(boosted.words.map(\.confidence) == [0.9, 1, 1, 0.9])
        #expect(VocabularyBoost.replacedWordCount(from: input, to: boosted) == 2)
    }

    @Test func aTermNeverSwallowsTheWordBeforeIt() {
        // What FluidAudio does with "Argo CD" in the vocabulary.
        let words = ["We", "deploy", "with", "Argo", "CD,", "then", "check."]
        let input = Transcription(
            text: words.joined(separator: " "),
            words: words.map { .init(text: $0, confidence: 0.9) }
        )
        let boosted = VocabularyBoost.apply("We deploy Argo CD then check.", to: input)
        #expect(boosted.text == "We deploy with Argo CD, then check.")
        #expect(boosted.words[2] == .init(text: "with", confidence: 0.9))
    }

    @Test func leadingPunctuationIsKept() {
        let input = Transcription(text: "(cube air)", words: [.init(text: "(cube", confidence: 0.3), .init(text: "air)", confidence: 0.3)])
        #expect(VocabularyBoost.apply("Kubernetes", to: input).text == "(Kubernetes)")
    }

    @Test func boostingRecordsTheRescoredTranscript() async {
        let engine = FakeRescorer(result: .success("Je déploie sur Kubernetes puis je pousse."))
        let booster = await booster(engine)
        let boosted = await booster.boost(transcription, tokenTimings: timings, samples: [0, 0.1], vocabulary: ["Kubernetes"])
        #expect(boosted.text == "Je déploie sur Kubernetes, puis je pousse.")
        #expect(boosted.vocabularyBoosted)
        #expect(await engine.vocabularies == [["Kubernetes"]])
    }

    @Test func nothingReplacedStillCountsAsBoosted() async {
        let booster = await booster(FakeRescorer(result: .success(nil)))
        let boosted = await booster.boost(transcription, tokenTimings: timings, samples: [0], vocabulary: ["Kubernetes"])
        #expect(boosted.text == transcription.text)
        #expect(boosted.words == transcription.words)
        #expect(boosted.vocabularyBoosted)
    }

    @Test func aFailureFallsBackToThePlainTranscript() async {
        let booster = await booster(FakeRescorer(result: .failure(FakeError())))
        let boosted = await booster.boost(transcription, tokenTimings: timings, samples: [0], vocabulary: ["Kubernetes"])
        #expect(boosted == transcription)
        #expect(!boosted.vocabularyBoosted)
    }

    @Test func anEmptyVocabularySkipsTheModel() async {
        let engine = FakeRescorer(result: .success("Kubernetes"))
        let booster = await booster(engine)
        let boosted = await booster.boost(transcription, tokenTimings: timings, samples: [0], vocabulary: [])
        #expect(boosted == transcription)
        #expect(await engine.vocabularies.isEmpty)
    }

    @Test func aDictationDoesNotWaitForTheModel() async {
        let engine = FakeRescorer(result: .success("Kubernetes"))
        let booster = VocabularyBooster(engine: engine, modelFolder: URL(filePath: "/tmp/none"))
        let boosted = await booster.boost(transcription, tokenTimings: timings, samples: [0], vocabulary: ["Kubernetes"])
        #expect(boosted == transcription)
        #expect(await engine.vocabularies.isEmpty)
    }

    @Test func aFailedLoadIsReportedAndUnloadResetsIt() async {
        let engine = FakeRescorer(result: .success(nil), loadError: FakeError())
        let booster = VocabularyBooster(engine: engine, modelFolder: URL(filePath: "/tmp/none"))
        await booster.load()
        guard case .failed = booster.state else {
            Issue.record("expected a failure, got \(booster.state)")
            return
        }
        await booster.unload()
        #expect(booster.state == .notLoaded)
    }

    @Test func modelLivesNextToParakeet() {
        let base = URL(filePath: "/tmp/Models", directoryHint: .isDirectory)
        #expect(VocabularyBooster.modelFolder(in: base).deletingLastPathComponent().path == base.path)
        #expect(VocabularyBooster.modelFolder(in: base).lastPathComponent == "parakeet-ctc-110m-coreml")
    }
}

private struct FakeError: Error {}

private actor FakeRescorer: VocabularyRescoring {
    let result: Result<String?, FakeError>
    let loadError: FakeError?
    private(set) var vocabularies: [[String]] = []

    init(result: Result<String?, FakeError>, loadError: FakeError? = nil) {
        self.result = result
        self.loadError = loadError
    }

    nonisolated var isModelDownloaded: Bool { true }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if let loadError { throw loadError }
    }

    func unload() async {}

    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float], vocabulary: [String]) async throws -> String? {
        vocabularies.append(vocabulary)
        return try result.get()
    }
}

/// Needs the Parakeet and the CTC models already downloaded by the app; skipped otherwise.
@MainActor
struct VocabularyBoostingModelTests {
    nonisolated static var modelsAvailable: Bool {
        ParakeetTranscriber.isModelDownloaded()
            && VocabularyBooster.isModelDownloaded()
    }

    private let vocabulary = ["Thibaut Mottet", "FluidAudio", "Argo CD", "Kubernetes", "Claude Code", "Grafana"]

    private func synthesize(_ sentence: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, sentence]
        try say.run()
        say.waitUntilExit()
        return try AudioResampler.samples(fromFile: url)
    }

    private func transcribe(_ sentence: String, voice: String, language: String) async throws -> (plain: Transcription, boosted: Transcription, added: Duration?) {
        let booster = VocabularyBooster()
        await booster.load()
        #expect(booster.state == .ready)
        let samples = try synthesize(sentence, voice: voice)
        let plain = try await ParakeetTranscriber().transcription(samples: samples, language: language)
        let transcriber = ParakeetTranscriber(booster: booster, boostedVocabulary: { vocabulary })
        _ = try await transcriber.transcription(samples: samples, language: language)
        let first = booster.lastDuration
        // The first rescoring also tokenizes the vocabulary and warms the model up.
        let boosted = try await transcriber.transcription(samples: samples, language: language)
        print("""
            Boosting [\(language)] added \(first.map { "\($0)" } ?? "nothing") the first time, \
            then \(booster.lastDuration.map { "\($0)" } ?? "nothing"), for \(samples.count / AudioAnalysis.sampleRate) s of audio:
              plain:   \(plain.text)
              boosted: \(boosted.text)
            """)
        return (plain, boosted, booster.lastDuration)
    }

    /// Parakeet hears "Fluid Audio": the vocabulary puts the name back.
    @Test(.enabled(if: modelsAvailable), .timeLimit(.minutes(5)))
    func fixesMangledNamesInEnglish() async throws {
        let result = try await transcribe("Ask Thibaut Mottet to update FluidAudio and Parakeet.", voice: "Daniel", language: "en")
        #expect(result.boosted.vocabularyBoosted)
        #expect(result.boosted.text.contains("FluidAudio"), "got: \(result.boosted.text)")
        #expect(result.boosted.text.contains("to update"), "got: \(result.boosted.text)")
        #expect(result.boosted.text.hasPrefix("Ask "))
        #expect(result.boosted.words.map(\.text) == result.boosted.text.split(separator: " ").map(String.init))
        #expect(result.added != nil)
    }

    /// "Cloud Code" in a French sentence, and "avec" kept before "Argo CD".
    @Test(.enabled(if: modelsAvailable), .timeLimit(.minutes(5)))
    func keepsTheFrenchAroundTheTerms() async throws {
        let result = try await transcribe(
            "On déploie sur Kubernetes avec Argo CD, puis envoie les erreurs à Claude Code.", voice: "Thomas", language: "fr"
        )
        #expect(result.boosted.vocabularyBoosted)
        #expect(result.boosted.text.contains("avec Argo CD"), "got: \(result.boosted.text)")
        #expect(result.boosted.text.contains("Claude Code"), "got: \(result.boosted.text)")
        #expect(result.boosted.text.contains("puis envoie les erreurs"), "got: \(result.boosted.text)")
    }
}
