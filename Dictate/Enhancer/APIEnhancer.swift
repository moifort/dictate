import Foundation
import DictateKit

/// A service reached with the user's own API key. Each one runs its
/// fastest model that does not reason first: a cleanup is a light task,
/// and every second of thinking is a second the user waits.
nonisolated enum APIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    /// The reviewer this key serves.
    var reviewer: Reviewer {
        switch self {
        case .anthropic: .claude
        case .openAI: .openAI
        case .gemini: .gemini
        }
    }

    /// Same model as through the CLI: Haiku 4.5, which does not think.
    /// GPT-5.4 nano without reasoning has the lowest time to first token of
    /// OpenAI's line (0.7 s, Artificial Analysis, 2026-11). Gemini 3.5
    /// Flash-Lite is Google's fastest; the 3.x line cannot turn thinking
    /// off, only down to "minimal".
    var defaultModel: String {
        switch self {
        case .anthropic: ClaudeCLIEnhancer.defaultModel
        case .openAI: "gpt-5.4-nano"
        case .gemini: "gemini-3.5-flash-lite"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .gemini: "AIza…"
        }
    }

    /// Where the user creates a key.
    var keysPage: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// The keychain item holding this provider's key.
    var keychainAccount: String { "\(rawValue)-api-key" }

    func request(apiKey: String, model: String, systemPrompt: String, message: String) throws -> URLRequest {
        let url: URL
        let body: [String: Any]
        var headers = ["content-type": "application/json"]
        switch self {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
            body = [
                "model": model,
                "max_tokens": 4_096,
                "system": systemPrompt,
                "messages": [["role": "user", "content": message]],
            ]
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            headers["authorization"] = "Bearer \(apiKey)"
            body = [
                "model": model,
                "reasoning_effort": "none",
                "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": message]],
            ]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            headers["x-goog-api-key"] = apiKey
            body = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["role": "user", "parts": [["text": message]]]],
                "generationConfig": ["thinkingConfig": ["thinkingLevel": "minimal"]],
            ]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The reply's text, or the error the service explains.
    func text(from data: Data, status: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 200..<300:
            guard let text = replyText(json), !text.isEmpty else { throw APIReviewError.noText(self) }
            return text
        case 401, 403:
            throw APIReviewError.invalidKey(self)
        // Gemini answers a wrong key with 400 "API key not valid".
        case 400 where message?.localizedCaseInsensitiveContains("api key") == true:
            throw APIReviewError.invalidKey(self)
        case 429:
            throw APIReviewError.rateLimited(self)
        default:
            throw APIReviewError.failed(self, status: status, message: message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    private func replyText(_ json: [String: Any]?) -> String? {
        switch self {
        case .anthropic:
            let content = json?["content"] as? [[String: Any]] ?? []
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openAI:
            let choices = json?["choices"] as? [[String: Any]]
            return (choices?.first?["message"] as? [String: Any])?["content"] as? String
        case .gemini:
            let candidates = json?["candidates"] as? [[String: Any]]
            let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            // Thought summaries come as parts flagged `thought`.
            return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
    }
}

nonisolated enum APIReviewError: LocalizedError, Equatable {
    case missingKey(APIProvider)
    /// The key is wrong, revoked or lacks access.
    case invalidKey(APIProvider)
    /// Rate or spend limit: nothing to look into.
    case rateLimited(APIProvider)
    case failed(APIProvider, status: Int, message: String)
    case noText(APIProvider)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            String(localized: "Aucune clé API \(provider.displayName) enregistrée.")
        case .invalidKey(let provider):
            String(localized: "Clé API \(provider.displayName) refusée : vérifiez-la dans les Réglages.")
        case .rateLimited(let provider):
            String(localized: "Limite de l'API \(provider.displayName) atteinte.")
        case .failed(let provider, let status, let message):
            String(localized: "L'API \(provider.displayName) a renvoyé une erreur \(status) : \(message)")
        case .noText(let provider):
            String(localized: "L'API \(provider.displayName) n'a renvoyé aucun texte.")
        }
    }

    /// Only the user can fix it, with another key.
    var isKeyProblem: Bool {
        switch self {
        case .missingKey, .invalidKey: true
        default: false
        }
    }

    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}

/// Cleans up transcripts through a provider's API and the user's own key.
/// No CLI, no process to keep warm: a request costs the round trip only.
final class APIEnhancer: Enhancer {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let provider: APIProvider
    private let apiKey: () -> String
    private let systemPrompt: () -> String
    private let model: String
    private let send: Send

    init(
        provider: APIProvider,
        apiKey: @escaping () -> String,
        systemPrompt: @escaping () -> String,
        model: String? = nil,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.model = model ?? provider.defaultModel
        self.send = send
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        let key = apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIReviewError.missingKey(provider) }
        let request = try provider.request(
            apiKey: key, model: model, systemPrompt: systemPrompt(),
            message: PromptBuilder.userMessage(transcription: transcription, context: context)
        )
        let (data, response) = try await send(request)
        let reply = try provider.text(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        // The prompt forbids them, but a marker left in would end up in the user's text.
        return DoubtfulWords.strip(PromptBuilder.cleanedText(from: reply))
    }
}
