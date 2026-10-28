import Darwin
import Foundation

nonisolated enum ClaudeCLIError: LocalizedError, Equatable {
    case notFound
    case failed(String)
    case noResult(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "CLI claude introuvable. Installez Claude Code ou indiquez son chemin dans les réglages.")
        case .failed(let message):
            String(localized: "Claude a renvoyé une erreur : \(message)")
        case .noResult(let details):
            String(localized: "Claude Code s'est arrêté sans réponse. \(details)")
        }
    }

    /// Claude declining because the subscription's session, weekly or spend
    /// limit is spent. The CLI says so in its `result` text ("You've hit your
    /// session limit · resets 3:20pm", "Usage limit reached"…); nothing in
    /// Dictate caused it and the raw transcript goes in. Any other wording
    /// stays a failure to look into.
    var isUsageLimit: Bool {
        guard case .failed(let message) = self else { return false }
        let text = message.lowercased()
        if text.contains("usage limit") { return true }
        return text.contains("limit") && (text.contains("hit your") || text.contains("reached your"))
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
        // Cleaning up a transcript needs no extended thinking; with thinking on,
        // a cold Haiku request was measured at 4.6 s instead of 1.5 s. CLI
        // 2.1.293 with Haiku 5.5 thinks anyway (~250 tokens, ~1 s): neither
        // this, CLAUDE_CODE_DISABLE_THINKING, alwaysThinkingEnabled nor
        // --effort low turned it off on 2026-10-11, hence Haiku 4.5, which
        // does not think (ClaudeCLIEnhancer.defaultModel).
        var environment = ProcessInfo.processInfo.environment
        environment["MAX_THINKING_TOKENS"] = "0"
        process.environment = environment
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
        let text = try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            reader.cancel()
            terminate()
            outcome.resolve(.failure(CancellationError()))
        }
        // The CLI would go on with its post-turn summary: nothing left to wait for.
        reader.cancel()
        terminate()
        return text
    }

    /// Returns on the assistant's text rather than on the `result` event: the
    /// CLI writes a post-turn summary before `result`, measured at 2.5 to 5 s
    /// on 2026-10-11 with CLI 2.1.293, longer than the cleanup itself.
    private static func readResult(from stdout: FileHandle, stderr: LockedBuffer) async throws -> String {
        for try await line in stdout.bytes.lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let text = assistantText(event) { return text }
            guard event["type"] as? String == "result" else { continue }
            let text = event["result"] as? String ?? ""
            let subtype = event["subtype"] as? String ?? "unknown"
            if event["is_error"] as? Bool == true || subtype != "success" {
                throw ClaudeCLIError.failed(text.isEmpty ? subtype : text)
            }
            return text
        }
        throw ClaudeCLIError.noResult(stderr.text)
    }

    /// The text of a model reply. Nil for thinking-only messages and for the
    /// messages the CLI makes up itself on an API or login error, which carry
    /// an `error` field: those are left for the `result` event to report.
    static func assistantText(_ event: [String: Any]) -> String? {
        guard event["type"] as? String == "assistant", event["error"] == nil,
              let message = event["message"] as? [String: Any],
              message["model"] as? String != "<synthetic>",
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
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
