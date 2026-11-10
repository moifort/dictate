import Foundation

/// Runs a command line tool to completion, off the cooperative thread pool,
/// with a time limit: a tool that hangs is terminated, never waited on.
nonisolated enum Subprocess {
    struct Output: Sendable {
        let status: Int32
        /// Standard output, and standard error when asked for.
        let data: Data
        /// Terminated by the time limit.
        let timedOut: Bool

        var text: String { String(decoding: data, as: UTF8.self) }
        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Throws only when the tool cannot be launched. Standard input is empty:
    /// a tool waiting for it would otherwise wait for ever.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: Duration = .seconds(30),
        includingStandardError: Bool = false
    ) async throws -> Output {
        let process = Process()
        let output = Pipe()
        let collected = Collected()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = includingStandardError ? output : FileHandle.nullDevice
        // Read as it comes: a full pipe would block the tool before it exits.
        output.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                // What is left in the pipe. Not after a timeout: a child the tool
                // started may still hold the pipe open, and the read would wait for it.
                if !collected.timedOut { collected.append(output.fileHandleForReading.readDataToEndOfFile()) }
                continuation.resume(returning: Output(
                    status: process.terminationStatus, data: collected.data, timedOut: collected.timedOut
                ))
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard process.isRunning else { return }
                collected.markTimedOut()
                process.terminate()
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var expired = false

        func append(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }
        func markTimedOut() { lock.withLock { expired = true } }
        var data: Data { lock.withLock { buffer } }
        var timedOut: Bool { lock.withLock { expired } }
    }
}
