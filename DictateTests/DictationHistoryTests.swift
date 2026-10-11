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
