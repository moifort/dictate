import Foundation
import Testing
@testable import Dictate

@MainActor
struct ClaudeAPIEnhancerTests {
    nonisolated private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: ClaudeAPIEnhancer.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    nonisolated private static func reply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
    }

    @Test func theRequestCarriesTheKeyModelAndPrompts() throws {
        let request = try ClaudeAPIEnhancer.request(apiKey: "sk-ant-test", model: "claude-haiku-4-5", systemPrompt: "system", message: "hello")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["system"] as? String == "system")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "hello")
    }

    @Test func theReplysTextBlocksAreJoined() throws {
        let data = try JSONSerialization.data(withJSONObject: ["content": [
            ["type": "text", "text": "Bon"], ["type": "text", "text": "jour"],
        ]])
        #expect(try ClaudeAPIEnhancer.text(from: data, status: 200) == "Bonjour")
    }

    @Test func statusesMapToErrors() throws {
        #expect(throws: ClaudeAPIError.invalidKey) { try ClaudeAPIEnhancer.text(from: Data(), status: 401) }
        #expect(throws: ClaudeAPIError.invalidKey) { try ClaudeAPIEnhancer.text(from: Data(), status: 403) }
        #expect(throws: ClaudeAPIError.rateLimited) { try ClaudeAPIEnhancer.text(from: Data(), status: 429) }
        let overloaded = try JSONSerialization.data(withJSONObject: ["error": ["message": "Overloaded"]])
        #expect(throws: ClaudeAPIError.failed(status: 529, message: "Overloaded")) {
            try ClaudeAPIEnhancer.text(from: overloaded, status: 529)
        }
        #expect(throws: ClaudeAPIError.noText) { try ClaudeAPIEnhancer.text(from: Data("{}".utf8), status: 200) }
    }

    @Test func enhanceSendsTheTrimmedKeyAndCleansTheReply() async throws {
        let sent = OneShot<URLRequest>()
        let enhancer = ClaudeAPIEnhancer(apiKey: { " sk-ant-test \n" }, systemPrompt: { "system" }) { request in
            sent.resolve(.success(request))
            return (Self.reply("Je pousse sur main."), Self.response(200))
        }
        #expect(try await enhancer.enhance(transcript: "euh je pousse sur main", context: DictationContext()) == "Je pousse sur main.")
        let request = try await sent.value()
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    }

    @Test func withoutAKeyNothingIsSent() async {
        let enhancer = ClaudeAPIEnhancer(apiKey: { "" }, systemPrompt: { "" }) { _ in
            Issue.record("no request expected")
            return (Data(), URLResponse())
        }
        await #expect(throws: ClaudeAPIError.missingKey) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func maskedKeysKeepTheirEnds() {
        #expect(APIKeyField.masked("sk-ant-api03-abcdefghijklmnopwxyz") == "sk-ant-api…wxyz")
        #expect(APIKeyField.masked("short") == "••••")
    }
}

@MainActor
struct ClaudeEnhancerTests {
    private final class Fake: WarmableEnhancer {
        let name: String
        private(set) var warm = false
        init(_ name: String) { self.name = name }
        func prewarm() { warm = true }
        func reset() { warm = true }
        func shutdown() { warm = false }
        func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String { name }
    }

    @Test func theAccessPicksTheRoute() async throws {
        var access = ClaudeAccess.subscription
        let enhancer = ClaudeEnhancer(access: { access }, cli: Fake("cli"), api: Fake("api"))
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "cli")
        access = .apiKey
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "api")
    }

    @Test func theCLIIsOnlyWarmForTheSubscription() {
        var access = ClaudeAccess.subscription
        let cli = Fake("cli")
        let enhancer = ClaudeEnhancer(access: { access }, cli: cli, api: Fake("api"))
        enhancer.prewarm()
        #expect(cli.warm)
        access = .apiKey
        enhancer.reset()
        #expect(!cli.warm)
    }
}
