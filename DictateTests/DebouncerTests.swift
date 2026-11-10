import Testing

@testable import Dictate

@MainActor
struct DebouncerTests {
    /// Typing a term letter by letter runs the action once, after the last letter.
    @Test func aBurstRunsTheLastActionOnce() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        var runs: [Int] = []
        for letter in 1...5 { debouncer.schedule { runs.append(letter) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs == [5])
    }

    @Test func aCancelledActionNeverRuns() async throws {
        let debouncer = Debouncer(delay: .milliseconds(30))
        var ran = false
        debouncer.schedule { ran = true }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran)
    }
}
