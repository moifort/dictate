import Foundation

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
