import Foundation
import Observation
import DictateKit

/// Real dictations kept on this Mac to measure the engines' word error rate:
/// a WAV file each, and one JSON line per dictation in `entries.jsonl`.
///
/// Opt-in, never uploaded: the text and the audio stay in this folder, and
/// errors reported to Sentry say what failed, never what was said.
@Observable
final class EvaluationCorpus {
    private(set) var entries: [CorpusEntry]

    @ObservationIgnored let folder: URL
    private var entriesFile: JSONLinesFile<CorpusEntry> { JSONLinesFile(folder.appending(path: "entries.jsonl")) }

    /// One folder per bundle identifier, like the statistics: a Debug build
    /// must not mix its test dictations into the release's corpus.
    static var defaultFolder: URL {
        URL.applicationSupportDirectory
            .appending(path: "Dictate/Corpus", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier ?? "Dictate", directoryHint: .isDirectory)
    }

    init(folder: URL = EvaluationCorpus.defaultFolder) {
        self.folder = folder
        entries = JSONLinesFile<CorpusEntry>(folder.appending(path: "entries.jsonl")).load()
    }

    /// Waits for the user's fixes, then keeps the dictation.
    func record(_ sample: DictationSample) async {
        let reference = await sample.followUp?.value?.corrected
        await add(sample, reference: reference)
    }

    /// The audio is encoded and both files written off the main actor.
    func add(_ sample: DictationSample, reference: String?) async {
        let id = UUID()
        let entry = CorpusEntry(
            id: id,
            date: sample.date,
            audioFile: "\(id.uuidString).wav",
            audio: Double(sample.samples.count) / Double(AudioAnalysis.sampleRate),
            engine: sample.engine,
            language: sample.language,
            bundleID: sample.bundleID,
            category: sample.category.rawValue,
            transcript: sample.transcript,
            inserted: sample.inserted,
            enhanced: sample.enhanced,
            reference: reference,
            vocabularyBoosted: sample.vocabularyBoosted
        )
        do {
            try await Self.write(sample.samples, to: audioURL(of: entry), entry: entry, in: entriesFile)
            entries.append(entry)
            Log.app.info("corpus: kept dictation \(self.entries.count), reference: \(reference != nil)")
        } catch {
            Log.app.error("could not save corpus entry: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "evaluation corpus entry could not be saved", category: "corpus")
        }
    }

    @concurrent
    private nonisolated static func write(
        _ samples: [Float], to audio: URL, entry: CorpusEntry, in file: JSONLinesFile<CorpusEntry>
    ) async throws {
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WAVFile.data(samples: samples).write(to: audio)
        try file.append(entry)
    }

    func audioURL(of entry: CorpusEntry) -> URL {
        folder.appending(path: entry.audioFile)
    }

    /// Removes every recording and text kept so far.
    func deleteAll() {
        entries = []
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
            Log.app.info("corpus deleted")
        } catch {
            Log.app.error("could not delete corpus: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "evaluation corpus could not be deleted", category: "corpus")
        }
    }
}
