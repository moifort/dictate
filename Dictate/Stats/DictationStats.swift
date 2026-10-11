import Foundation

/// What the statistics page draws, worked out from the history: one column
/// per day over the last month, and the Fitness-style trends of the last
/// week against the four before it.
///
/// Timings are medians, never means: one Claude timeout of eight seconds
/// would otherwise drag a whole day's figure up.
nonisolated struct DictationStats {
    static let dayCount = 30
    static let recentDays = 7
    static let baselineDays = 28
    /// Below this relative change a trend reads as steady.
    static let steadyThreshold = 0.05

    struct Day: Identifiable, Equatable {
        /// Start of the day.
        let date: Date
        let words: Int
        let dictations: Int
        /// Median Whisper time of the day, in seconds.
        let transcription: TimeInterval
        /// Median Claude time of the day, insertion included, in seconds.
        let enhancement: TimeInterval
        /// Median wait after releasing `fn`, in seconds.
        let latency: TimeInterval

        var id: Date { date }
    }

    struct Trend: Equatable {
        enum Direction: Equatable { case up, down, steady }

        /// Over the last seven days; nil without a dictation in them.
        let recent: Double?
        /// Over the four weeks before; nil without a dictation in them.
        let baseline: Double?

        var direction: Direction? {
            guard let recent, let baseline, baseline > 0 else { return nil }
            let change = (recent - baseline) / baseline
            if abs(change) < DictationStats.steadyThreshold { return .steady }
            return change > 0 ? .up : .down
        }
    }

    /// Oldest first, today last, days without a dictation included.
    let days: [Day]
    /// Average words on the days something was dictated: a weekend off is
    /// not a slower week.
    let wordsPerDay: Trend
    let dictationsPerDay: Trend
    /// Median wait after releasing `fn`, in seconds.
    let latency: Trend
    /// Words per minute of speech.
    let pace: Trend

    var today: Day { days[days.count - 1] }
    var isEmpty: Bool { days.allSatisfy { $0.dictations == 0 } }

    init(records: [DictationRecord], now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }

        days = (0..<Self.dayCount).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Self.day(date, byDay[date] ?? [])
        }

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
            let minutes = records.reduce(0) { $0 + $1.audio } / 60
            guard minutes > 0 else { return nil }
            return Double(records.reduce(0) { $0 + $1.words }) / minutes
        }
    }

    private static func day(_ date: Date, _ records: [DictationRecord]) -> Day {
        Day(
            date: date,
            words: records.reduce(0) { $0 + $1.words },
            dictations: records.count,
            transcription: median(records.map(\.transcription)) ?? 0,
            enhancement: median(records.map { ($0.enhancement ?? 0) + $0.insertion }) ?? 0,
            latency: median(records.map(\.latency)) ?? 0
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
