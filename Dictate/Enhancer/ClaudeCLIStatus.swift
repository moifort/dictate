import Foundation
import Observation

/// What is known of the `claude` CLI: where it is, its version and whether
/// an account is signed in. Looked up on disk, then probed in the background.
@Observable
final class ClaudeCLIStatus {
    private(set) var path: URL?
    /// Version reported by `claude --version`: nil while probing or when the binary does not answer.
    private(set) var version: String?
    private(set) var isProbing = false
    /// Whether `claude auth status` reports a signed-in account; false until
    /// the first answer. Claude cannot review without one.
    private(set) var signedIn = false

    /// Wraps every change of what is known: the app compares the automatic
    /// reviewer before and after, and refreshes what depends on it.
    @ObservationIgnored var onUpdate: (_ apply: () -> Void) -> Void = { $0() }

    @ObservationIgnored private let locator: ClaudeCLILocator
    @ObservationIgnored private let override: () -> String
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init(locator: ClaudeCLILocator = ClaudeCLILocator(), override: @escaping () -> String) {
        self.locator = locator
        self.override = override
        path = locator.locate(override: override())
    }

    /// The CLI is here and an account is signed in.
    var subscriptionReady: Bool { path != nil && signedIn }

    /// Where the CLI is right now, for the enhancer about to start it.
    func locate() -> URL? { locator.locate(override: override()) }

    /// Looks for the CLI again, and probes it when it moved.
    func refresh() {
        let found = locate()
        guard found != path else { return }
        onUpdate { path = found }
        probe()
    }

    /// Asks the CLI again, e.g. after the user signed in to Claude.
    func recheck() {
        let before = path
        refresh()
        // A new path was already probed.
        if path == before { probe() }
    }

    func probe() {
        probeTask?.cancel()
        version = nil
        guard let path else {
            isProbing = false
            onUpdate { signedIn = false }
            return
        }
        isProbing = true
        probeTask = Task {
            async let version = ClaudeCLILocator.version(of: path)
            // A CLI too old to answer keeps working as before: assume signed in.
            async let signedIn = ClaudeCLILocator.isSignedIn(path)
            let (probedVersion, probedSignedIn) = await (version, signedIn ?? true)
            guard !Task.isCancelled else { return }
            Log.app.info("claude signed in: \(probedSignedIn)")
            onUpdate {
                self.version = probedVersion
                self.signedIn = probedSignedIn
                isProbing = false
            }
        }
    }

    /// Short form for the settings: the bundled copy hides deep inside the desktop app.
    func displayPath(_ url: URL) -> String {
        locator.displayPath(of: url)
    }

    /// For the error reports.
    var reportTag: String { path == nil ? "missing" : signedIn ? "signed_in" : "signed_out" }
}
