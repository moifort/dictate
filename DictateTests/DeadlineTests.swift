import Foundation
import Testing
@testable import Dictate

struct DeadlineTests {
    @Test func aPromptResultIsReturned() async throws {
        let work = Task.detached { () throws -> Int in 42 }
        let result = try await value(of: work, within: .seconds(5)) { _ in }
        #expect(result == 42)
    }

    @Test func aFailureIsPassedOn() async {
        let work = Task.detached { () throws -> Int in throw URLError(.badURL) }
        await #expect(throws: URLError.self) {
            try await value(of: work, within: .seconds(5)) { _ in }
        }
    }

    @Test func aBlockedTaskIsAbandonedWhenTheTimeIsUp() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let work = Task.detached { try blocked(on: gate) }
        await #expect(throws: DeadlineExceeded.self) {
            try await value(of: work, within: .milliseconds(50)) { _ in }
        }
    }

    @Test func aResultComingAfterTheDeadlineGoesToLate() async throws {
        let gate = DispatchSemaphore(value: 0)
        let work = Task.detached { try blocked(on: gate) }
        try await confirmation { confirm in
            await #expect(throws: DeadlineExceeded.self) {
                try await value(of: work, within: .milliseconds(50)) { result in
                    #expect(result == 42)
                    confirm()
                }
            }
            gate.signal()
            _ = await work.result
            // The late handler runs right after the task, on its own task.
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Stands for a call stuck in Core Audio: no cancellation reaches it.
private nonisolated func blocked(on gate: DispatchSemaphore) throws -> Int {
    gate.wait()
    return 42
}
