import Darwin
import Foundation

/// A file of one JSON record per line, appended as records come: the
/// statistics and the evaluation corpus. A damaged line, say from a crash
/// mid-write, is skipped rather than costing the whole file.
nonisolated struct JSONLinesFile<Record: Codable>: Sendable {
    let url: URL

    init(_ url: URL) { self.url = url }

    func load() -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONCoders.decoder.decode(Record.self, from: $0) }
    }

    /// Appends one line, creating the file and its folder the first time.
    /// Opened in append mode, so a failure can never truncate what is there.
    func append(_ record: Record) throws {
        var line = try JSONCoders.encoder.encode(record)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: line)
    }
}

/// ISO 8601 dates, keys sorted: every JSON file the app writes.
nonisolated enum JSONCoders {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
