import Foundation
import Testing
@testable import Dictate

/// Runs the enhancer against fake `claude` shell scripts.
@MainActor
struct ClaudeCLIEnhancerTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "enhancer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fakeCLI(_ body: String) throws -> URL {
        let url = directory.appending(path: "claude")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeEnhancer(_ cli: URL?) -> ClaudeCLIEnhancer {
        ClaudeCLIEnhancer(locate: { cli }, systemPrompt: { "prompt" })
    }

    @Test func returnsResultAndSendsDictationAsStreamJSON() async throws {
        let stdinCopy = directory.appending(path: "stdin.txt")
        let cli = try fakeCLI("""
        cat > "\(stdinCopy.path)"
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"Fais un push."}'
        """)
        let result = try await makeEnhancer(cli).enhance(transcript: "fais un pouche", context: DictationContext(category: .code))
        #expect(result == "Fais un push.")

        let sent = try String(contentsOf: stdinCopy, encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let content = (json["message"] as? [String: Any])?["content"] as? String
        #expect(content == PromptBuilder.userMessage(transcript: "fais un pouche", context: DictationContext(category: .code)))
    }

    @Test func returnsOnTheAssistantTextWithoutWaitingForThePostTurnSummary() async throws {
        let cli = try fakeCLI("""
        cat > /dev/null
        echo '{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"thinking","thinking":""}]}}'
        echo '{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"text","text":"Fais un push."}]}}'
        sleep 5
        echo '{"type":"system","subtype":"post_turn_summary"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"Fais un push."}'
        """)
        let start = ContinuousClock.now
        let result = try await makeEnhancer(cli).enhance(transcript: "fais un pouche", context: DictationContext())
        #expect(result == "Fais un push.")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aMadeUpErrorReplyIsNotTakenForTheCleanup() async throws {
        let cli = try fakeCLI("""
        cat > /dev/null
        echo '{"type":"assistant","error":"authentication_failed","message":{"model":"<synthetic>","content":[{"type":"text","text":"Please run /login"}]}}'
        echo '{"type":"result","subtype":"success","is_error":true,"result":"Please run /login"}'
        """)
        await #expect(throws: ClaudeCLIError.self) {
            try await makeEnhancer(cli).enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func errorResultThrows() async throws {
        let cli = try fakeCLI("""
        cat > /dev/null
        echo '{"type":"result","subtype":"success","is_error":true,"result":"Please run /login"}'
        """)
        await #expect(throws: ClaudeCLIError.self) {
            try await makeEnhancer(cli).enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func exitWithoutResultThrows() async throws {
        let cli = try fakeCLI("cat > /dev/null; echo 'boom' >&2; exit 1")
        await #expect(throws: ClaudeCLIError.self) {
            try await makeEnhancer(cli).enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func missingCLIThrowsNotFound() async {
        await #expect(throws: ClaudeCLIError.notFound) {
            try await makeEnhancer(nil).enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func cancellationTerminatesProcessQuickly() async throws {
        let cli = try fakeCLI("cat > /dev/null; sleep 30")
        let enhancer = makeEnhancer(cli)
        let task = Task { try await enhancer.enhance(transcript: "x", context: DictationContext()) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(2))
        enhancer.shutdown()
    }

    @Test func prewarmedProcessIsUsedThenReplaced() async throws {
        let starts = directory.appending(path: "starts.txt")
        let cli = try fakeCLI("""
        echo started >> "\(starts.path)"
        cat > /dev/null
        echo '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
        """)
        let enhancer = makeEnhancer(cli)
        enhancer.prewarm()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try String(contentsOf: starts, encoding: .utf8).count(of: "started") == 1)

        _ = try await enhancer.enhance(transcript: "x", context: DictationContext())
        try await Task.sleep(for: .milliseconds(300))
        #expect(try String(contentsOf: starts, encoding: .utf8).count(of: "started") == 2)
        enhancer.shutdown()
    }

    @Test func argumentsDisableToolsAndUseStreamJSON() {
        let args = ClaudeCLIEnhancer.arguments(model: "haiku", systemPrompt: "P")
        #expect(args.starts(with: ["-p"]))
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] {
            #expect(args.contains(flag))
        }
        #expect(args.containsSequence(["--model", "haiku"]))
        #expect(args.containsSequence(["--tools", ""]))
        #expect(args.containsSequence(["--setting-sources", ""]))
        #expect(args.containsSequence(["--input-format", "stream-json"]))
        #expect(args.containsSequence(["--output-format", "stream-json"]))
        #expect(args.containsSequence(["--system-prompt", "P"]))
    }
}

private extension String {
    func count(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}

private extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<$0 + sequence.count]) == sequence }
    }
}

@MainActor
struct ClaudeCLIProcessTests {
    @Test func writingToAnExitedProcessThrowsInsteadOfCrashing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appending(path: "claude")
        try Data("#!/bin/bash\nexit 1\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let process = try ClaudeCLIProcess(executable: cli, arguments: [], workingDirectory: dir)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!process.isRunning)
        await #expect(throws: (any Error).self) { try await process.send("hello") }
    }
}
