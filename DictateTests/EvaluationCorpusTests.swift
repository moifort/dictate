import Foundation
import Testing
@testable import Dictate

@MainActor
struct EvaluationCorpusTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "EvaluationCorpusTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func sample(inserted: String = "Fais un push.", watch: InsertionWatch? = nil) -> DictationSample {
        DictationSample(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            samples: [0, 0.5, -0.5, 1],
            engine: .parakeet,
            language: "fr",
            bundleID: "com.apple.Terminal",
            category: .code,
            transcript: "euh fais un pouche",
            inserted: inserted,
            enhanced: true,
            watch: watch
        )
    }

    @Test func missingFolderStartsEmpty() {
        #expect(EvaluationCorpus(folder: folder).entries.isEmpty)
    }

    @Test func entriesAndAudioSurviveARelaunch() throws {
        let corpus = EvaluationCorpus(folder: folder)
        corpus.add(sample(), reference: "Fais un push.")
        corpus.add(sample(), reference: nil)

        let reloaded = EvaluationCorpus(folder: folder)
        #expect(reloaded.entries == corpus.entries)
        let entry = try #require(reloaded.entries.first)
        #expect(entry.transcript == "euh fais un pouche")
        #expect(entry.inserted == "Fais un push.")
        #expect(entry.reference == "Fais un push.")
        #expect(entry.engine == .parakeet)
        #expect(entry.category == "code")
        #expect(entry.bundleID == "com.apple.Terminal")
        #expect(entry.audio == 4.0 / 16_000)
        let audio = try Data(contentsOf: reloaded.audioURL(of: entry))
        let samples = try #require(WAVFile.samples(from: audio))
        #expect(samples.count == 4)
        #expect(abs(samples[1] - 0.5) < 0.001)
        #expect(reloaded.entries.last?.reference == nil)
    }

    @Test func deleteAllRemovesEverything() {
        let corpus = EvaluationCorpus(folder: folder)
        corpus.add(sample(), reference: "Fais un push.")
        corpus.deleteAll()
        #expect(corpus.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(EvaluationCorpus(folder: folder).entries.isEmpty)
    }

    @Test func recordWaitsForTheUsersFixes() async {
        let field = CorpusFakeField(text: "Salut, ")
        let observer = PostInsertionObserver(reader: CorpusFakeReader(field: field), delay: .milliseconds(10))
        let watch = observer.watchFocusedField()
        field.text = "Salut, Fais un push sur main."
        let corpus = EvaluationCorpus(folder: folder)
        await corpus.record(sample(inserted: "Fais un push.", watch: watch), observer: observer)
        #expect(corpus.entries.first?.reference == "Fais un push sur main.")
    }

    @Test func recordWithoutAReadableFieldKeepsTheDictationWithoutReference() async {
        let observer = PostInsertionObserver(reader: CorpusFakeReader(field: nil), delay: .milliseconds(10))
        let corpus = EvaluationCorpus(folder: folder)
        await corpus.record(sample(watch: nil), observer: observer)
        #expect(corpus.entries.count == 1)
        #expect(corpus.entries.first?.reference == nil)
    }
}

struct WAVFileTests {
    @Test func headerDescribes16kHzMono16Bit() {
        let data = [UInt8](WAVFile.data(samples: [0, 1]))
        #expect(data.count == 48)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[36..<40]) == Array("data".utf8))
        #expect(data[22] == 1)                                  // mono
        #expect(UInt32(data[24]) | UInt32(data[25]) << 8 == 16_000)
        #expect(data[34] == 16)                                 // bits per sample
    }

    @Test func samplesRoundTripAndClip() throws {
        let samples = try #require(WAVFile.samples(from: WAVFile.data(samples: [-2, -0.25, 0, 0.25, 2])))
        #expect(samples.count == 5)
        #expect(samples.first == -1)
        #expect(samples.last == 1)
        #expect(abs(samples[1] + 0.25) < 0.001)
    }

    @Test func anythingElseIsRejected() {
        #expect(WAVFile.samples(from: Data("not a wav file at all, but long enough to pass".utf8)) == nil)
    }
}

struct CorpusEvaluationTests {
    private func entry(
        engine: TranscriptionEngine = .parakeet, transcript: String, inserted: String, enhanced: Bool = true, reference: String?
    ) -> CorpusEntry {
        CorpusEntry(
            id: UUID(), date: .now, audioFile: "a.wav", audio: 1, engine: engine, language: "fr",
            bundleID: nil, category: "other", transcript: transcript, inserted: inserted, enhanced: enhanced,
            reference: reference
        )
    }

    @Test func poolsErrorsOverTheDictationsWithAReference() {
        let evaluation = CorpusEvaluation(entries: [
            // Transcript: "euh" added, "pouche", "maintenant" dropped. Claude: "maintenant" dropped.
            entry(transcript: "euh fais un pouche", inserted: "Fais un push.", reference: "Fais un push maintenant"),
            // Transcript: "toi". Claude: "Bonjour" and "toi".
            entry(transcript: "salut toi", inserted: "Bonjour toi", reference: "salut Thibaut"),
            entry(transcript: "ignoré", inserted: "Ignoré", reference: nil),
        ])
        #expect(evaluation.total == 3)
        let parakeet = evaluation.engines[.parakeet]
        #expect(parakeet?.dictations == 2)
        #expect(parakeet?.transcript == WordErrorRate.Count(errors: 4, referenceWords: 6))
        #expect(parakeet?.enhanced == WordErrorRate.Count(errors: 3, referenceWords: 6))
        #expect(parakeet?.enhancedDictations == 2)
    }

    @Test func rawInsertionsDoNotCountForClaude() {
        let evaluation = CorpusEvaluation(entries: [
            entry(transcript: "fais un push", inserted: "fais un push", enhanced: false, reference: "fais un push"),
        ])
        #expect(evaluation.engines[.parakeet]?.enhancedDictations == 0)
        #expect(evaluation.engines[.parakeet]?.enhanced.referenceWords == 0)
    }

    @Test func summaryNamesTheEngine() {
        let evaluation = CorpusEvaluation(entries: [
            entry(engine: .parakeet, transcript: "a", inserted: "a", reference: "a"),
        ])
        #expect(evaluation.engines[.parakeet]?.transcript.rate == 0)
        #expect(evaluation.summary.contains("Parakeet seul"))
        #expect(evaluation.summary.contains("Parakeet + Claude"))
    }
}

@MainActor
private final class CorpusFakeField: ReadableField {
    var text: String

    init(text: String) { self.text = text }

    func snapshot() -> FieldSnapshot? {
        FieldSnapshot(text: text, selection: NSRange(location: (text as NSString).length, length: 0))
    }
}

@MainActor
private final class CorpusFakeReader: FieldReading {
    let field: CorpusFakeField?

    init(field: CorpusFakeField?) { self.field = field }

    func focusedField() -> (any ReadableField)? { field }
}
