import Foundation

/// The highlights of the statistics page: the last week against the four
/// before it, as the Fitness app compares weeks.
///
/// Timings are medians, never means: one Claude timeout of eight seconds
/// would otherwise drag a whole week's figure up.
nonisolated struct DictationStats {
    static let recentDays = 7
    static let baselineDays = 28
    /// Below this relative change a trend reads as steady.
    static let steadyThreshold = 0.05

    struct Trend: Equatable {
        enum Direction: Equatable { case up, down, steady }

        /// Over the last seven days; nil without a dictation in them.
        let recent: Double?
        /// Over the four weeks before; nil without a dictation in them.
        let baseline: Double?

        /// Relative change from the baseline; nil without both figures.
        var change: Double? {
            guard let recent, let baseline, baseline > 0 else { return nil }
            return (recent - baseline) / baseline
        }

        var direction: Direction? {
            guard let change else { return nil }
            if abs(change) < DictationStats.steadyThreshold { return .steady }
            return change > 0 ? .up : .down
        }
    }

    /// Average words on the days something was dictated: a weekend off is
    /// not a slower week.
    let wordsPerDay: Trend
    let dictationsPerDay: Trend
    /// Median wait after releasing `fn`, in seconds.
    let latency: Trend
    /// Words per minute of speech.
    let pace: Trend
    /// True before the first dictation ever.
    let isEmpty: Bool
    /// Seconds saved against typing, since the first dictation.
    let timeSaved: TimeInterval
    /// Seconds saved against typing since midnight.
    let timeSavedToday: TimeInterval

    init(records: [DictationRecord], now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        isEmpty = records.isEmpty
        timeSaved = records.reduce(0) { $0 + $1.timeSaved }
        timeSavedToday = records.filter { $0.date >= today }.reduce(0) { $0 + $1.timeSaved }

        func window(from start: Int, count: Int) -> [DictationRecord] {
            let lower = calendar.date(byAdding: .day, value: -(start + count - 1), to: today)!
            let upper = calendar.date(byAdding: .day, value: 1 - start, to: today)!
            return records.filter { $0.date >= lower && $0.date < upper }
        }
        let recent = window(from: 0, count: Self.recentDays)
        let baseline = window(from: Self.recentDays, count: Self.baselineDays)

        func trend(_ measure: ([DictationRecord]) -> Double?) -> Trend {
            Trend(recent: measure(recent), baseline: measure(baseline))
        }
        func perActiveDay(_ value: @escaping (DictationRecord) -> Double) -> ([DictationRecord]) -> Double? {
            { records in
                let activeDays = Set(records.map { calendar.startOfDay(for: $0.date) }).count
                guard activeDays > 0 else { return nil }
                return records.reduce(0) { $0 + value($1) } / Double(activeDays)
            }
        }
        wordsPerDay = trend(perActiveDay { Double($0.words) })
        dictationsPerDay = trend(perActiveDay { _ in 1 })
        latency = trend { Self.median($0.map(\.latency)) }
        pace = trend { records in
            DictationSeries.pace(words: records.reduce(0) { $0 + $1.words }, audio: records.reduce(0) { $0 + $1.audio })
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
