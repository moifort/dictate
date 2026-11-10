import Foundation

/// Runs an action once things settle: each call replaces the previous one
/// and waits `delay` again, so a burst of calls runs the last action once.
final class Debouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(_ action: @escaping () -> Void) {
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
