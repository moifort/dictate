import DictateKit
import Foundation
import Testing

@testable import Dictate

@MainActor
struct APIEnhancerTests {
    nonisolated private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    nonisolated private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    @Test func anthropicGetsTheKeyHeaderAndTheSystemField() throws {
        let request = try APIProvider.anthropic.request(apiKey: "sk-ant-test", model: "claude-haiku-4-5", systemPrompt: "system", message: "hello")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try body(request)
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["system"] as? String == "system")
        #expect((body["messages"] as? [[String: Any]])?.first?["content"] as? String == "hello")
    }

    @Test func openAIGetsABearerAndNoReasoning() throws {
        let request = try APIProvider.openAI.request(apiKey: "sk-test", model: "gpt-5.4-nano", systemPrompt: "system", message: "hello")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        let body = try body(request)
        #expect(body["reasoning_effort"] as? String == "none")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test func geminiPutsTheModelInThePathAndThinksMinimally() throws {
        let request = try APIProvider.gemini.request(apiKey: "AIza-test", model: "gemini-3.5-flash-lite", systemPrompt: "system", message: "hello")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test")
        let body = try body(request)
        let config = body["generationConfig"] as? [String: Any]
        #expect((config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "minimal")
        #expect(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == "system")
    }

    @Test func eachReplyShapeGivesItsText() throws {
        let anthropic = Self.json(["content": [["type": "text", "text": "Bon"], ["type": "text", "text": "jour"]]])
        #expect(try APIProvider.anthropic.text(from: anthropic, status: 200) == "Bonjour")
        let openAI = Self.json(["choices": [["message": ["role": "assistant", "content": "Bonjour"]]]])
        #expect(try APIProvider.openAI.text(from: openAI, status: 200) == "Bonjour")
        let gemini = Self.json(["candidates": [["content": ["parts": [["text": "pensée", "thought": true], ["text": "Bonjour"]]]]]])
        #expect(try APIProvider.gemini.text(from: gemini, status: 200) == "Bonjour")
    }

    @Test func statusesMapToErrors() {
        #expect(throws: APIReviewError.invalidKey(.anthropic)) { try APIProvider.anthropic.text(from: Data(), status: 401) }
        #expect(throws: APIReviewError.invalidKey(.openAI)) { try APIProvider.openAI.text(from: Data(), status: 403) }
        let badGeminiKey = Self.json(["error": ["code": 400, "message": "API key not valid. Please pass a valid API key."]])
        #expect(throws: APIReviewError.invalidKey(.gemini)) { try APIProvider.gemini.text(from: badGeminiKey, status: 400) }
        #expect(throws: APIReviewError.rateLimited(.openAI)) { try APIProvider.openAI.text(from: Data(), status: 429) }
        let overloaded = Self.json(["error": ["message": "Overloaded"]])
        #expect(throws: APIReviewError.failed(.anthropic, status: 529, message: "Overloaded")) {
            try APIProvider.anthropic.text(from: overloaded, status: 529)
        }
        #expect(throws: APIReviewError.noText(.gemini)) { try APIProvider.gemini.text(from: Data("{}".utf8), status: 200) }
    }

    @Test func theFastestModelsAreTheDefaults() {
        #expect(APIProvider.anthropic.defaultModel == ClaudeCLIEnhancer.defaultModel)
        #expect(APIProvider.openAI.defaultModel == "gpt-5.4-nano")
        #expect(APIProvider.gemini.defaultModel == "gemini-3.5-flash-lite")
    }

    @Test func enhanceSendsTheTrimmedKeyAndCleansTheReply() async throws {
        let sent = OneShot<URLRequest>()
        let enhancer = APIEnhancer(
            provider: .openAI, apiKey: { " sk-test \n" }, systemPrompt: { "system" },
            send: { request in
                sent.resolve(.success(request))
                return (Self.json(["choices": [["message": ["content": "Je pousse sur main."]]]]), Self.response(200))
            }
        )
        #expect(try await enhancer.enhance(transcript: "euh je pousse sur main", context: DictationContext()) == "Je pousse sur main.")
        let request = try await sent.value()
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        #expect(try body(request)["model"] as? String == "gpt-5.4-nano")
    }

    @Test func withoutAKeyNothingIsSent() async {
        let enhancer = APIEnhancer(
            provider: .gemini, apiKey: { "" }, systemPrompt: { "" },
            send: { _ in
                Issue.record("no request expected")
                return (Data(), URLResponse())
            }
        )
        await #expect(throws: APIReviewError.missingKey(.gemini)) {
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

struct APISessionTests {
    @Test func theSessionKeepsNothingAndGivesUpInTime() {
        let configuration = APIEnhancer.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.timeoutIntervalForRequest <= 10)
        #expect(configuration.timeoutIntervalForResource <= 20)
    }
}
