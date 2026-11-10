import Foundation
import Testing

@testable import Dictate

/// A copy under one release identifier inheriting what the other left.
struct IdentifierMigrationTests {
    private let library = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)/Library")
    private let old = "test.dictate.old-\(UUID().uuidString)"
    private let new = "test.dictate.new-\(UUID().uuidString)"
    private let keys = KeyStores()

    private func migration(current: String? = nil, defaults: UserDefaults = .standard) -> IdentifierMigration {
        IdentifierMigration(
            current: current ?? new, releases: [old, new], others: [old], library: library, defaults: defaults,
            secret: { [keys] identifier, provider in keys.store(identifier, provider) }
        )
    }

    @Test func theFilesFollowTheCopy() throws {
        let theirs = AppPaths(identifier: old, library: library)
        try FileManager.default.createDirectory(at: theirs.statistics.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: theirs.statistics)
        try FileManager.default.createDirectory(at: theirs.corpus, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: theirs.corpus.appending(path: "entries.jsonl"))

        let migrated = migration().run()
        let mine = AppPaths(identifier: new, library: library)
        #expect(FileManager.default.fileExists(atPath: mine.statistics.path))
        #expect(FileManager.default.fileExists(atPath: mine.corpus.appending(path: "entries.jsonl").path))
        #expect(migrated.count == 2)
        // Copied, not moved: the other copy may still be installed.
        #expect(FileManager.default.fileExists(atPath: theirs.statistics.path))
    }

    @Test func nothingOfItsOwnIsOverwritten() throws {
        let theirs = AppPaths(identifier: old, library: library)
        let mine = AppPaths(identifier: new, library: library)
        for paths in [theirs, mine] {
            try FileManager.default.createDirectory(at: paths.statistics.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(paths.identifier.utf8).write(to: paths.statistics)
        }
        migration().run()
        #expect(try String(contentsOf: mine.statistics, encoding: .utf8) == new)
    }

    @Test func theKeysFollowTheCopy() throws {
        try keys.store(old, .openAI).write("sk-old")
        try keys.store(new, .gemini).write("AIza-mine")
        try keys.store(old, .gemini).write("AIza-old")
        migration().run()
        #expect(try keys.store(new, .openAI).read() == "sk-old")
        #expect(try keys.store(new, .gemini).read() == "AIza-mine")
    }

    @Test func theSettingsFollowWhenThisCopyHasNone() {
        let defaults = UserDefaults.standard
        defaults.setPersistentDomain(["language": "de"], forName: old)
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        #expect(migration().run().contains("settings from \(old)"))
        #expect(defaults.persistentDomain(forName: new)?["language"] as? String == "de")
        // Once it has its own, nothing is brought over again.
        defaults.setPersistentDomain(["language": "fr"], forName: old)
        migration().run()
        #expect(defaults.persistentDomain(forName: new)?["language"] as? String == "de")
    }

    /// A Debug build keeps its data apart on purpose.
    @Test func aDebugBuildBringsNothingOver() throws {
        try keys.store(old, .openAI).write("sk-old")
        #expect(migration(current: "test.dictate.dev").run().isEmpty)
    }
}

private final class KeyStores: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: InMemorySecret] = [:]

    func store(_ identifier: String, _ provider: APIProvider) -> SecretStore {
        lock.withLock {
            let key = "\(identifier)/\(provider.rawValue)"
            if let store = stores[key] { return store }
            let store = InMemorySecret()
            stores[key] = store
            return store
        }
    }
}
