import Foundation

public extension Duration {
    /// Whole milliseconds, for the logs.
    nonisolated var milliseconds: Int {
        Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    /// Seconds with their fraction, for the statistics.
    nonisolated var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
