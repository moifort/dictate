import Foundation

/// The span of the statistics page, as the Health app offers it: today by
/// the hour, a week or a month by the day, six months by the week, a year by
/// the month.
nonisolated enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, sixMonths, year

    var id: String { rawValue }

    /// The width of one column.
    var unit: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .sixMonths: .weekOfYear
        case .year: .month
        }
    }

    /// How many columns, the current one included. The day is the exception:
    /// it runs from midnight to midnight, not 24 hours back from now.
    var count: Int {
        switch self {
        case .day: 24
        case .week: 7
        case .month: 30
        case .sixMonths: 26
        case .year: 12
        }
    }
}

/// The dictations of one period, one column per unit of time, as a Health
/// chart draws them. Timings are medians, never means: one Claude timeout of
/// eight seconds would otherwise drag a whole column up.
nonisolated struct DictationSeries: Equatable {
    struct Bucket: Identifiable, Equatable {
        /// Start of the column.
        let date: Date
        /// Start of the next column.
        let end: Date
        let words: Int
        let dictations: Int
        /// Seconds of speech recorded.
        let audio: TimeInterval
        /// Median transcription time, in seconds.
        let transcription: TimeInterval
        /// Median Claude time, insertion included, in seconds.
        let enhancement: TimeInterval
        /// Median wait after releasing `fn`, in seconds.
        let latency: TimeInterval

        var id: Date { date }
        var midpoint: Date { date.addingTimeInterval(end.timeIntervalSince(date) / 2) }
        /// Words per minute of speech; nil without speech.
        var pace: Double? { DictationSeries.pace(words: words, audio: audio) }
    }

    let period: StatsPeriod
    /// Oldest first, the current column last, empty columns included.
    let buckets: [Bucket]
    /// First instant covered.
    let start: Date
    /// First instant past the last column.
    let end: Date
    let words: Int
    let dictations: Int
    /// Median wait after releasing `fn` over the period, in seconds; nil
    /// without a dictation.
    let latency: TimeInterval?
    /// Words per minute of speech over the period; nil without speech.
    let pace: Double?

    init(records: [DictationRecord], period: StatsPeriod, now: Date = .now, calendar: Calendar = .current) {
        self.period = period
        let unit = period.unit
        let current = calendar.dateInterval(of: unit, for: now)!.start
        let start: Date
        let end: Date
        if period == .day {
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 1, to: start)!
        } else {
            start = calendar.date(byAdding: unit, value: 1 - period.count, to: current)!
            end = calendar.date(byAdding: unit, value: 1, to: current)!
        }
        self.start = start
        self.end = end

        let covered = records.filter { $0.date >= start && $0.date < end }
        let grouped = Dictionary(grouping: covered) { calendar.dateInterval(of: unit, for: $0.date)!.start }

        var buckets: [Bucket] = []
        var date = start
        while date < end {
            let next = calendar.date(byAdding: unit, value: 1, to: date)!
            buckets.append(Self.bucket(from: date, to: next, grouped[date] ?? []))
            date = next
        }
        self.buckets = buckets

        words = covered.reduce(0) { $0 + $1.words }
        dictations = covered.count
        latency = DictationStats.median(covered.map(\.latency))
        pace = Self.pace(words: words, audio: covered.reduce(0) { $0 + $1.audio })
    }

    /// The column an instant falls in, if any.
    func bucket(containing date: Date) -> Bucket? {
        buckets.first { $0.date <= date && date < $0.end }
    }

    private static func bucket(from start: Date, to end: Date, _ records: [DictationRecord]) -> Bucket {
        Bucket(
            date: start,
            end: end,
            words: records.reduce(0) { $0 + $1.words },
            dictations: records.count,
            audio: records.reduce(0) { $0 + $1.audio },
            transcription: DictationStats.median(records.map(\.transcription)) ?? 0,
            enhancement: DictationStats.median(records.map { ($0.enhancement ?? 0) + $0.insertion }) ?? 0,
            latency: DictationStats.median(records.map(\.latency)) ?? 0
        )
    }

    static func pace(words: Int, audio: TimeInterval) -> Double? {
        guard audio > 0 else { return nil }
        return Double(words) / (audio / 60)
    }
}
