import Darwin
import Foundation

nonisolated enum ClaudeCLIError: LocalizedError, Equatable {
    case notFound
    case failed(String)
    case noResult(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "CLI claude introuvable. Installez Claude Code ou indiquez son chemin dans les réglages."
        case .failed(let message):
            "Claude a renvoyé une erreur : \(message)"
        case .noResult(let details):
            "Claude Code s'est arrêté sans réponse. \(details)"
        }
    }
}

/// One `claude -p` process in stream-json mode, started ahead of time and
/// used for exactly one message.
nonisolated final class ClaudeCLIProcess: @unchecked Sendable {
    let startedAt = ContinuousClock.now

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let stderrBuffer = LockedBuffer()

    init(executable: URL, arguments: [String], workingDirectory: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Writing to a process that already exited must throw EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        errors.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            stderrBuffer.append(handle.availableData)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Sends one user message and returns the `result` text.
    func send(_ content: String) async throws -> String {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
        try input.fileHandleForWriting.close()

        let outcome = OneShot<String>()
        let reader = Task.detached { [output, stderrBuffer] in
            do {
                outcome.resolve(.success(try await Self.readResult(from: output.fileHandleForReading, stderr: stderrBuffer)))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            reader.cancel()
            terminate()
            outcome.resolve(.failure(CancellationError()))
        }
    }

    private static func readResult(from stdout: FileHandle, stderr: LockedBuffer) async throws -> String {
        for try await line in stdout.bytes.lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "result"
            else { continue }
            let text = event["result"] as? String ?? ""
            let subtype = event["subtype"] as? String ?? "unknown"
            if event["is_error"] as? Bool == true || subtype != "success" {
                throw ClaudeCLIError.failed(text.isEmpty ? subtype : text)
            }
            return text
        }
        throw ClaudeCLIError.noResult(stderr.text)
    }
}

/// Resolves a single async result exactly once, from any thread.
nonisolated final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ newResult: Result<Value, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: newResult)
    }
}

nonisolated final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 4_096

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
