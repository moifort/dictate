import Foundation

/// One model load at a time, shared by every caller that comes while it
/// runs: a dictation during startup must not trigger a second download or a
/// second copy of the model in memory. Owned by the actor that holds the
/// model, and only used from it.
public nonisolated final class SharedLoad {
    private var running: Task<Void, Error>?

    public init() {}

    /// Runs `load` unless `isLoaded`; joins the load already running if any.
    public func run(isLoaded: Bool, _ load: @escaping @Sendable () async throws -> Void) async throws {
        guard !isLoaded else { return }
        if let running { return try await running.value }
        let task = Task { try await load() }
        running = task
        defer { running = nil }
        try await task.value
    }
}
