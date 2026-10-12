import Foundation
import Testing
@testable import Dictate

struct ModelStorageTests {
    @Test func diskUsageSumsEveryFileInTheTree() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = folder.appending(path: "Encoder.mlmodelc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 100_000).write(to: folder.appending(path: "config.json"))
        try Data(count: 300_000).write(to: nested.appending(path: "weight.bin"))

        let usage = try #require(ModelStorage.diskUsage(of: folder))
        // Allocated blocks round each file up, never down.
        #expect(usage >= 400_000)
        #expect(usage < 500_000)
    }

    @Test func diskUsageIsNilWithoutTheFolder() {
        let missing = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        #expect(ModelStorage.diskUsage(of: missing) == nil)
    }
}
