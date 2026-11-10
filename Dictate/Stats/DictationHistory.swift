import Foundation
import Observation

/// Every finished dictation, one JSON line each, appended as it happens.
/// A line is about a hundred bytes: years of dictation stay a few megabytes.
@Observable
final class DictationHistory {
    private(set) var records: [DictationRecord]

    @ObservationIgnored private let file: JSONLinesFile<DictationRecord>

    /// One file per bundle identifier: a Debug build must not mix its test
    /// dictations into the statistics of the installed release.
    static var defaultFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "Dictate/Statistics", directoryHint: .isDirectory)
            .appending(path: "\(Bundle.main.bundleIdentifier ?? "Dictate").jsonl")
    }

    init(file: URL = DictationHistory.defaultFile) {
        self.file = JSONLinesFile(file)
        records = self.file.load()
    }

    func append(_ record: DictationRecord) {
        records.append(record)
        do {
            try file.append(record)
        } catch {
            Log.app.error("could not save dictation statistics: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "dictation statistics could not be saved", category: "stats")
        }
    }
}
