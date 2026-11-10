import Foundation
import Observation

/// Where a downloaded model stands, as the screens show it, and its load:
/// shared by Parakeet and the vocabulary boosting model.
@Observable
final class ModelLoader {
    private(set) var state: TranscriberState = .notLoaded
    /// For the reports: "parakeet", "vocabulary boosting".
    @ObservationIgnored private let name: String

    init(name: String) {
        self.name = name
    }

    /// Downloads the model on first use, then loads it, following its
    /// progress. Does nothing while a load runs or once it is ready.
    func load(_ work: (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) async {
        guard !state.isBusy, state != .ready else { return }
        state = .loading
        do {
            try await work { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.state.isBusy else { return }
                    // The download is over: what remains is compiling the model for this Mac.
                    self.state = fraction < 1 ? .downloading(fraction) : .loading
                }
            }
            state = .ready
            ErrorReporter.breadcrumb("\(name) model ready", category: "transcriber")
        } catch {
            ErrorReporter.capture(error, "\(name) model failed to load", category: "transcriber")
            state = .failed(error.localizedDescription)
        }
    }

    /// The model was freed.
    func unloaded() {
        state = .notLoaded
    }
}
