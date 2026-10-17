import Foundation
import Network
import Observation

/// Whether the Mac has a usable network path, for the enhancers that need
/// one. Assumes online until the system says otherwise.
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                Log.app.info("network \(online ? "reachable" : "unreachable", privacy: .public)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.thibautmottet.dictate.network"))
    }

    func stop() {
        monitor.cancel()
    }
}
