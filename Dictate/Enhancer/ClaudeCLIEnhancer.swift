import Foundation

/// Cleans up transcripts with Claude through the official `claude` CLI, so the
/// user's Claude subscription is used.
///
/// Starting the CLI takes seconds, so one process is always started ahead of
/// time and waits for its single message. After each use a fresh process is
/// started, which keeps every cleanup independent of the previous ones.
final class ClaudeCLIEnhancer: Enhancer {
    private let locate: () -> URL?
    private let systemPrompt: () -> String
    private let model: String
    private let recycleAfter: Duration
    private let workingDirectory: URL

    private var warm: ClaudeCLIProcess?
    private var recycleTask: Task<Void, Never>?

    /// Haiku 4.5, pinned: the `haiku` alias now means Haiku 5.5, which thinks
    /// before answering whatever the CLI is told. On 60 real dictations
    /// (2026-10-28) 4.5 answered in 1.1 s median against 1.7 s, 1.5 s at p90
    /// against 3.0 s, and a blind review rated both equally.
    static let defaultModel = "claude-haiku-4-5"

    init(
        locate: @escaping () -> URL?,
        systemPrompt: @escaping () -> String,
        model: String = ClaudeCLIEnhancer.defaultModel,
        recycleAfter: Duration = .seconds(15 * 60)
    ) {
        self.locate = locate
        self.systemPrompt = systemPrompt
        self.model = model
        self.recycleAfter = recycleAfter
        workingDirectory = FileManager.default.temporaryDirectory.appending(path: "Dictate", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    static func arguments(model: String, systemPrompt: String) -> [String] {
        [
            "-p",
            "--model", model,
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--system-prompt", systemPrompt,
        ]
    }

    /// Makes sure a process is ready for the next dictation.
    func prewarm() {
        guard warm?.isRunning != true else { return }
        do {
            warm = try spawn()
        } catch ClaudeCLIError.notFound {
            // Expected on a Mac without Claude Code: the setup says so.
            warm = nil
        } catch {
            ErrorReporter.capture(error, "claude process could not be started ahead of time", category: "enhancer")
            warm = nil
        }
        scheduleRecycle()
    }

    /// Replaces the waiting process, e.g. after the vocabulary or CLI path changed.
    func reset() {
        warm?.terminate()
        warm = nil
        prewarm()
    }

    func shutdown() {
        recycleTask?.cancel()
        warm?.terminate()
        warm = nil
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        let process: ClaudeCLIProcess
        if let warm, warm.isRunning {
            process = warm
        } else {
            process = try spawn()
        }
        warm = nil
        defer { prewarm() }
        let reply = try await process.send(PromptBuilder.userMessage(transcription: transcription, context: context))
        // The prompt forbids them, but a marker left in would end up in the user's text.
        return DoubtfulWords.strip(PromptBuilder.cleanedText(from: reply))
    }

    private func spawn() throws -> ClaudeCLIProcess {
        guard let executable = locate() else { throw ClaudeCLIError.notFound }
        return try ClaudeCLIProcess(
            executable: executable,
            arguments: Self.arguments(model: model, systemPrompt: systemPrompt()),
            workingDirectory: workingDirectory
        )
    }

    /// A process idle for a long time is replaced, so its session never goes stale.
    private func scheduleRecycle() {
        recycleTask?.cancel()
        recycleTask = Task { [recycleAfter] in
            try? await Task.sleep(for: recycleAfter)
            guard !Task.isCancelled else { return }
            reset()
        }
    }
}
