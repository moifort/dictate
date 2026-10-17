import Foundation
import Testing
@testable import Dictate

@MainActor
struct DictationHistoryTests {
    private let file = FileManager.default.temporaryDirectory
        .appending(path: "DictationHistoryTests-\(UUID().uuidString)/history.jsonl")

    private func record(words: Int) -> DictationRecord {
        DictationRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000 + Double(words)),
            words: words,
            audio: 4,
            transcription: 2,
            enhancement: 1,
            insertion: 0
        )
    }

    @Test func missingFileStartsEmpty() {
        #expect(DictationHistory(file: file).records.isEmpty)
    }

    @Test func appendedRecordsSurviveARelaunch() {
        let history = DictationHistory(file: file)
        history.append(record(words: 3))
        history.append(record(words: 5))
        #expect(history.records.map(\.words) == [3, 5])
        #expect(DictationHistory(file: file).records == history.records)
    }

    @Test func theEngineSurvivesARelaunch() {
        let record = DictationRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000), words: 4, audio: 3,
            engine: .parakeet, transcription: 0.2, enhancement: 1, insertion: 0
        )
        DictationHistory(file: file).append(record)
        #expect(DictationHistory(file: file).records == [record])
    }

    @Test func whisperDictationsAreKeptWithoutAnEngine() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            // Written before the engine was recorded: all came from Whisper.
            #"{"date":"2026-10-11T17:39:57Z","words":4,"audio":1.5,"transcription":2.1,"enhancement":1.2,"insertion":0.03}"#,
            #"{"date":"2026-10-12T09:00:00Z","words":6,"audio":2,"engine":"whisper","transcription":1.4,"enhancement":1,"insertion":0.02}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let records = DictationHistory(file: file).records
        #expect(records.map(\.words) == [4, 6])
        #expect(records.allSatisfy { $0.engine == nil })
        #expect(records.first?.transcription == 2.1)
    }

    @Test func theReviewerSurvivesARelaunch() {
        let apple = DictationRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000), words: 4, audio: 3,
            transcription: 0.2, enhancement: 1, reviewer: .apple, insertion: 0
        )
        let raw = DictationRecord(
            date: Date(timeIntervalSince1970: 1_800_000_001), words: 4, audio: 3,
            transcription: 0.2, enhancement: nil, insertion: 0
        )
        let history = DictationHistory(file: file)
        history.append(apple)
        history.append(raw)
        let records = DictationHistory(file: file).records
        #expect(records == [apple, raw])
        #expect(records.map(\.reviewer) == [.apple, nil])
    }

    @Test func dictationsCleanedUpBeforeTheReviewerWasRecordedAreClaudes() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"date":"2026-10-15T17:39:57Z","words":4,"audio":1.5,"engine":"parakeet","transcription":0.3,"enhancement":1.2,"insertion":0.03}"#,
            #"{"date":"2026-10-15T17:40:57Z","words":4,"audio":1.5,"engine":"parakeet","transcription":0.3,"insertion":0.03}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        #expect(DictationHistory(file: file).records.map(\.reviewer) == [.claude, nil])
    }

    @Test func aDamagedLineDoesNotLoseTheOthers() throws {
        let history = DictationHistory(file: file)
        history.append(record(words: 3))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        history.append(record(words: 5))
        #expect(DictationHistory(file: file).records.map(\.words) == [3, 5])
    }
}
