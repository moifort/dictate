import os

/// The work was still running when the time was up.
nonisolated struct DeadlineExceeded: Error {}

/// Waits for `work` for at most `limit`. For work stuck in a blocking call,
/// which cancellation cannot reach: it is abandoned, not stopped, and a result
/// it still comes up with goes to `late` so that it can be released.
nonisolated func value<T: Sendable>(
    of work: Task<T, Error>,
    within limit: Duration,
    late: @escaping @Sendable (T) -> Void
) async throws -> T {
    let settled = OSAllocatedUnfairLock(initialState: false)
    let settle: @Sendable () -> Bool = {
        settled.withLock { isSettled in
            defer { isSettled = true }
            return !isSettled
        }
    }
    return try await withCheckedThrowingContinuation { continuation in
        let timer = Task.detached {
            try? await Task.sleep(for: limit)
            if settle() { continuation.resume(throwing: DeadlineExceeded()) }
        }
        Task.detached {
            let result = await work.result
            if settle() {
                timer.cancel()
                continuation.resume(with: result)
            } else if case .success(let value) = result {
                late(value)
            }
        }
    }
}
