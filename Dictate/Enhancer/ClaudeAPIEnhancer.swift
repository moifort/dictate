import Foundation

nonisolated enum ClaudeAPIError: LocalizedError, Equatable {
    case missingKey
    /// 401 or 403: the key is wrong, revoked or lacks access.
    case invalidKey
    /// 429: rate or spend limit, nothing to look into.
    case rateLimited
    case failed(status: Int, message: String)
    case noText

    var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "Aucune clé API Claude enregistrée.")
        case .invalidKey:
            String(localized: "Clé API Claude refusée : vérifiez-la dans les Réglages.")
        case .rateLimited:
            String(localized: "Limite de l'API Claude atteinte.")
        case .failed(let status, let message):
            String(localized: "L'API Claude a renvoyé une erreur \(status) : \(message)")
        case .noText:
            String(localized: "L'API Claude n'a renvoyé aucun texte.")
        }
    }
}

/// Cleans up transcripts with Claude through the Messages API and the
/// user's own API key, for those without a subscription. No CLI, no process
/// to keep warm: a request costs the round trip only.
final class ClaudeAPIEnhancer: Enhancer {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let apiKey: () -> String
    private let systemPrompt: () -> String
    private let model: String
    private let send: Send

    init(
        apiKey: @escaping () -> String,
        systemPrompt: @escaping () -> String,
        model: String = ClaudeCLIEnhancer.defaultModel,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.model = model
        self.send = send
    }

    nonisolated static func request(apiKey: String, model: String, systemPrompt: String, message: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4_096,
            "system": systemPrompt,
            "messages": [["role": "user", "content": message]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The reply's text blocks, or the error the API explains.
    nonisolated static func text(from data: Data, status: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch status {
        case 200..<300:
            let content = json?["content"] as? [[String: Any]] ?? []
            let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            guard !texts.isEmpty else { throw ClaudeAPIError.noText }
            return texts.joined()
        case 401, 403:
            throw ClaudeAPIError.invalidKey
        case 429:
            throw ClaudeAPIError.rateLimited
        default:
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw ClaudeAPIError.failed(status: status, message: message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        let key = apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeAPIError.missingKey }
        let request = try Self.request(
            apiKey: key, model: model, systemPrompt: systemPrompt(),
            message: PromptBuilder.userMessage(transcription: transcription, context: context)
        )
        let (data, response) = try await send(request)
        let reply = try Self.text(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        // The prompt forbids them, but a marker left in would end up in the user's text.
        return DoubtfulWords.strip(PromptBuilder.cleanedText(from: reply))
    }
}

/// Routes Claude's cleanups to the CLI or the API, by the access picked in the settings.
final class ClaudeEnhancer: WarmableEnhancer {
    private let access: () -> ClaudeAccess
    let cli: any WarmableEnhancer
    let api: any Enhancer

    init(access: @escaping () -> ClaudeAccess, cli: any WarmableEnhancer, api: any Enhancer) {
        self.access = access
        self.cli = cli
        self.api = api
    }

    /// Only the CLI has a process to start ahead of time.
    func prewarm() {
        if access() == .subscription { cli.prewarm() }
    }

    func reset() {
        switch access() {
        case .subscription: cli.reset()
        case .apiKey: cli.shutdown()
        }
    }

    func shutdown() {
        cli.shutdown()
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        switch access() {
        case .subscription: try await cli.enhance(transcription, context: context)
        case .apiKey: try await api.enhance(transcription, context: context)
        }
    }
}
