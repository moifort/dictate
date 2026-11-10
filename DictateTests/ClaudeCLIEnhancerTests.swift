import Foundation
import Testing
@testable import Dictate
import DictateKit

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

    @Test func sendsDoubtfulWordsMarkedAndStripsMarkersFromTheReply() async throws {
        let stdinCopy = directory.appending(path: "stdin.txt")
        let cli = try fakeCLI("""
        cat > "\(stdinCopy.path)"
        echo '{"type":"result","subtype":"success","is_error":false,"result":"Déploie sur <?>Kubernetes</?>."}'
        """)
        let words = [
            Transcription.Word(text: "déploie", confidence: 0.9),
            Transcription.Word(text: "sur", confidence: 0.9),
            Transcription.Word(text: "Kubernetis", confidence: 0.2),
        ]
        let result = try await makeEnhancer(cli).enhance(
            Transcription(text: "déploie sur Kubernetis", words: words), context: DictationContext()
        )
        #expect(result == "Déploie sur Kubernetes.")
        let sent = try Data(contentsOf: stdinCopy)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let content = try #require((json["message"] as? [String: Any])?["content"] as? String)
        #expect(content.contains("<?>Kubernetis</?>"))
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
        // A loaded machine can take a while to start the script: wait for it, up to 5 s.
        func waitForStarts(_ count: Int) async throws -> Int {
            for _ in 0..<100 {
                let started = (try? String(contentsOf: starts, encoding: .utf8))?.count(of: "started") ?? 0
                if started >= count { return started }
                try await Task.sleep(for: .milliseconds(50))
            }
            return (try? String(contentsOf: starts, encoding: .utf8))?.count(of: "started") ?? 0
        }
        enhancer.prewarm()
        #expect(try await waitForStarts(1) == 1)

        _ = try await enhancer.enhance(transcript: "x", context: DictationContext())
        #expect(try await waitForStarts(2) == 2)
        enhancer.shutdown()
    }

    /// Left idle, the waiting process is stopped, not replaced; the next press starts one.
    @Test func anIdleProcessIsStoppedUntilTheNextPress() async throws {
        let starts = directory.appending(path: "starts.txt")
        let cli = try fakeCLI("""
        echo started >> "\(starts.path)"
        cat > /dev/null
        """)
        let enhancer = ClaudeCLIEnhancer(locate: { cli }, systemPrompt: { "prompt" }, idleTimeout: .milliseconds(200))
        enhancer.prewarm()
        #expect(enhancer.isWarm)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!enhancer.isWarm)
        #expect(try String(contentsOf: starts, encoding: .utf8).count(of: "started") == 1)
        enhancer.prewarm()
        #expect(enhancer.isWarm)
        enhancer.shutdown()
    }

    /// The `haiku` alias follows the newest Haiku, and Haiku 5.5 thinks before answering.
    @Test func defaultModelIsPinnedToHaiku45() {
        #expect(ClaudeCLIEnhancer.defaultModel == "claude-haiku-4-5")
    }

    @Test func argumentsDisableToolsAndUseStreamJSON() {
        let args = ClaudeCLIEnhancer.arguments(model: ClaudeCLIEnhancer.defaultModel, systemPrompt: "P")
        #expect(args.starts(with: ["-p"]))
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] {
            #expect(args.contains(flag))
        }
        #expect(args.containsSequence(["--model", "claude-haiku-4-5"]))
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

/// A usage limit is Claude declining for the day, not a failure of Dictate's.
struct ClaudeCLIErrorTests {
    @Test(arguments: [
        "You've hit your session limit · resets 3:20pm (Europe/Paris)",
        "You've hit your weekly limit · resets Oct 24, 9am (Europe/Paris)",
        "You've hit your monthly spend limit.",
        "Usage limit reached",
        "You've reached your weekly usage limit",
    ])
    func usageLimitsAreRecognised(message: String) {
        #expect(ClaudeCLIError.failed(message).isUsageLimit)
    }

    @Test(arguments: [
        "Please run /login",
        "Invalid API key · Please run /login",
        "error_during_execution",
        "Context limit reached",
    ])
    func otherFailuresAreNot(message: String) {
        #expect(!ClaudeCLIError.failed(message).isUsageLimit)
        #expect(!ClaudeCLIError.noResult(message).isUsageLimit)
        #expect(!ClaudeCLIError.notFound.isUsageLimit)
    }

    @Test(arguments: [
        "Failed to authenticate: OAuth session expired and could not be refreshed",
        "Please run /login",
        "Invalid API key · Please run /login",
        "Not logged in · Please run /login",
    ])
    func disconnectionsAreRecognised(message: String) {
        #expect(ClaudeCLIError.failed(message).isDisconnected)
    }

    @Test(arguments: [
        "error_during_execution",
        "You've hit your session limit · resets 3:20pm",
        "Context limit reached",
    ])
    func otherFailuresAreNotDisconnections(message: String) {
        #expect(!ClaudeCLIError.failed(message).isDisconnected)
        #expect(!ClaudeCLIError.noResult(message).isDisconnected)
        #expect(!ClaudeCLIError.notFound.isDisconnected)
    }
}

/// The CLI's stream-json output as it comes on a failure, line by line: what
/// Dictate reads of it must not depend on the wording of its messages.
struct ClaudeCLIContractTests {
    private func outcome(_ lines: [String]) -> Result<String?, ClaudeCLIError> {
        var reading = ClaudeCLIProcess.StreamReading()
        do {
            for line in lines {
                let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                if let text = try reading.read(event) { return .success(text) }
            }
            return .success(nil)
        } catch let error as ClaudeCLIError {
            return .failure(error)
        } catch {
            Issue.record("\(error)")
            return .success(nil)
        }
    }

    private func failure(code: String, text: String) -> ClaudeCLIError? {
        let result = outcome([
            #"{"type":"system","subtype":"init","model":"claude-haiku-4-5"}"#,
            #"{"type":"assistant","error":"\#(code)","message":{"model":"<synthetic>","content":[{"type":"text","text":"\#(text)"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"\#(text)"}"#,
        ])
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func aSignInFailureIsReadFromItsCodeWhateverTheWording() throws {
        let error = try #require(failure(code: "authentication_failed", text: "Something new went wrong"))
        #expect(error.isDisconnected)
        #expect(!error.isUsageLimit)
        #expect(ReviewFailure(error) == .disconnected)
    }

    @Test func aSpentLimitIsReadFromItsCode() throws {
        #expect(try #require(failure(code: "rate_limit", text: "Any wording")).isUsageLimit)
        #expect(try #require(failure(code: "billing_error", text: "Credit balance is too low")).isUsageLimit)
    }

    /// An "/login" in a server error's text is not a sign-in failure once the code says otherwise.
    @Test func theCodeWinsOverTheWording() throws {
        let error = try #require(failure(code: "server_error", text: "Overloaded, try /login later"))
        #expect(!error.isDisconnected)
        #expect(!error.isUsageLimit)
    }

    /// Older CLIs give no code: the wording still tells.
    @Test func withoutACodeTheWordingIsRead() {
        #expect(ClaudeCLIError.failed("Failed to authenticate: OAuth session expired").isDisconnected)
        #expect(ClaudeCLIError.failed("You've hit your session limit · resets 3:20pm").isUsageLimit)
        #expect(!ClaudeCLIError.failed("Overloaded").isDisconnected)
    }

    @Test func theModelsReplyIsTheCleanup() {
        let result = outcome([
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5","content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"<cleaned>Fais un push.</cleaned>"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"<cleaned>Fais un push.</cleaned>"}"#,
        ])
        #expect(result == .success("<cleaned>Fais un push.</cleaned>"))
    }
}
