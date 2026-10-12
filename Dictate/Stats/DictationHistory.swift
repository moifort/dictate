import Foundation
import Observation

/// Every finished dictation, one JSON line each, appended as it happens.
/// A line is about a hundred bytes: years of dictation stay a few megabytes.
@Observable
final class DictationHistory {
    private(set) var records: [DictationRecord]

    @ObservationIgnored private let file: URL

    /// One file per bundle identifier: a Debug build must not mix its test
    /// dictations into the statistics of the installed release.
    static var defaultFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "Dictate/Statistics", directoryHint: .isDirectory)
            .appending(path: "\(Bundle.main.bundleIdentifier ?? "Dictate").jsonl")
    }

    init(file: URL = DictationHistory.defaultFile) {
        self.file = file
        records = Self.load(file)
    }

    func append(_ record: DictationRecord) {
        records.append(record)
        do {
            var line = try Self.encoder.encode(record)
            line.append(0x0A)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            Log.app.error("could not save dictation statistics: \(error.localizedDescription, privacy: .public)")
            ErrorReporter.capture(error, "dictation statistics could not be saved", category: "stats")
        }
    }

    /// A damaged line, say from a crash mid-write, is skipped rather than
    /// costing the whole history.
    private static func load(_ file: URL) -> [DictationRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DictationRecord.self, from: $0) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
