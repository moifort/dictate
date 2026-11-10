import Foundation

extension Duration {
    /// Whole milliseconds, for the logs.
    public nonisolated var milliseconds: Int {
        Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    /// Seconds with their fraction, for the statistics.
    public nonisolated var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
