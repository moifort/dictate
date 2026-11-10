import Foundation

/// Refreshes the onboarding checklist at the pace it asks for
/// (`SetupChecklist.pollInterval`), since macOS does not notify permission
/// changes, and stops once everything is ready.
final class SetupMonitor {
    private let refresh: () -> SetupChecklist
    private var timer: Timer?

    /// `refresh` reads the system again and returns the new checklist.
    init(refresh: @escaping () -> SetupChecklist) {
        self.refresh = refresh
    }

    /// Starts, adjusts or stops the polling for `checklist`.
    func follow(_ checklist: SetupChecklist) {
        let interval = checklist.pollInterval
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else {
            Log.app.info("setup complete")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.follow(self.refresh())
            }
        }
    }
}
