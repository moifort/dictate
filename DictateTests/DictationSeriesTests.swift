import Foundation
import Testing
@testable import Dictate

struct DictationSeriesTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Sunday 11 October 2026, 18:00 in Paris.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 18))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(
        daysAgo: Int,
        hour: Int = 10,
        words: Int = 10,
        audio: TimeInterval = 4,
        transcription: TimeInterval = 2,
        enhancement: TimeInterval? = 1
    ) -> DictationRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return DictationRecord(
            date: calendar.date(byAdding: .hour, value: hour, to: day)!,
            words: words,
            audio: audio,
            transcription: transcription,
            enhancement: enhancement,
            insertion: 0
        )
    }

    private func series(_ records: [DictationRecord], _ period: StatsPeriod) -> DictationSeries {
        DictationSeries(records: records, period: period, now: now, calendar: calendar)
    }

    // MARK: - Columns

    @Test func monthCoversTheLastThirtyDaysOldestFirstEmptyDaysIncluded() {
        let series = series([record(daysAgo: 0), record(daysAgo: 2)], .month)
        #expect(series.buckets.count == 30)
        #expect(series.buckets.first?.date == date(2026, 9, 12))
        #expect(series.buckets.last?.date == date(2026, 10, 11))
        #expect(series.end == date(2026, 10, 12))
        #expect(series.buckets.map(\.dictations).suffix(3) == [1, 0, 1])
    }

    @Test func weekEndsOnToday() {
        let series = series([record(daysAgo: 6), record(daysAgo: 7)], .week)
        #expect(series.buckets.count == 7)
        #expect(series.buckets.first?.date == date(2026, 10, 5))
        #expect(series.dictations == 1)
    }

    @Test func dayRunsFromMidnightToMidnightByTheHour() {
        let series = series([record(daysAgo: 0, hour: 10), record(daysAgo: 1, hour: 23)], .day)
        #expect(series.buckets.count == 24)
        #expect(series.start == date(2026, 10, 11))
        #expect(series.end == date(2026, 10, 12))
        #expect(series.buckets[10].dictations == 1)
        #expect(series.buckets[10].end == date(2026, 10, 11, 11))
        #expect(series.dictations == 1)
    }

    @Test func sixMonthsGroupByWeekFromTheCalendarsFirstWeekday() {
        // Thursday 8 October sits in the week of Monday 5; Sunday 4 in the one before.
        let series = series([record(daysAgo: 3), record(daysAgo: 7)], .sixMonths)
        #expect(series.buckets.count == 26)
        #expect(series.buckets.last?.date == date(2026, 10, 5))
        #expect(series.buckets.last?.dictations == 1)
        #expect(series.buckets[24].dictations == 1)
        #expect(series.buckets.first?.date == date(2026, 4, 13))
    }

    @Test func yearGroupsByMonth() {
        let series = series([record(daysAgo: 0), record(daysAgo: 40)], .year)
        #expect(series.buckets.count == 12)
        #expect(series.buckets.first?.date == date(2025, 11, 1))
        #expect(series.buckets.last?.date == date(2026, 10, 1))
        #expect(series.buckets.map(\.dictations).suffix(2) == [1, 1])
    }

    @Test func recordsOlderThanThePeriodAreLeftOut() {
        let series = series([record(daysAgo: 60), record(daysAgo: 0)], .month)
        #expect(series.dictations == 1)
        #expect(series.buckets.reduce(0) { $0 + $1.dictations } == 1)
    }

    @Test func bucketContainingAnInstant() {
        let series = series([], .week)
        #expect(series.bucket(containing: date(2026, 10, 8, 15))?.date == date(2026, 10, 8))
        #expect(series.bucket(containing: date(2026, 10, 12)) == nil)
    }

    // MARK: - Figures

    @Test func bucketAddsWordsAndTakesMedianTimings() {
        let series = series([
            record(daysAgo: 0, hour: 9, words: 5, transcription: 1, enhancement: 1),
            record(daysAgo: 0, hour: 10, words: 7, transcription: 2, enhancement: 1),
            // A Claude timeout must not drag the whole day.
            record(daysAgo: 0, hour: 11, words: 8, transcription: 3, enhancement: 8),
        ], .week)
        let today = series.buckets.last!
        #expect(today.words == 20)
        #expect(today.dictations == 3)
        #expect(today.transcription == 2)
        #expect(today.enhancement == 1)
        #expect(today.latency == 3)
        #expect(series.words == 20)
        #expect(series.latency == 3)
    }

    @Test func dictationWithoutClaudeCountsNoEnhancement() {
        let series = series([record(daysAgo: 0, enhancement: nil)], .week)
        #expect(series.buckets.last?.enhancement == 0)
        #expect(series.buckets.last?.latency == 2)
    }

    @Test func paceIsWordsPerMinuteOfSpeech() {
        let series = series([record(daysAgo: 0, words: 30, audio: 12), record(daysAgo: 1, words: 10, audio: 8)], .week)
        #expect(series.buckets.last?.pace == 150)
        #expect(series.pace == 120)
        #expect(series.buckets.first?.pace == nil)
    }

    @Test func emptyPeriodHasNoFigures() {
        let series = series([], .month)
        #expect(series.words == 0)
        #expect(series.latency == nil)
        #expect(series.pace == nil)
    }
}
