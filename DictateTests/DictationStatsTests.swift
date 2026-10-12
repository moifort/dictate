import Foundation
import Testing
@testable import Dictate

struct DictationStatsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// Sunday 11 October 2026, 18:00 in Paris.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 18))!
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

    private func stats(_ records: [DictationRecord]) -> DictationStats {
        DictationStats(records: records, now: now, calendar: calendar)
    }

    // MARK: - Word count

    @Test func countsWordsIgnoringPunctuation() {
        #expect(DictationRecord.wordCount(of: "Fais un push sur la branche main.") == 7)
        #expect(DictationRecord.wordCount(of: "Tu viens ? Oui !") == 3)
        #expect(DictationRecord.wordCount(of: "  ") == 0)
    }

    @Test func latencyAddsEveryStepAfterRelease() {
        let record = DictationRecord(date: now, words: 1, audio: 3, transcription: 2, enhancement: 1, insertion: 0.5)
        #expect(record.latency == 3.5)
        let raw = DictationRecord(date: now, words: 1, audio: 3, transcription: 2, enhancement: nil, insertion: 0.5)
        #expect(raw.latency == 2.5)
    }

    // MARK: - Trends

    @Test func wordsTrendComparesActiveDaysOfTheLastWeekToTheFourBefore() {
        let stats = stats([
            record(daysAgo: 0, words: 120),
            record(daysAgo: 3, words: 80),
            record(daysAgo: 10, words: 50),
            record(daysAgo: 20, words: 50),
        ])
        #expect(stats.wordsPerDay.recent == 100)
        #expect(stats.wordsPerDay.baseline == 50)
        #expect(stats.wordsPerDay.direction == .up)
    }

    @Test func latencyTrendUsesMedians() {
        let stats = stats([
            record(daysAgo: 1, transcription: 1, enhancement: 1),
            record(daysAgo: 1, transcription: 1, enhancement: 1),
            record(daysAgo: 1, transcription: 1, enhancement: 8),
            record(daysAgo: 12, transcription: 2, enhancement: 1),
        ])
        #expect(stats.latency.recent == 2)
        #expect(stats.latency.baseline == 3)
        #expect(stats.latency.direction == .down)
    }

    @Test func paceIsWordsPerMinuteOfSpeech() {
        let stats = stats([record(daysAgo: 0, words: 30, audio: 12)])
        #expect(stats.pace.recent == 150)
    }

    @Test func smallChangesReadAsSteady() {
        let stats = stats([record(daysAgo: 0, words: 102), record(daysAgo: 9, words: 100)])
        #expect(stats.wordsPerDay.change == 0.02)
        #expect(stats.wordsPerDay.direction == .steady)
    }

    @Test func noBaselineMeansNoTrendYet() {
        let stats = stats([record(daysAgo: 0)])
        #expect(stats.wordsPerDay.recent == 10)
        #expect(stats.wordsPerDay.baseline == nil)
        #expect(stats.wordsPerDay.change == nil)
        #expect(stats.wordsPerDay.direction == nil)
    }

    @Test func emptyHistoryHasNothingToCompare() {
        let stats = stats([])
        #expect(stats.isEmpty)
        #expect(stats.wordsPerDay.recent == nil)
        #expect(stats.latency.recent == nil)
    }

    @Test func medianOfAnEvenCountAveragesTheMiddlePair() {
        #expect(DictationStats.median([4, 1, 3, 2]) == 2.5)
        #expect(DictationStats.median([]) == nil)
    }
}
