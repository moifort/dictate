import Foundation

/// Keeps the last value computed for a key: the statistics are worked out
/// from the whole history, and a view's body runs far more often than the
/// history or the hour changes. Held in `@State`, so it lives as long as the view.
final class Memo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    func value(for key: Key, _ compute: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = compute()
        cached = (key, value)
        return value
    }
}

/// What every statistic depends on: the history, which only grows, the
/// period shown and the current hour, the finest column of any period.
nonisolated struct StatsKey: Equatable {
    let count: Int
    let last: Date?
    let period: StatsPeriod
    let hour: Date

    init(records: [DictationRecord], period: StatsPeriod, now: Date, calendar: Calendar = .current) {
        count = records.count
        last = records.last?.date
        self.period = period
        hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
    }
}
